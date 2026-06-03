use std::path::{Path, PathBuf};

use crate::theme;

use eframe::egui::{self, CentralPanel, ScrollArea, TopBottomPanel, ViewportCommand};
use studio_stud::setup_core::config::{StudioStudConfig, load_config_or_default, save_config};
use studio_stud::setup_core::install::{
    default_install_root, default_plugins_dir, is_valid_repo_root, repo_already_registered,
};

use crate::install_flow::{HeadlessInstallParams, resolve_daemon_src, resolve_plugin_src, run_install_headless};

use theme::{
    ToastSeverity, apply_theme, card, checkbox_row, content_alpha, divider, error_card,
    ghost_button, header_band, open_folder, path_exists, path_row, primary_button, progress_card,
    secondary_button, section, step_anim, success_card, summary_field, take_dropped_folder, toast,
    window_icon, BG, HAIRLINE, L, M, S, SURFACE, XS,
};

const INSTALL_STEPS: &[&str] = &["Location", "Plugins", "Repos", "Confirm"];
const UNINSTALL_STEPS: &[&str] = &["Scope", "Repos", "Confirm"];

#[derive(Default, PartialEq, Eq, Clone, Copy)]
enum InstallStep {
    #[default]
    Location,
    PluginsDir,
    Repos,
    Confirm,
}

