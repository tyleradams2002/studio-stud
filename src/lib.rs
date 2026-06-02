pub mod util;
pub mod storage;
pub mod capture;
pub mod output;
pub mod http;
pub mod analyze;
pub mod query;
pub mod cli;
pub mod bench;
pub mod live;
pub mod policy;
pub mod write;
pub mod stage3_cli;
pub mod project;
pub mod diff;
pub mod stage4_cli;
pub mod update;

pub use cli::run;

pub fn run_with_args<I, S>(args: I) -> anyhow::Result<()>
where
    I: IntoIterator<Item = S>,
    S: Into<std::ffi::OsString> + Clone,
{
    cli::run_with_args(args)
}
