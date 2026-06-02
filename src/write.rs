pub mod file;
pub mod safety;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockedReason {
    TokenInvalid,
    BadRequest,
    NoPolicy,
    PathNotAllowed,
    PlaceMismatch,
    InvalidUtf8,
    Oversize,
    HeaderMissing,
    ParseError,
    HashMismatch,
    InternalError,
}

impl BlockedReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TokenInvalid => "tokenInvalid",
            Self::BadRequest => "badRequest",
            Self::NoPolicy => "noPolicy",
            Self::PathNotAllowed => "pathNotAllowed",
            Self::PlaceMismatch => "placeMismatch",
            Self::InvalidUtf8 => "invalidUtf8",
            Self::Oversize => "oversize",
            Self::HeaderMissing => "headerMissing",
            Self::ParseError => "parseError",
            Self::HashMismatch => "hashMismatch",
            Self::InternalError => "internalError",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteMode {
    Validate,
    Preview,
    Apply,
}

#[derive(Debug, Clone)]
pub struct WriteRequest<'a> {
    pub path: &'a str,
    pub content: &'a [u8],
    pub expected_hash: Option<&'a str>,
    pub generated_by: Option<&'a str>,
    pub place_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteOutcome {
    pub ok: bool,
    pub blocked: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub path: String,
    pub changed: bool,
    pub diff: String,
    pub bytes: u64,
    pub hash_before: String,
    pub hash_after: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generated_by: Option<String>,
}

impl WriteOutcome {
    pub fn blocked(reason: BlockedReason, path: &str, detail: Option<String>) -> Self {
        Self {
            ok: false,
            blocked: true,
            blocked_reason: Some(reason.as_str().to_string()),
            detail,
            path: path.to_string(),
            changed: false,
            diff: String::new(),
            bytes: 0,
            hash_before: String::new(),
            hash_after: String::new(),
            generated_by: None,
        }
    }

    pub fn success(
        path: &str,
        changed: bool,
        diff: String,
        bytes: u64,
        hash_before: String,
        hash_after: String,
        generated_by: Option<String>,
    ) -> Self {
        Self {
            ok: true,
            blocked: false,
            blocked_reason: None,
            detail: None,
            path: path.to_string(),
            changed,
            diff,
            bytes,
            hash_before,
            hash_after,
            generated_by,
        }
    }
}