impl InstallStep {
    fn index(self) -> usize {
        match self {
            InstallStep::Location => 0,
            InstallStep::PluginsDir => 1,
            InstallStep::Repos => 2,
            InstallStep::Confirm => 3,
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
enum InstallPhase {
    Editing,
    Installing,
    Done(String),
    Failed(String),
}

pub struct InstallApp {
    step: InstallStep,
    prev_step: InstallStep,
    install_root: String,
    plugins_dir: String,
    plugins_default_missing: bool,
    install_repos: bool,
    repos: Vec<String>,
    toasts: Vec<(ToastSeverity, String)>,
    phase: InstallPhase,
    install_rx: Option<std::sync::mpsc::Receiver<Result<String, String>>>,
}

#[derive(Clone)]
struct InstallInputs {
    install_root: String,
    plugins_dir: String,
    install_repos: bool,
    repos: Vec<String>,
}

impl Default for InstallApp {
    fn default() -> Self {
        let plugins = default_plugins_dir();
        let exists = plugins.is_dir();
        let root = default_install_root();
        Self {
            step: InstallStep::Location,
            prev_step: InstallStep::Location,
            install_root: if root.is_dir() {
                root.display().to_string()
            } else {
                String::new()
            },
            plugins_dir: if exists {
                plugins.display().to_string()
            } else {
                String::new()
            },
            plugins_default_missing: !exists,
            install_repos: false,
            repos: Vec::new(),
            toasts: Vec::new(),
            phase: InstallPhase::Editing,
            install_rx: None,
        }
    }
}

impl InstallApp {
    fn set_step(&mut self, step: InstallStep) {
        self.prev_step = self.step;
        self.step = step;
        self.toasts.clear();
    }

    fn plugins_ok(&self) -> bool {
        path_exists(&self.plugins_dir)
    }

    fn location_ok(&self) -> bool {
        !self.install_root.trim().is_empty()
    }

    fn try_add_repo(&mut self, p: PathBuf) {
        self.toasts.clear();
        if !is_valid_repo_root(&p) {
            self.toasts.push((
                ToastSeverity::Danger,
                format!("Not a valid repo root: {}", p.display()),
            ));
            return;
        }
        if self.repos.iter().any(|r| paths_equal(r, &p)) {
            self.toasts
                .push((ToastSeverity::Warning, "Already in list.".into()));
            return;
        }
        let cfg = load_config_or_default();
        if repo_already_registered(&cfg, &p) {
            self.toasts.push((
                ToastSeverity::Warning,
                format!("Already installed: {}", p.display()),
            ));
            return;
        }
        self.repos.push(p.display().to_string());
    }

    fn render_toasts(&self, ui: &mut egui::Ui) {
        for (sev, msg) in &self.toasts {
            toast(ui, *sev, msg);
        }
    }
}

impl eframe::App for InstallApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_install();
        if matches!(self.phase, InstallPhase::Installing) {
            ctx.request_repaint();
        }

        let step_idx = self.step.index();
        let anim = step_anim(ctx, step_idx);
        let step_key = format!("install_{step_idx}");
        let alpha = if self.prev_step != self.step {
            content_alpha(ctx, &step_key, false)
        } else {
            1.0
        };
        if self.prev_step != self.step {
            self.prev_step = self.step;
        }

        TopBottomPanel::top("install_header")
            .frame(
                egui::Frame::none()
                    .fill(SURFACE)
                    .stroke(egui::Stroke::new(1.0, HAIRLINE))
                    .inner_margin(egui::Margin::symmetric(L, M)),
            )
            .show(ctx, |ui| {
                header_band(ui, "Studio Stud Installer", INSTALL_STEPS, step_idx, anim);
            });

        let (footer_back, _footer_primary, footer_enabled, footer_label, footer_reason) =
            self.footer_state();

        TopBottomPanel::bottom("install_footer")
            .frame(
                egui::Frame::none()
                    .fill(SURFACE)
                    .stroke(egui::Stroke::new(1.0, HAIRLINE))
                    .inner_margin(egui::Margin::symmetric(L, M)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    if footer_back.is_some() {
                        if secondary_button(ui, "Back").clicked() {
                            if let Some(s) = footer_back {
                                self.set_step(s);
                                if matches!(self.phase, InstallPhase::Failed(_)) {
                                    self.phase = InstallPhase::Editing;
                                }
                            }
                        }
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if let Some(reason) = footer_reason {
                            ui.label(
                                egui::RichText::new(reason).color(theme::MUTED).size(12.0),
                            );
                            ui.add_space(S);
                        }
                        let btn = if footer_enabled {
                            primary_button(ui, footer_label)
                        } else {
                            ui.add_enabled(
                                false,
                                egui::Button::new(
                                    egui::RichText::new(footer_label).color(theme::MUTED),
                                )
                                .fill(theme::CARD)
                                .min_size(egui::Vec2::new(100.0, 32.0)),
                            )
                        };
                        if footer_enabled && btn.clicked() {
                            self.on_footer_primary(ctx);
                        }
                    });
                });
            });

        CentralPanel::default()
            .frame(egui::Frame::none().fill(BG).inner_margin(egui::Margin::same(L)))
            .show(ctx, |ui| {
                ui.set_opacity(alpha);
                ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        match self.step {
                            InstallStep::Location => self.screen_location(ui),
                            InstallStep::PluginsDir => self.screen_plugins(ui),
                            InstallStep::Repos => self.screen_repos(ui, ctx),
                            InstallStep::Confirm => self.screen_confirm(ui, ctx),
                        }
                    });
            });

        let enter = ctx.input(|i| i.key_pressed(egui::Key::Enter));
        let esc = ctx.input(|i| i.key_pressed(egui::Key::Escape));
        if esc {
            if let Some(s) = footer_back {
                self.set_step(s);
                if matches!(self.phase, InstallPhase::Failed(_)) {
                    self.phase = InstallPhase::Editing;
                }
            }
        } else if enter && footer_enabled {
            self.on_footer_primary(ctx);
        }
    }
}

impl InstallApp {
    fn footer_state(&self) -> (Option<InstallStep>, bool, bool, &'static str, Option<&'static str>) {
        match self.phase {
            InstallPhase::Installing => (None, false, false, "Installing…", None),
            InstallPhase::Done(_) => (None, false, true, "Close", None),
            InstallPhase::Failed(_) => (
                Some(InstallStep::Repos),
                true,
                true,
                "Retry",
                None,
            ),
            InstallPhase::Editing => match self.step {
                InstallStep::Location => (
                    None,
                    true,
                    self.location_ok(),
                    "Next",
                    if self.location_ok() {
                        None
                    } else {
                        Some("Select an install folder")
                    },
                ),
                InstallStep::PluginsDir => (
                    Some(InstallStep::Location),
                    true,
                    self.plugins_ok(),
                    "Next",
                    if self.plugins_ok() {
                        None
                    } else {
                        Some("Select a folder that exists")
                    },
                ),
                InstallStep::Repos => (
                    Some(InstallStep::PluginsDir),
                    true,
                    true,
                    "Next",
                    None,
                ),
                InstallStep::Confirm => (
                    Some(InstallStep::Repos),
                    true,
                    true,
                    "Install",
                    None,
                ),
            },
        }
    }

