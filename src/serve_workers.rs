use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tiny_http::Method;

use crate::http::{DaemonState, ServeConfig, handle_daemon_request};
use crate::util::split_url;

pub const DEFAULT_READ_POOL_SIZE: usize = 3;
pub const WRITER_LANE_CAP: usize = 8;
pub const WRITER_LANE_CHANNEL_CAP: usize = 64;
pub const WRITER_LANE_IDLE_TIMEOUT: Duration = Duration::from_secs(300);

const DEFAULT_EVICT_INTERVAL: Duration = Duration::from_secs(60);

/// Resolve shared read-pool size from env (`STUDIO_STUD_READ_POOL_SIZE`) or default.
pub fn read_pool_size() -> usize {
    std::env::var("STUDIO_STUD_READ_POOL_SIZE")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_READ_POOL_SIZE)
}

/// Writer-lane idle timeout; override via `STUDIO_STUD_WRITER_LANE_IDLE_MS` (tests).
pub fn writer_lane_idle_timeout() -> Duration {
    std::env::var("STUDIO_STUD_WRITER_LANE_IDLE_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .map(Duration::from_millis)
        .unwrap_or(WRITER_LANE_IDLE_TIMEOUT)
}

fn evict_interval() -> Duration {
    std::env::var("STUDIO_STUD_LANE_EVICT_INTERVAL_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .map(Duration::from_millis)
        .unwrap_or(DEFAULT_EVICT_INTERVAL)
}

/// True when the acceptor should route to a per-place writer lane (body unread).
pub fn routes_to_writer_lane(method: &Method, path: &str) -> bool {
    if method != &Method::Post {
        return false;
    }
    matches!(
        path,
        "/studio-stud/tick"
            | "/studio-stud/tick/bulk/start"
            | "/studio-stud/tick/bulk/chunk"
            | "/studio-stud/tick/bulk/complete"
    )
}

/// Routing key: `(projectKey, placeId)` with fallbacks for absent query params.
pub fn writer_lane_key(query: &HashMap<String, String>, default_project_key: &str) -> String {
    let project_key = query
        .get("projectKey")
        .or_else(|| query.get("project_key"))
        .map(String::as_str)
        .unwrap_or(default_project_key);
    let place_id = query
        .get("placeId")
        .or_else(|| query.get("place_id"))
        .map(String::as_str)
        .unwrap_or("0");
    format!("{project_key}|{place_id}")
}

fn write_test_lane_stats(count: usize) {
    if let Ok(path) = std::env::var("STUDIO_STUD_TEST_LANE_STATS") {
        let _ = std::fs::write(path, count.to_string());
    }
}

struct WriterLane {
    sender: SyncSender<tiny_http::Request>,
    thread: JoinHandle<()>,
    last_used: Instant,
}

struct WriterLaneRegistry {
    lanes: HashMap<String, WriterLane>,
    lru: VecDeque<String>,
    idle_timeout: Duration,
    cap: usize,
    state: Arc<Mutex<DaemonState>>,
    config: ServeConfig,
}

impl WriterLaneRegistry {
    fn new(state: Arc<Mutex<DaemonState>>, config: ServeConfig) -> Self {
        Self {
            lanes: HashMap::new(),
            lru: VecDeque::new(),
            idle_timeout: writer_lane_idle_timeout(),
            cap: WRITER_LANE_CAP,
            state,
            config,
        }
    }

    fn touch_lru(&mut self, key: &str) {
        if let Some(pos) = self.lru.iter().position(|k| k == key) {
            self.lru.remove(pos);
        }
        self.lru.push_front(key.to_string());
    }

    fn spawn_lane(&self) -> (SyncSender<tiny_http::Request>, JoinHandle<()>) {
        let (tx, rx) = mpsc::sync_channel(WRITER_LANE_CHANNEL_CAP);
        let state = Arc::clone(&self.state);
        let config = self.config.clone();
        let handle = thread::spawn(move || {
            writer_lane_loop(rx, state, config);
        });
        (tx, handle)
    }

    /// Register/refresh the lane for `key` and return a CLONE of its sender. The caller sends on the
    /// clone AFTER releasing the registry lock, so a full bounded lane channel can never stall the
    /// registry (cross-place dispatch + eviction stay live). The registry keeps its own sender, so
    /// an outstanding clone does not keep the lane alive past eviction (the lane drains then exits).
    fn acquire_sender(&mut self, key: &str) -> SyncSender<tiny_http::Request> {
        if !self.lanes.contains_key(key) {
            let (sender, thread) = self.spawn_lane();
            self.lanes.insert(
                key.to_string(),
                WriterLane {
                    sender,
                    thread,
                    last_used: Instant::now(),
                },
            );
            write_test_lane_stats(self.lanes.len());
        }
        self.touch_lru(key);
        let lane = self.lanes.get_mut(key).expect("lane present after insert");
        lane.last_used = Instant::now();
        lane.sender.clone()
    }

    fn remove_lane(&mut self, key: &str) {
        if let Some(lane) = self.lanes.remove(key) {
            drop(lane.sender);
            let _ = lane.thread.join();
        }
        self.lru.retain(|k| k != key);
        write_test_lane_stats(self.lanes.len());
    }

    fn evict_idle(&mut self, now: Instant) {
        let idle_keys: Vec<String> = self
            .lanes
            .iter()
            .filter(|(_, lane)| now.duration_since(lane.last_used) >= self.idle_timeout)
            .map(|(k, _)| k.clone())
            .collect();
        for key in idle_keys {
            self.remove_lane(&key);
        }
        while self.lanes.len() > self.cap {
            let Some(lru_key) = self.lru.back().cloned() else {
                break;
            };
            self.remove_lane(&lru_key);
        }
    }

    fn shutdown(&mut self) {
        let keys: Vec<String> = self.lanes.keys().cloned().collect();
        for key in keys {
            self.remove_lane(&key);
        }
        write_test_lane_stats(0);
    }

    fn lane_count(&self) -> usize {
        self.lanes.len()
    }
}

fn writer_lane_loop(
    rx: Receiver<tiny_http::Request>,
    state: Arc<Mutex<DaemonState>>,
    config: ServeConfig,
) {
    loop {
        let request = match rx.recv() {
            Ok(request) => request,
            Err(_) => break,
        };
        if let Err(err) = handle_daemon_request(request, Arc::clone(&state), &config) {
            crate::obs::event("http-error", &format!("request failed: {err:#}"));
        }
    }
}

fn read_pool_loop(
    rx: Arc<Mutex<Receiver<tiny_http::Request>>>,
    state: Arc<Mutex<DaemonState>>,
    config: ServeConfig,
) {
    loop {
        let request = match rx.lock() {
            Ok(rx) => match rx.recv() {
                Ok(request) => request,
                Err(_) => break,
            },
            Err(_) => break,
        };
        if let Err(err) = handle_daemon_request(request, Arc::clone(&state), &config) {
            crate::obs::event("http-error", &format!("request failed: {err:#}"));
        }
    }
}

/// Routes HTTP requests to per-place writer lanes or the shared read pool.
pub(crate) struct ServeDispatcher {
    pool_tx: Sender<tiny_http::Request>,
    pool_handles: Vec<JoinHandle<()>>,
    writer_registry: Arc<Mutex<WriterLaneRegistry>>,
    lane_evict_shutdown: Arc<AtomicBool>,
    evict_handle: JoinHandle<()>,
    default_project_key: String,
}

impl ServeDispatcher {
    pub(crate) fn start(
        state: Arc<Mutex<DaemonState>>,
        config: ServeConfig,
        pool_size: usize,
    ) -> Self {
        let (pool_tx, pool_rx) = mpsc::channel();
        let pool_rx = Arc::new(Mutex::new(pool_rx));
        let mut pool_handles = Vec::with_capacity(pool_size);
        for _ in 0..pool_size {
            let pool_rx = Arc::clone(&pool_rx);
            let state = Arc::clone(&state);
            let config = config.clone();
            pool_handles.push(thread::spawn(move || {
                read_pool_loop(pool_rx, state, config);
            }));
        }

        let writer_registry = Arc::new(Mutex::new(WriterLaneRegistry::new(
            Arc::clone(&state),
            config.clone(),
        )));
        let evict_registry = Arc::clone(&writer_registry);
        let lane_evict_shutdown = Arc::new(AtomicBool::new(false));
        let evict_stop = Arc::clone(&lane_evict_shutdown);
        let evict_handle = thread::spawn(move || {
            loop {
                thread::sleep(evict_interval());
                if evict_stop.load(Ordering::Relaxed) {
                    break;
                }
                let Ok(mut reg) = evict_registry.lock() else {
                    break;
                };
                reg.evict_idle(Instant::now());
            }
        });

        Self {
            pool_tx,
            pool_handles,
            writer_registry,
            lane_evict_shutdown,
            evict_handle,
            default_project_key: config.project_key.clone(),
        }
    }

    pub(crate) fn route(&self, request: tiny_http::Request) {
        let method = request.method().clone();
        let url = request.url().to_string();
        let (path, query) = split_url(&url);

        if routes_to_writer_lane(&method, &path) {
            let key = writer_lane_key(&query, &self.default_project_key);
            // Take a sender clone under the lock, then RELEASE the lock before sending: a full
            // bounded lane buffer must not stall cross-place dispatch or eviction.
            let sender = match self.writer_registry.lock() {
                Ok(mut reg) => reg.acquire_sender(&key),
                Err(_) => return,
            };
            if sender.send(request).is_err() {
                // Lane thread is gone — reap the dead lane.
                if let Ok(mut reg) = self.writer_registry.lock() {
                    reg.remove_lane(&key);
                }
            }
        } else if self.pool_tx.send(request).is_err() {
            // pool shut down
        }
    }

    #[allow(dead_code)]
    pub(crate) fn writer_lane_count(&self) -> usize {
        self.writer_registry
            .lock()
            .map(|reg| reg.lane_count())
            .unwrap_or(0)
    }

    pub(crate) fn shutdown(self) {
        self.lane_evict_shutdown
            .store(true, Ordering::Relaxed);
        drop(self.pool_tx);
        for handle in self.pool_handles {
            let _ = handle.join();
        }
        if let Ok(mut reg) = self.writer_registry.lock() {
            reg.shutdown();
        }
        let _ = self.evict_handle.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_tick_and_bulk_to_writer_lane() {
        assert!(routes_to_writer_lane(
            &Method::Post,
            "/studio-stud/tick"
        ));
        assert!(routes_to_writer_lane(
            &Method::Post,
            "/studio-stud/tick/bulk/start"
        ));
        assert!(routes_to_writer_lane(
            &Method::Post,
            "/studio-stud/tick/bulk/chunk"
        ));
        assert!(routes_to_writer_lane(
            &Method::Post,
            "/studio-stud/tick/bulk/complete"
        ));
        assert!(!routes_to_writer_lane(&Method::Get, "/studio-stud/tick"));
        assert!(!routes_to_writer_lane(
            &Method::Post,
            "/studio-stud/live/delta"
        ));
        assert!(!routes_to_writer_lane(
            &Method::Get,
            "/studio-stud/ping"
        ));
    }

    #[test]
    fn writer_lane_key_uses_query_params() {
        let mut q = HashMap::new();
        q.insert("projectKey".into(), "MyProj".into());
        q.insert("placeId".into(), "12345".into());
        assert_eq!(writer_lane_key(&q, "default"), "MyProj|12345");
    }

    #[test]
    fn writer_lane_key_falls_back_to_defaults() {
        let q = HashMap::new();
        assert_eq!(writer_lane_key(&q, "default"), "default|0");
    }

    #[test]
    fn writer_lane_key_accepts_snake_case_aliases() {
        let mut q = HashMap::new();
        q.insert("project_key".into(), "P".into());
        q.insert("place_id".into(), "9".into());
        assert_eq!(writer_lane_key(&q, "default"), "P|9");
    }
}
