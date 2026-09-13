use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    Repository, browser, metadata,
    model::{BookmarkInput, UserSettings},
    search,
};

pub const VERSION: u64 = 1;
pub const MAX_LINE: usize = 64 * 1024;
pub const MAX_RESPONSE: usize = 256 * 1024;
pub const MAX_RESULTS: usize = 10;

pub fn parse_request(line: &str) -> Result<Request, &'static str> {
    if line.len() > MAX_LINE {
        return Err("Protocol message is too large");
    }
    serde_json::from_str(line).map_err(|_| "Invalid protocol message")
}

pub fn encode_response(response: &Response) -> Result<String, &'static str> {
    let encoded = serde_json::to_string(response).map_err(|_| "Could not encode response")?;
    if encoded.len() > MAX_RESPONSE {
        return Err("Worker response exceeded safety limit");
    }
    Ok(encoded)
}

#[derive(Debug, Deserialize)]
pub struct Request {
    pub version: u64,
    pub id: u64,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    Hello,
    Search {
        query: String,
        #[serde(default = "default_limit")]
        limit: usize,
        #[serde(default)]
        offset: usize,
        #[serde(default)]
        scope: SearchScope,
    },
    Get {
        bookmark_id: String,
    },
    Add {
        bookmark: BookmarkInput,
    },
    Edit {
        bookmark: BookmarkInput,
    },
    Delete {
        bookmark_id: String,
    },
    Open {
        bookmark_id: String,
        #[serde(default)]
        new_window: bool,
        #[serde(default)]
        browser_id: Option<String>,
    },
    OpenUrl {
        url: String,
        #[serde(default)]
        new_window: bool,
        #[serde(default)]
        browser_id: Option<String>,
    },
    Browsers,
    GetSettings,
    SaveSettings {
        settings: UserSettings,
    },
    Copy {
        bookmark_id: String,
    },
    Duplicate {
        url: String,
    },
    SuggestTags {
        text: String,
    },
    FetchMetadata {
        url: String,
        metadata_request_id: u64,
    },
}
#[derive(Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SearchScope {
    #[default]
    All,
    Tags,
}
fn default_limit() -> usize {
    8
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub version: u64,
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
impl Response {
    pub fn ok(id: u64, result: Value) -> Self {
        Self {
            version: VERSION,
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }
    pub fn error(id: u64, error: impl Into<String>) -> Self {
        Self {
            version: VERSION,
            id,
            ok: false,
            result: None,
            error: Some(error.into()),
        }
    }
}

pub enum Effect {
    Response(Response),
    Metadata {
        response_id: u64,
        metadata_request_id: u64,
        url: String,
    },
}

pub fn handle(repo: &mut Repository, request: Request) -> Effect {
    let id = request.id;
    if request.version != VERSION {
        return Effect::Response(Response::error(id, "Unsupported protocol version"));
    }
    let result: Result<Value, String> = match request.command {
        Command::Hello => Ok(json!({"protocolVersion":VERSION,"maxResults":MAX_RESULTS})),
        Command::Search {
            query,
            limit,
            offset,
            scope,
        } => {
            if query.len() > 8192 {
                Err("Query is too long".into())
            } else {
                let tags_only = scope == SearchScope::Tags;
                let duplicate = (!tags_only)
                    .then(|| {
                        crate::url_key::normalize_url(&query)
                            .ok()
                            .and_then(|_| repo.find_url(&query).ok().flatten())
                    })
                    .flatten();
                let exact_match = duplicate.is_some();
                let page_limit = limit.clamp(1, MAX_RESULTS);
                let page_offset = if query.trim().is_empty() {
                    0
                } else {
                    offset.min(repo.all().len())
                };
                let fetch_limit = page_offset.saturating_add(page_limit).saturating_add(1);
                let mut rows = if tags_only {
                    search::rank_tags(repo.all(), &query, fetch_limit)
                } else {
                    search::rank(repo.all(), &query, fetch_limit)
                };
                // An exact URL match always leads, followed by the best related results.
                if let Some(item) = duplicate {
                    rows.retain(|row| row.id != item.id);
                    rows.insert(0, item);
                }
                let has_more = rows.len() > page_offset.saturating_add(page_limit);
                let rows: Vec<_> = rows
                    .into_iter()
                    .skip(page_offset)
                    .take(page_limit)
                    .collect();
                Ok(
                    json!({"query":query,"scope":if tags_only { "tags" } else { "all" },"offset":page_offset,"items":rows,"hasMore":has_more,"isUrl":!tags_only && crate::url_key::normalize_url(&query).is_ok(),"exactMatch":exact_match}),
                )
            }
        }
        Command::Get { bookmark_id } => Ok(json!({"bookmark":repo.get(&bookmark_id)})),
        Command::Add { bookmark } => repo
            .add(bookmark)
            .map(|b| json!({"bookmark":b}))
            .map_err(|e| e.to_string()),
        Command::Edit { bookmark } => repo
            .edit(bookmark)
            .map(|b| json!({"bookmark":b}))
            .map_err(|e| e.to_string()),
        Command::Delete { bookmark_id } => repo
            .delete(&bookmark_id)
            .map(|deleted| json!({"deleted":deleted}))
            .map_err(|e| e.to_string()),
        Command::Duplicate { url } => repo
            .find_url(&url)
            .map(|bookmark| json!({"bookmark":bookmark}))
            .map_err(|e| e.to_string()),
        Command::SuggestTags { text } => Ok(json!({"tags":repo.suggestions(&text)})),
        Command::Open {
            bookmark_id,
            new_window,
            browser_id,
        } => open(repo, &bookmark_id, new_window, browser_id.as_deref()),
        Command::OpenUrl {
            url,
            new_window,
            browser_id,
        } => open_url(&url, new_window, browser_id.as_deref()),
        Command::Browsers => browser::discover().map(|browsers| json!({"browsers":browsers})),
        Command::GetSettings => repo
            .settings()
            .map(|settings| json!({"settings":settings}))
            .map_err(|e| e.to_string()),
        Command::SaveSettings { settings } => repo
            .save_settings(settings)
            .map(|settings| json!({"settings":settings,"saved":true}))
            .map_err(|e| e.to_string()),
        Command::Copy { bookmark_id } => copy(repo, &bookmark_id),
        Command::FetchMetadata {
            url,
            metadata_request_id,
        } => {
            return Effect::Metadata {
                response_id: id,
                metadata_request_id,
                url,
            };
        }
    };
    Effect::Response(match result {
        Ok(v) => Response::ok(id, v),
        Err(e) => Response::error(id, e),
    })
}
fn open(
    repo: &mut Repository,
    id: &str,
    new_window: bool,
    browser_id: Option<&str>,
) -> Result<Value, String> {
    let b = repo.get(id).ok_or("Bookmark no longer exists")?;
    launch_url(&b.original_url, new_window, browser_id)?;
    repo.record_open(id).map_err(|e| e.to_string())?;
    Ok(json!({"opened":true}))
}
fn open_url(url: &str, new_window: bool, browser_id: Option<&str>) -> Result<Value, String> {
    let (validated_url, _) = crate::url_key::normalize_url(url)?;
    launch_url(&validated_url, new_window, browser_id)?;
    Ok(json!({"opened":true}))
}
fn launch_url(url: &str, new_window: bool, browser_id: Option<&str>) -> Result<(), String> {
    let mut command;
    if let Some(browser_id) = browser_id {
        let selected = browser::find(browser_id)?;
        command = std::process::Command::new("systemd-run");
        command.args([
            "--user",
            "--quiet",
            "--collect",
            "--property=StandardOutput=null",
            "--property=StandardError=null",
            "uwsm-app",
            "--",
            "gio",
            "launch",
        ]);
        command.arg(selected.desktop_path).arg(url);
    } else {
        command = std::process::Command::new("omarchy-launch-browser");
        if new_window {
            command.arg("--new-window");
        }
        command.arg(url);
    }
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Could not open browser: {e}"))?;
    Ok(())
}
fn copy(repo: &Repository, id: &str) -> Result<Value, String> {
    use std::io::Write;
    let b = repo.get(id).ok_or("Bookmark no longer exists")?;
    let mut child = std::process::Command::new("wl-copy")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Could not start wl-copy: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or("Could not open clipboard input")?
        .write_all(b.original_url.as_bytes())
        .map_err(|e| format!("Could not copy URL: {e}"))?;
    Ok(json!({"copied":true}))
}
pub fn metadata_response(response_id: u64, metadata_request_id: u64, url: &str) -> Response {
    match metadata::fetch(url) {
        Ok(data) => Response::ok(
            response_id,
            json!({"metadataRequestId":metadata_request_id,"metadata":data}),
        ),
        Err(e) => Response::error(response_id, e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_rejects_invalid_and_oversized_messages() {
        assert!(parse_request("not json").is_err());
        assert_eq!(
            parse_request(&"x".repeat(MAX_LINE + 1)).unwrap_err(),
            "Protocol message is too large"
        );
        assert!(parse_request(r#"{"version":1,"id":1,"type":"hello"}"#).is_ok());
    }

    #[test]
    fn output_is_single_bounded_json_line() {
        let encoded = encode_response(&Response::ok(1, json!({"value":"ok"}))).unwrap();
        assert!(encoded.len() <= MAX_RESPONSE);
        assert!(!encoded.contains('\n'));
    }

    #[test]
    fn direct_urls_require_valid_http_or_https_syntax() {
        assert!(open_url("youtube.com", false, None).is_err());
        assert!(open_url("javascript:alert(1)", false, None).is_err());
        assert!(open_url("https://user:pass@example.test", false, None).is_err());
    }
}