    fn start_install(&mut self, ctx: &egui::Context) {
        let input = InstallInputs {
            install_root: self.install_root.clone(),
            plugins_dir: self.plugins_dir.clone(),
            install_repos: self.install_repos,
            repos: self.repos.clone(),
        };
        let (tx, rx) = std::sync::mpsc::channel();
        self.install_rx = Some(rx);
        self.phase = InstallPhase::Installing;
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = run_install(&input).map_err(|e| format!("{e:#}"));
            let _ = tx.send(result);
            ctx.request_repaint();
        });
    }

    /// Poll the background install thread and transition the phase when it finishes.
    fn poll_install(&mut self) {
        if let Some(rx) = &self.install_rx {
            match rx.try_recv() {
                Ok(Ok(msg)) => {
                    self.phase = InstallPhase::Done(msg);
                    self.install_rx = None;
                }
                Ok(Err(e)) => {
                    self.phase = InstallPhase::Failed(e);
                    self.install_rx = None;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    self.install_rx = None;
                }
            }
        }
    }

    fn on_footer_primary(&mut self, ctx: &egui::Context) {
        match &self.phase {
            InstallPhase::Done(_) => {
                ctx.send_viewport_cmd(ViewportCommand::Close);
                return;
            }
            InstallPhase::Failed(_) => {
                self.start_install(ctx);
                return;
            }
            InstallPhase::Installing => return,
            InstallPhase::Editing => {}
        }

        match self.step {
            InstallStep::Location if self.location_ok() => self.set_step(InstallStep::PluginsDir),
            InstallStep::PluginsDir if self.plugins_ok() => self.set_step(InstallStep::Repos),
            InstallStep::Repos => self.set_step(InstallStep::Confirm),
            InstallStep::Confirm => self.start_install(ctx),
            _ => {}
        }
    }

    fn screen_location(&mut self, ui: &mut egui::Ui) {
        section(
            ui,
            "Where should Studio Stud install?",
            "The daemon and tools will live in this folder.",
        );
        if self.install_root.trim().is_empty() {
            toast(
                ui,
                ToastSeverity::Warning,
                "Choose where Studio Stud should install.",
            );
        }
        card(ui, |ui| {
            let _ = path_row(ui, &mut self.install_root, "Browse…", true);
        });
    }

    fn screen_plugins(&mut self, ui: &mut egui::Ui) {
        section(
            ui,
            "Roblox Plugins folder",
            "Studio Stud copies the core plugin into this folder.",
        );
        if self.plugins_default_missing && self.plugins_dir.is_empty() {
            toast(
                ui,
                ToastSeverity::Warning,
                "Default plugins folder was not found. Select an existing folder.",
            );
        }
        card(ui, |ui| {
            ui.label(
                egui::RichText::new("Plugins folder")
                    .color(theme::MUTED)
                    .size(12.5),
            );
            ui.add_space(S);
            let _ = path_row(ui, &mut self.plugins_dir, "Browse…", true);
        });
    }

    fn screen_repos(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        // A clearly visible checkbox gates the rest of the screen; no heading above it.
        card(ui, |ui| {
            checkbox_row(
                ui,
                &mut self.install_repos,
                "Select to setup Studio Stud in your repo",
            );
        });

        if !self.install_repos {
            return;
        }

        ui.add_space(M);
        self.render_toasts(ui);

        if let Some(p) = take_dropped_folder(ctx) {
            self.try_add_repo(p);
        }

        // Add button on top (always reachable), list box fills the width below.
        ui.horizontal(|ui| {
            if primary_button(ui, "Add folder…").clicked()
                && let Some(p) = rfd::FileDialog::new().pick_folder()
            {
                self.try_add_repo(p);
            }
            ui.label(
                egui::RichText::new("Pick a repo's top-level folder.")
                    .color(theme::MUTED)
                    .size(11.5),
            );
        });
        ui.add_space(M);
        self.repo_list_box(ui);
    }

    fn repo_list_box(&mut self, ui: &mut egui::Ui) {
        let row_h = 30.0;
        let box_h = ui.available_height().clamp(140.0, 240.0);
        let mut remove_idx = None;
        egui::Frame::none()
            .fill(SURFACE)
            .stroke(egui::Stroke::new(1.5, theme::BORDER))
            .rounding(egui::Rounding::same(theme::R_CARD))
            .inner_margin(egui::Margin::same(S))
            .show(ui, |ui| {
                ui.set_height(box_h);
                ui.set_width(ui.available_width());
                let avail_w = ui.available_width();
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        let slots = (((box_h - 2.0 * S) / row_h).floor() as usize).max(1);
                        let rows = self.repos.len().max(slots);
                        for i in 0..rows {
                            let (rect, _) = ui.allocate_exact_size(
                                egui::vec2(avail_w, row_h),
                                egui::Sense::hover(),
                            );
                            if i + 1 < rows {
                                ui.painter().line_segment(
                                    [rect.left_bottom(), rect.right_bottom()],
                                    egui::Stroke::new(1.0, HAIRLINE),
                                );
                            }
                            if let Some(full) = self.repos.get(i) {
                                let remove_w = 72.0;
                                let inner = rect.shrink2(egui::vec2(S, 0.0));
                                let label_rect = egui::Rect::from_min_size(
                                    inner.min,
                                    egui::vec2((inner.width() - remove_w).max(40.0), inner.height()),
                                );
                                let remove_rect = egui::Rect::from_min_size(
                                    egui::pos2(inner.max.x - remove_w, inner.min.y),
                                    egui::vec2(remove_w, inner.height()),
                                );
                                let max_chars = (label_rect.width() / 7.0) as usize;
                                let shown = theme::truncate_middle(full, max_chars);
                                let mut label_ui = ui.new_child(
                                    egui::UiBuilder::new()
                                        .max_rect(label_rect)
                                        .layout(egui::Layout::left_to_right(egui::Align::Center)),
                                );
                                label_ui
                                    .add(
                                        egui::Label::new(
                                            egui::RichText::new(shown)
                                                .color(theme::TEXT)
                                                .size(13.0),
                                        )
                                        .truncate(),
                                    )
                                    .on_hover_text(full);
                                let mut rm_ui = ui.new_child(
                                    egui::UiBuilder::new()
                                        .max_rect(remove_rect)
                                        .layout(egui::Layout::right_to_left(egui::Align::Center)),
                                );
                                if ghost_button(&mut rm_ui, "Remove").clicked() {
                                    remove_idx = Some(i);
                                }
                            }
                        }
                    });
            });
        if let Some(i) = remove_idx {
            self.repos.remove(i);
        }
    }

    fn screen_confirm(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        match &self.phase.clone() {
            InstallPhase::Installing => {
                section(ui, "Installing", "Please wait while Studio Stud is set up.");
                let frac = ui
                    .ctx()
                    .animate_value_with_time(egui::Id::new("install_progress"), 0.92, 5.0);
                progress_card(ui, "Installing Studio Stud…", frac);
                return;
            }
            InstallPhase::Done(msg) => {
                section(ui, "All set", "Studio Stud is ready to use.");
                success_card(ui, msg);
                ui.add_space(M);
                if ghost_button(ui, "Open install folder").clicked() {
                    open_folder(Path::new(&self.install_root));
                }
                return;
            }
            InstallPhase::Failed(err) => {
                section(ui, "Something went wrong", "Review the error and try again.");
                error_card(ui, err);
                return;
            }
            InstallPhase::Editing => {}
        }

        section(ui, "Review and install", "Confirm your choices before installing.");
        card(ui, |ui| {
            summary_field(ui, "Install location", &self.install_root);
            divider(ui);
            summary_field(ui, "Plugins folder", &self.plugins_dir);
            divider(ui);
            let active_repos = self.install_repos && !self.repos.is_empty();
            ui.label(
                egui::RichText::new(if active_repos {
                    format!("Project folders ({})", self.repos.len())
                } else {
                    "Project folders".to_string()
                })
                .color(theme::MUTED)
                .size(12.5),
            );
            ui.add_space(XS);
            if active_repos {
                for r in &self.repos {
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new("•").color(theme::ACCENT));
                        ui.add(
                            egui::Label::new(
                                egui::RichText::new(r).color(theme::TEXT).size(13.0),
                            )
                            .truncate(),
                        )
                        .on_hover_text(r);
                    });
                }
            } else {
                ui.label(
                    egui::RichText::new("None — installing the tool only")
                        .color(theme::MUTED)
                        .italics(),
                );
            }
        });
        let _ = ctx;
    }
}

