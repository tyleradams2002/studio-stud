use std::path::PathBuf;

use eframe::egui;
use studio_stud::setup_core::config::{StudioStudConfig, load_config_or_default, register_repo, save_config};
use studio_stud::setup_core::install::{
    copy_addon_payloads_from_repo, default_install_root, default_plugins_dir, install_core_plugin,
    install_path_shim, is_valid_repo_root, lay_tool_payload, repo_already_registered,
    write_starter_policy,
};
use studio_stud::setup_core::install::migrate_legacy_repo;

#[derive(Default, PartialEq, Eq)]
enum InstallStep {
    #[default]
    Location,
    PluginsDir,
    Repos,
    Confirm,
}

pub struct InstallApp {
    step: InstallStep,
    install_root: String,
    plugins_dir: String,
    plugins_warning: bool,
    repo_input: String,
    repos: Vec<String>,
    repo_messages: Vec<String>,
    status: String,
    done: bool,
}

impl Default for InstallApp {
    fn default() -> Self {
        let plugins = default_plugins_dir();
        let exists = plugins.is_dir();
        Self {
            step: InstallStep::Location,
            install_root: default_install_root().display().to_string(),
            plugins_dir: plugins.display().to_string(),
            plugins_warning: !exists,
            repo_input: String::new(),
            repos: Vec::new(),
            repo_messages: Vec::new(),
            status: String::new(),
            done: false,
        }
    }
}

impl eframe::App for InstallApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Studio Stud Installer");
            match self.step {
                InstallStep::Location => {
                    ui.label("Step 1: Install location");
                    ui.text_edit_singleline(&mut self.install_root);
                    if ui.button("Browse…").clicked()
                        && let Some(p) = rfd::FileDialog::new().pick_folder()
                    {
                        self.install_root = p.display().to_string();
                    }
                    if ui.button("Next").clicked() {
                        self.step = InstallStep::PluginsDir;
                    }
                }
                InstallStep::PluginsDir => {
                    ui.label("Step 2: Roblox Plugins folder");
                    if self.plugins_warning {
                        ui.colored_label(
                            egui::Color32::YELLOW,
                            "Default plugins folder not found. Select a valid folder to continue.",
                        );
                    }
                    ui.text_edit_singleline(&mut self.plugins_dir);
                    if ui.button("Browse…").clicked()
                        && let Some(p) = rfd::FileDialog::new().pick_folder()
                    {
                        self.plugins_dir = p.display().to_string();
                        self.plugins_warning = false;
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.step = InstallStep::Location;
                        }
                        let can_next = PathBuf::from(&self.plugins_dir).is_dir();
                        if ui.add_enabled(can_next, egui::Button::new("Next")).clicked() {
                            self.step = InstallStep::Repos;
                        }
                    });
                }
                InstallStep::Repos => {
                    ui.label("Step 3: Register repo paths");
                    ui.horizontal(|ui| {
                        ui.text_edit_singleline(&mut self.repo_input);
                        if ui.button("Add").clicked() {
                            let p = PathBuf::from(self.repo_input.trim());
                            if !is_valid_repo_root(&p) {
                                self.repo_messages.push(format!(
                                    "Not a repo root: {}",
                                    p.display()
                                ));
                            } else if self.repos.iter().any(|r| {
                                PathBuf::from(r)
                                    .canonicalize()
                                    .ok()
                                    .zip(p.canonicalize().ok())
                                    .map(|(a, b)| a == b)
                                    .unwrap_or(false)
                            }) {
                                self.repo_messages
                                    .push("Already in list".into());
                            } else {
                                let mut cfg = load_config_or_default();
                                if repo_already_registered(&cfg, &p) {
                                    self.repo_messages.push(format!(
                                        "Already installed: {}",
                                        p.display()
                                    ));
                                } else {
                                    self.repos.push(p.display().to_string());
                                }
                            }
                            self.repo_input.clear();
                        }
                    });
                    let mut remove_idx = None;
                    for (i, r) in self.repos.iter().enumerate() {
                        ui.horizontal(|ui| {
                            ui.label(r);
                            if ui.button("Remove").clicked() {
                                remove_idx = Some(i);
                            }
                        });
                    }
                    if let Some(i) = remove_idx {
                        self.repos.remove(i);
                    }
                    for m in &self.repo_messages {
                        ui.label(m);
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.step = InstallStep::PluginsDir;
                        }
                        if ui.button("Next").clicked() {
                            self.step = InstallStep::Confirm;
                        }
                    });
                }
                InstallStep::Confirm => {
                    ui.label("Step 4: Confirm & Install");
                    ui.label(format!("Install: {}", self.install_root));
                    ui.label(format!("Plugins: {}", self.plugins_dir));
                    ui.label(format!("Repos: {}", self.repos.len()));
                    if self.done {
                        ui.label(&self.status);
                    } else if ui.button("Install").clicked() {
                        match run_install(self) {
                            Ok(msg) => {
                                self.status = msg;
                                self.done = true;
                            }
                            Err(e) => self.status = format!("Error: {e:#}"),
                        }
                    }
                    if ui.button("Back").clicked() && !self.done {
                        self.step = InstallStep::Repos;
                    }
                }
            }
        });
    }
}

