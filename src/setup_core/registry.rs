use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use serde_json::{Value, json};

use super::config::{RepoEntry, StudioStudConfig, load_config, save_config};

#[derive(Debug, Clone)]
pub enum RepoResolveError {
    Unbound { place_id: i64, registered: Vec<Value> },
    NoRegistry,
}

#[derive(Clone)]
pub struct RepoResolver {
    inner: Arc<RwLock<StudioStudConfig>>,
}

impl RepoResolver {
    pub fn from_config(cfg: StudioStudConfig) -> Self {
        Self {
            inner: Arc::new(RwLock::new(cfg)),
        }
    }

    pub fn load() -> Self {
        Self::from_config(super::config::load_config_or_default())
    }

    pub fn reload(&self) -> Result<(), String> {
        let cfg = load_config().map_err(|e| e.to_string())?.unwrap_or_default();
        *self.inner.write().map_err(|_| "lock poisoned".to_string())? = cfg;
        Ok(())
    }

    pub fn config_snapshot(&self) -> StudioStudConfig {
        self.inner.read().unwrap().clone()
    }

    pub fn resolve_repo_root(&self, place_id: Option<i64>) -> Result<PathBuf, RepoResolveError> {
        let guard = self.inner.read().unwrap();
        if guard.repos.is_empty() && guard.install_root.is_empty() {
            return Err(RepoResolveError::NoRegistry);
        }
        if let Some(pid) = place_id {
            if let Some(entry) = guard.repos.iter().find(|r| r.place_id == Some(pid)) {
                return Ok(PathBuf::from(&entry.path));
            }
            let registered: Vec<Value> = guard
                .repos
                .iter()
                .map(|r| {
                    json!({
                        "path": r.path,
                        "placeId": r.place_id,
                        "enabledAddons": r.enabled_addons,
                    })
                })
                .collect();
            return Err(RepoResolveError::Unbound {
                place_id: pid,
                registered,
            });
        }
        // No placeId: fall back to first registered repo if any
        if let Some(entry) = guard.repos.first() {
            return Ok(PathBuf::from(&entry.path));
        }
        Err(RepoResolveError::NoRegistry)
    }

    pub fn bind_place(&self, place_id: i64, repo_path: &Path) -> Result<bool, String> {
        let canon = repo_path
            .canonicalize()
            .unwrap_or_else(|_| repo_path.to_path_buf());
        let key = canon.display().to_string();
        let mut guard = self.inner.write().map_err(|_| "lock poisoned".to_string())?;
        let Some(entry) = guard
            .repos
            .iter_mut()
            .find(|r| r.path.eq_ignore_ascii_case(&key))
        else {
            guard.repos.push(RepoEntry {
                path: key.clone(),
                place_id: Some(place_id),
                enabled_addons: Vec::new(),
                registered_at: crate::util::now_utc(),
            });
            save_config(&guard).map_err(|e| e.to_string())?;
            return Ok(true);
        };
        if entry.place_id == Some(place_id) {
            return Ok(false);
        }
        entry.place_id = Some(place_id);
        save_config(&guard).map_err(|e| e.to_string())?;
        Ok(true)
    }

    /// Auto-bind for the common single-repo install: when exactly one repo is
    /// registered and it is not yet bound to any place, bind it to `place_id`.
    /// Returns the bound repo path on success. This is what makes
    /// "install -> add-repo -> open Studio" sync with no manual bind step.
    /// Deliberately conservative: it does nothing when 0 or 2+ repos are
    /// registered, or when the sole repo is already bound to a place.
    pub fn autobind_sole_repo(&self, place_id: i64) -> Option<PathBuf> {
        let mut guard = self.inner.write().ok()?;
        if guard.repos.len() != 1 {
            return None;
        }
        {
            let entry = &mut guard.repos[0];
            if entry.place_id.is_some() {
                return None;
            }
            entry.place_id = Some(place_id);
        }
        let path = PathBuf::from(&guard.repos[0].path);
        if let Err(e) = save_config(&guard) {
            // In-memory bind is still effective for this session; surface the
            // persistence failure but don't fail the bind.
            eprintln!("Studio Stud: autobind save_config failed: {e}");
        }
        Some(path)
    }

    /// Learn-on-connect: bind place from capture payload when repo path is known.
    pub fn learn_place_from_cwd(&self, place_id: i64) -> Result<(), String> {
        if let Ok(root) = crate::policy::resolve_repo_root(None) {
            return self.bind_place(place_id, &root).map(|_| ());
        }
        Ok(())
    }
}

pub fn bind_place_to_repo(place_id: i64, repo_path: &Path) -> Result<bool, String> {
    let resolver = RepoResolver::load();
    resolver.bind_place(place_id, repo_path)
}

impl RepoResolveError {
    pub fn to_json(&self) -> Value {
        match self {
            RepoResolveError::Unbound {
                place_id,
                registered,
            } => json!({
                "ok": false,
                "status": "unbound",
                "placeId": place_id,
                "registeredRepos": registered,
            }),
            RepoResolveError::NoRegistry => json!({
                "ok": false,
                "status": "noRegistry",
                "detail": "No Studio Stud install registry. Run studio-stud-setup install.",
            }),
        }
    }
}