fn paths_equal(a: &str, b: &Path) -> bool {
    PathBuf::from(a)
        .canonicalize()
        .ok()
        .zip(b.canonicalize().ok())
        .map(|(x, y)| x == y)
        .unwrap_or(false)
}

fn run_install(app: &InstallInputs) -> anyhow::Result<String> {
    let install_root = PathBuf::from(&app.install_root);
    let plugins_dir = PathBuf::from(&app.plugins_dir);

    let daemon_src = resolve_daemon_src().ok_or_else(|| {
        anyhow::anyhow!(
            "Could not find studio-stud.exe. Build the project first (cargo build --workspace \
             or .\\scripts\\package-release.ps1), then run setup again."
        )
    })?;
    let plugin_src = resolve_plugin_src().ok_or_else(|| {
        anyhow::anyhow!(
            "Could not find StudioStud.plugin.lua next to the setup tool or in plugin/."
        )
    })?;

    run_install_headless(&HeadlessInstallParams {
        install_root: install_root.clone(),
        plugins_dir: plugins_dir.clone(),
        daemon_src,
        plugin_src,
        repo_paths: app.repos.clone(),
        channel: Some("release".into()),
        daemon_version: env!("CARGO_PKG_VERSION").into(),
        plugin_version: String::new(),
        install_repos: app.install_repos,
    })?;
    Ok(format!(
        "Installed to {}. Open a new terminal for studio-stud on PATH.",
        install_root.display()
    ))
}