fn run_install(app: &InstallApp) -> anyhow::Result<String> {
    let install_root = PathBuf::from(&app.install_root);
    let plugins_dir = PathBuf::from(&app.plugins_dir);
    let dev_repo = std::env::current_dir().ok();
    let daemon_src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("bin")
        .join("studio-stud.exe");
    let plugin_src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("plugin")
        .join("StudioStud.plugin.lua");
    if !daemon_src.is_file() {
        return Err(anyhow::anyhow!(
            "Build studio-stud first: .\\scripts\\build-local.ps1"
        ));
    }
    lay_tool_payload(&install_root, &daemon_src, &plugin_src)?;
    if let Some(repo) = &dev_repo {
        copy_addon_payloads_from_repo(repo, &install_root)?;
    }
    install_core_plugin(&plugins_dir, &plugin_src)?;
    install_path_shim(&install_root)?;
    let mut cfg = load_config_or_default();
    cfg.install_root = install_root.display().to_string();
    cfg.plugins_dir = plugins_dir.display().to_string();
    cfg.channel = "release".into();
    cfg.versions.daemon = env!("CARGO_PKG_VERSION").into();
    for r in &app.repos {
        let p = PathBuf::from(r);
        register_repo(&mut cfg, &p)?;
        write_starter_policy(&p)?;
        let _ = migrate_legacy_repo(&p, &mut cfg);
    }
    save_config(&cfg)?;
    Ok(format!(
        "Installed to {}. Open a new terminal for `studio-stud` on PATH.",
        install_root.display()
    ))
}

#[derive(Default, PartialEq, Eq)]
enum UninstallStep {
    #[default]
    User,
    Repos,
    Confirm,
}

pub struct UninstallApp {
    step: UninstallStep,
    remove_user: bool,
    repo_paths: Vec<(String, bool)>,
    status: String,
    done: bool,
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
            step: UninstallStep::User,
            remove_user: true,
            repo_paths,
            status: String::new(),
            done: false,
        }
    }
}

impl eframe::App for UninstallApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Studio Stud Uninstaller");
            match self.step {
                UninstallStep::User => {
                    ui.checkbox(&mut self.remove_user, "Remove user installation (tool, plugin, config)");
                    if ui.button("Next").clicked() {
                        self.step = UninstallStep::Repos;
                    }
                }
                UninstallStep::Repos => {
                    ui.label("Uninstall from repos (unchecked by default):");
                    for item in &mut self.repo_paths {
                        ui.checkbox(&mut item.1, &item.0);
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Back").clicked() {
                            self.step = UninstallStep::User;
                        }
                        if ui.button("Next").clicked() {
                            self.step = UninstallStep::Confirm;
                        }
                    });
                }
                UninstallStep::Confirm => {
                    if self.done {
                        ui.label(&self.status);
                    } else if ui.button("Uninstall").clicked() {
                        self.status = run_uninstall(self).unwrap_or_else(|e| format!("{e:#}"));
                        self.done = true;
                    }
                }
            }
        });
    }
}

fn run_uninstall(app: &UninstallApp) -> anyhow::Result<String> {
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

pub fn run_install_gui() -> eframe::Result<()> {
    let opts = eframe::NativeOptions::default();
    eframe::run_native(
        "Studio Stud Setup",
        opts,
        Box::new(|_cc| Ok(Box::new(InstallApp::default()))),
    )
}

pub fn run_uninstall_gui() -> eframe::Result<()> {
    let opts = eframe::NativeOptions::default();
    eframe::run_native(
        "Studio Stud Uninstall",
        opts,
        Box::new(|_cc| Ok(Box::new(UninstallApp::default()))),
    )
}
