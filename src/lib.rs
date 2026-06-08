pub mod analyze;
pub mod bench;
pub mod capture;
pub mod cli;
pub mod conn_registry;
pub mod diff;
pub mod http;
pub mod live;
pub mod obs;
pub mod output;
pub mod policy;
pub mod project;
pub mod query;
pub mod reflection;
pub mod serve_workers;
pub mod repomap;
pub mod setup_core;
pub mod stage3_cli;
pub mod stage4_cli;
pub mod storage;
pub mod telemetry;
pub mod tick;
pub mod update;
pub mod util;
pub mod write;

pub use setup_core::registry::RepoResolver;

pub use cli::run;

pub fn run_with_args<I, S>(args: I) -> anyhow::Result<()>
where
    I: IntoIterator<Item = S>,
    S: Into<std::ffi::OsString> + Clone,
{
    cli::run_with_args(args)
}