// --- Uninstaller ---

#[derive(Default, PartialEq, Eq, Clone, Copy)]
enum UninstallStep {
    #[default]
    Scope,
    Repos,
    Confirm,
}

impl UninstallStep {
    fn index(self) -> usize {
        match self {
            UninstallStep::Scope => 0,
            UninstallStep::Repos => 1,
            UninstallStep::Confirm => 2,
        }
    }

    fn prev(self) -> Option<Self> {
        match self {
            UninstallStep::Scope => None,
            UninstallStep::Repos => Some(UninstallStep::Scope),
            UninstallStep::Confirm => Some(UninstallStep::Repos),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
enum UninstallPhase {
    Editing,
    Working,
    Done(String),
    Failed(String),
}

pub struct UninstallApp {
    step: UninstallStep,
    prev_step: UninstallStep,
    remove_user: bool,
    repo_paths: Vec<(String, bool)>,
    phase: UninstallPhase,
    uninstall_rx: Option<std::sync::mpsc::Receiver<Result<String, String>>>,
}

#[derive(Clone)]
struct UninstallInputs {
    remove_user: bool,
    repo_paths: Vec<(String, bool)>,
}

impl Default for UninstallApp {
    fn default() -> Self {
        let cfg = load_config_or_default();
        let repo_paths = cfg
            .repos
            .iter()
            .map(|r| (r.path.clone(), false))
            .collect();
        Self {
            step: UninstallStep::Scope,
            prev_step: UninstallStep::Scope,
            remove_user: true,
            repo_paths,
            phase: UninstallPhase::Editing,
            uninstall_rx: None,
        }
    }
}

impl UninstallApp {
    fn set_step(&mut self, step: UninstallStep) {
        self.prev_step = self.step;
        self.step = step;
    }

    fn something_selected(&self) -> bool {
        self.remove_user || self.repo_paths.iter().any(|(_, sel)| *sel)
    }

    fn poll_uninstall(&mut self) {
        if let Some(rx) = &self.uninstall_rx
            && let Ok(result) = rx.try_recv()
        {
            self.uninstall_rx = None;
            match result {
                Ok(msg) => self.phase = UninstallPhase::Done(msg),
                Err(e) => self.phase = UninstallPhase::Failed(e),
            }
        }
    }
}

impl eframe::App for UninstallApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_uninstall();
        if matches!(self.phase, UninstallPhase::Working) {
            ctx.request_repaint();
        }

        let step_idx = self.step.index();
        let anim = step_anim(ctx, step_idx);
        let alpha = if self.prev_step != self.step {
            content_alpha(ctx, &format!("uninstall_{step_idx}"), false)
        } else {
            1.0
        };
        if self.prev_step != self.step {
            self.prev_step = self.step;
        }

        TopBottomPanel::top("uninstall_header")
            .frame(
                egui::Frame::none()
                    .fill(SURFACE)
                    .stroke(egui::Stroke::new(1.0, HAIRLINE))
                    .inner_margin(egui::Margin::symmetric(L, M)),
            )
            .show(ctx, |ui| {
                header_band(ui, "Studio Stud Uninstaller", UNINSTALL_STEPS, step_idx, anim);
            });

        let (back, primary_label, primary_enabled, reason) = match &self.phase {
            UninstallPhase::Working => (None, "Working…", false, None),
            UninstallPhase::Done(_) => (None, "Close", true, None),
            UninstallPhase::Failed(_) => (Some(UninstallStep::Repos), "Retry", true, None),
            UninstallPhase::Editing => match self.step {
                UninstallStep::Scope => (None, "Next", true, None),
                UninstallStep::Repos => (Some(UninstallStep::Scope), "Next", true, None),
                UninstallStep::Confirm => (
                    Some(UninstallStep::Repos),
                    "Uninstall",
                    self.something_selected(),
                    if self.something_selected() {
                        None
                    } else {
                        Some("Select something to remove")
                    },
                ),
            },
        };

        TopBottomPanel::bottom("uninstall_footer")
            .frame(
                egui::Frame::none()
                    .fill(SURFACE)
                    .stroke(egui::Stroke::new(1.0, HAIRLINE))
                    .inner_margin(egui::Margin::symmetric(L, M)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    if let Some(s) = back {
                        if secondary_button(ui, "Back").clicked() {
                            self.set_step(s);
                            if matches!(self.phase, UninstallPhase::Failed(_)) {
                                self.phase = UninstallPhase::Editing;
                            }
                        }
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if let Some(r) = reason {
                            ui.label(egui::RichText::new(r).color(theme::MUTED).size(12.0));
                            ui.add_space(S);
                        }
                        let btn = if primary_enabled {
                            primary_button(ui, primary_label)
                        } else {
                            ui.add_enabled(
                                false,
                                egui::Button::new(
                                    egui::RichText::new(primary_label).color(theme::MUTED),
                                )
                                .fill(theme::CARD)
                                .min_size(egui::Vec2::new(100.0, 32.0)),
                            )
                        };
                        if primary_enabled && btn.clicked() {
                            self.on_primary(ctx);
                        }
                    });
                });
            });

        CentralPanel::default()
            .frame(egui::Frame::none().fill(BG).inner_margin(egui::Margin::same(L)))
            .show(ctx, |ui| {
                ui.set_opacity(alpha);
                ScrollArea::vertical().show(ui, |ui| match self.step {
                    UninstallStep::Scope => self.screen_scope(ui),
                    UninstallStep::Repos => self.screen_repos(ui),
                    UninstallStep::Confirm => self.screen_confirm(ui),
                });
            });

        let enter = ctx.input(|i| i.key_pressed(egui::Key::Enter)) && primary_enabled;
        let esc = ctx.input(|i| i.key_pressed(egui::Key::Escape));
        if esc {
            if let Some(s) = self.step.prev() {
                self.set_step(s);
                if matches!(self.phase, UninstallPhase::Failed(_)) {
                    self.phase = UninstallPhase::Editing;
                }
            }
        } else if enter {
            self.on_primary(ctx);
        }
    }
}

