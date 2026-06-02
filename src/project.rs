pub mod manifest;
pub mod index;
pub mod projection;

pub use manifest::{
    ProjectError, ProjectManifest, ProjectNode, PathNode, effective_ignore_unknown,
    infer_class_name, parse_manifest, resolve_class_name, validate_class_name,
};
pub use index::{FileRole, RepoIndex, RepoIndexEntry, build_index};
pub use projection::{
    DesiredInstance, DesiredProjection, ProjectionError, ProjectionWarning, build_projection,
};
