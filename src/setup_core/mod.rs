//! Centralized install registry, channel manifests, crypto, install ops, and health checks.
//! Shared by the daemon (registry resolution, addon routes) and `studio-stud-setup`.

pub mod channels;
pub mod config;
pub mod crypto;
pub mod health;
pub use health::{health_json, repo_health_json};
pub mod install;
pub mod registry;

pub use config::{
    RepoEntry, StudioStudConfig, config_dir, config_path, load_config, load_config_or_default,
    register_repo, save_config,
};
pub use registry::{RepoResolveError, RepoResolver, bind_place_to_repo};