impl UninstallApp {
    fn start_uninstall(&mut self, ctx: &egui::Context) {
        let input = UninstallInputs {
            remove_user: self.remove_user,
            repo_paths: self.repo_paths.clone(),
        };
        let (tx, rx) = std::sync::mpsc::channel();
        self.uninstall_rx = Some(rx);
        self.phase = UninstallPhase::Working;
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = run_uninstall(&input).map_err(|e| format!("{e:#}"));
            let _ = tx.send(result);
            ctx.request_repaint();
        });
    }

    fn on_primary(&mut self, ctx: &egui::Context) {
        match &self.phase {
            UninstallPhase::Done(_) => {
                ctx.send_viewport_cmd(ViewportCommand::Close);
                return;
            }
            UninstallPhase::Failed(_) => {
                self.start_uninstall(ctx);
                return;
            }
            UninstallPhase::Working => return,
            UninstallPhase::Editing => {}
        }

        match self.step {
            UninstallStep::Scope => self.set_step(UninstallStep::Repos),
            UninstallStep::Repos => self.set_step(UninstallStep::Confirm),
            UninstallStep::Confirm if self.something_selected() => self.start_uninstall(ctx),
            UninstallStep::Confirm => {}
        }
    }

    fn screen_scope(&mut self, ui: &mut egui::Ui) {
        section(
            ui,
            "What should we remove?",
            "Choose whether to remove the global Studio Stud installation.",
        );
        card(ui, |ui| {
            checkbox_row(
                ui,
                &mut self.remove_user,
                "Remove user installation (daemon, plugin copy, config)",
            );
            ui.add_space(S);
            ui.label(
                egui::RichText::new(
                    "This deletes the install folder, removes the plugin from your Plugins \
                     directory, and clears registry config.",
                )
                .color(theme::MUTED)
                .size(12.0),
            );
        });
    }

    fn screen_repos(&mut self, ui: &mut egui::Ui) {
        section(
            ui,
            "Repo cleanup",
            "Optionally remove .studio-stud folders from registered projects.",
        );
        if self.repo_paths.is_empty() {
            card(ui, |ui| {
                ui.label(
                    egui::RichText::new("No registered repos to clean up.")
                        .color(theme::MUTED)
                        .italics(),
                );
            });
            return;
        }

        let row_h = 34.0;
        let box_h = ui.available_height().clamp(140.0, 300.0);
        egui::Frame::none()
            .fill(SURFACE)
            .stroke(egui::Stroke::new(1.5, theme::BORDER))
            .rounding(egui::Rounding::same(theme::R_CARD))
            .inner_margin(egui::Margin::same(S))
            .show(ui, |ui| {
                ui.set_height(box_h);
                ui.set_width(ui.available_width());
                let avail_w = ui.available_width();
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        let count = self.repo_paths.len();
                        for (i, (path, sel)) in self.repo_paths.iter_mut().enumerate() {
                            let (rect, _) = ui
                                .allocate_exact_size(egui::vec2(avail_w, row_h), egui::Sense::hover());
                            if i + 1 < count {
                                ui.painter().line_segment(
                                    [rect.left_bottom(), rect.right_bottom()],
                                    egui::Stroke::new(1.0, HAIRLINE),
                                );
                            }
                            let inner = rect.shrink2(egui::vec2(S, 0.0));
                            let max_chars = (inner.width() / 7.5) as usize;
                            let shown = theme::truncate_middle(path, max_chars);
                            let mut row_ui = ui.new_child(
                                egui::UiBuilder::new()
                                    .max_rect(inner)
                                    .layout(egui::Layout::left_to_right(egui::Align::Center)),
                            );
                            checkbox_row(&mut row_ui, sel, &shown);
                        }
                    });
            });
        ui.add_space(S);
        ui.label(
            egui::RichText::new("Unchecked repos are left unchanged.")
                .color(theme::MUTED)
                .size(11.5),
        );
    }

    fn screen_confirm(&mut self, ui: &mut egui::Ui) {
        match &self.phase.clone() {
            UninstallPhase::Working => {
                section(ui, "Removing", "Please wait while Studio Stud is removed.");
                let frac = ui
                    .ctx()
                    .animate_value_with_time(egui::Id::new("uninstall_progress"), 0.92, 4.0);
                progress_card(ui, "Uninstalling…", frac);
                return;
            }
            UninstallPhase::Done(msg) => {
                section(ui, "All done", "Studio Stud has been removed.");
                success_card(ui, msg);
                return;
            }
            UninstallPhase::Failed(err) => {
                section(ui, "Failed", "Something went wrong while removing.");
                error_card(ui, err);
                return;
            }
            UninstallPhase::Editing => {}
        }

        section(ui, "Review and uninstall", "Confirm what will be removed.");
        let selected: Vec<&str> = self
            .repo_paths
            .iter()
            .filter(|(_, s)| *s)
            .map(|(p, _)| p.as_str())
            .collect();
        card(ui, |ui| {
            summary_field(
                ui,
                "User installation",
                if self.remove_user {
                    "Remove (daemon, plugin, config)"
                } else {
                    "Keep"
                },
            );
            divider(ui);
            ui.label(
                egui::RichText::new(format!("Repos to clean ({})", selected.len()))
                    .color(theme::MUTED)
                    .size(12.5),
            );
            ui.add_space(XS);
            if selected.is_empty() {
                ui.label(
                    egui::RichText::new("None")
                        .color(theme::MUTED)
                        .italics(),
                );
            } else {
                for p in selected {
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new("•").color(theme::ACCENT));
                        ui.add(
                            egui::Label::new(egui::RichText::new(p).color(theme::TEXT).size(13.0))
                                .truncate(),
                        )
                        .on_hover_text(p);
                    });
                }
            }
        });
    }
}

fn run_uninstall(app: &UninstallInputs) -> anyhow::Result<String> {
    let mut cfg = load_config_or_default();
    if app.remove_user {
        let root = PathBuf::from(&cfg.install_root);
        if root.exists() {
            std::fs::remove_dir_all(&root).ok();
        }
        let plugin = PathBuf::from(&cfg.plugins_dir).join("StudioStud.plugin.lua");
        std::fs::remove_file(plugin).ok();
        let _ = studio_stud::setup_core::config::remove_daemon_lock();
    }
    for (path, selected) in &app.repo_paths {
        if !selected {
            continue;
        }
        let p = PathBuf::from(path);
        let _ = std::fs::remove_dir_all(p.join(".studio-stud"));
        cfg.repos.retain(|r| !r.path.eq_ignore_ascii_case(path));
    }
    if app.remove_user {
        cfg = StudioStudConfig::default();
    }
    save_config(&cfg)?;
    Ok("Uninstall complete.".into())
}

fn native_options(title: &str) -> eframe::NativeOptions {
    let size = [820.0, 600.0];
    eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size(size)
            .with_min_inner_size(size)
            .with_max_inner_size(size)
            .with_resizable(false)
            .with_maximize_button(false)
            .with_title(title)
            .with_icon(window_icon()),
        ..Default::default()
    }
}

pub fn run_install_gui() -> eframe::Result<()> {
    let opts = native_options("Studio Stud Setup");
    eframe::run_native(
        "Studio Stud Setup",
        opts,
        Box::new(|cc| {
            apply_theme(&cc.egui_ctx);
            Ok(Box::new(InstallApp::default()))
        }),
    )
}

pub fn run_uninstall_gui() -> eframe::Result<()> {
    let opts = native_options("Studio Stud Uninstall");
    eframe::run_native(
        "Studio Stud Uninstall",
        opts,
        Box::new(|cc| {
            apply_theme(&cc.egui_ctx);
            Ok(Box::new(UninstallApp::default()))
        }),
    )
}
