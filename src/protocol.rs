use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    Repository, import,
    library::BackupReason,
    metadata,
    model::{BookmarkInput, DefaultResultOrder, UserSettings},
    search,
};

pub const VERSION: u64 = 1;
pub const MAX_LINE: usize = 64 * 1024;
pub const MAX_RESPONSE: usize = 256 * 1024;
pub const MAX_RESULTS: usize = 10;
/// Space kept free for the response envelope and non-item fields.
const RESPONSE_OVERHEAD: usize = 4 * 1024;
/// Restore choices shown at once; older backups remain on disk.
const MAX_REPORTED_BACKUPS: usize = 30;

/// Parses one request line. Failures carry the request ID when it can be
/// recovered, so the client can resolve that request instead of waiting.
pub fn parse_request(line: &str) -> Result<Request, (u64, &'static str)> {
    if line.len() > MAX_LINE {
        return Err((0, "Protocol message is too large"));
    }
    serde_json::from_str(line).map_err(|_| {
        let id = serde_json::from_str::<Value>(line)
            .ok()
            .and_then(|value| value.get("id").and_then(Value::as_u64))
            .unwrap_or(0);
        (id, "Invalid protocol message")
    })
}

/// Encodes a response as a single line. A response that would exceed the
/// line limit is replaced by an error for the same request, never dropped.
pub fn encode_response(response: &Response) -> String {
    match serde_json::to_string(response) {
        Ok(encoded) if encoded.len() <= MAX_RESPONSE => encoded,
        Ok(_) => fallback(response.id, "Worker response exceeded safety limit"),
        Err(_) => fallback(response.id, "Could not encode response"),
    }
}
fn fallback(id: u64, message: &str) -> String {
    serde_json::to_string(&Response::error(id, message))
        .unwrap_or_else(|_| format!(r#"{{"version":{VERSION},"id":{id},"ok":false}}"#))
}
fn encoded_len(value: &impl Serialize) -> usize {
    serde_json::to_string(value).map_or(usize::MAX, |text| text.len())
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
    },
    OpenUrl {
        url: String,
        #[serde(default)]
        new_window: bool,
    },
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
    ImportSources,
    ImportPreview {
        source_id: String,
    },
    ImportBookmarks {
        source_id: String,
    },
    BackupCreate,
    BackupsList,
    BackupRestore {
        name: String,
    },
    LibraryClear,
    LibraryLoadExamples,
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
                let default_order = if query.trim().is_empty() {
                    repo.settings()
                        .map(|settings| settings.default_result_order)
                        .unwrap_or(DefaultResultOrder::MostUsed)
                } else {
                    DefaultResultOrder::MostUsed
                };
                let mut rows = if tags_only {
                    search::rank_tags_in_order(repo.all(), &query, fetch_limit, default_order)
                } else {
                    search::rank_in_order(repo.all(), &query, fetch_limit, default_order)
                };
                // An exact URL match always leads, followed by the best related results.
                if let Some(item) = duplicate {
                    rows.retain(|row| row.id != item.id);
                    rows.insert(0, item);
                }
                let mut has_more = rows.len() > page_offset.saturating_add(page_limit);
                // Keep the page within the response limit; the client asks for
                // the rest by offset, so a shortened page only adds a round trip.
                let mut budget = MAX_RESPONSE
                    .saturating_sub(RESPONSE_OVERHEAD)
                    .saturating_sub(encoded_len(&query));
                let mut page = Vec::new();
                for row in rows.into_iter().skip(page_offset).take(page_limit) {
                    let size = encoded_len(&row).saturating_add(1);
                    if size > budget && !page.is_empty() {
                        has_more = true;
                        break;
                    }
                    budget = budget.saturating_sub(size);
                    page.push(row);
                }
                let rows = page;
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
        } => open(repo, &bookmark_id, new_window),
        Command::OpenUrl {
            url,
            new_window,
        } => open_url(&url, new_window),
        Command::GetSettings => repo
            .settings()
            .map(|settings| json!({"settings":settings}))
            .map_err(|e| e.to_string()),
        Command::SaveSettings { settings } => repo
            .save_settings(settings)
            .map(|settings| json!({"settings":settings,"saved":true}))
            .map_err(|e| e.to_string()),
        Command::Copy { bookmark_id } => copy(repo, &bookmark_id),
        Command::ImportSources => import::discover().map(|sources| json!({"importSources":sources})),
        Command::ImportPreview { source_id } => read_import(repo, &source_id)
            .map(|(source, read)| {
                json!({"importPreview":{"browser":source.browser,"profile":source.profile,"sourceId":source.id,"counts":repo.preview_import(&read)}})
            }),
        Command::ImportBookmarks { source_id } => read_import(repo, &source_id).and_then(|(_, read)| {
            repo.import(read)
                .map(|summary| json!({"imported":summary}))
                .map_err(|e| e.to_string())
        }),
        Command::BackupCreate => repo
            .create_backup(BackupReason::Manual)
            .map(|backup| json!({"backupCreated":backup}))
            .map_err(|e| e.to_string()),
        Command::BackupsList => repo
            .list_backups()
            .map(|mut backups| {
                backups.truncate(MAX_REPORTED_BACKUPS);
                json!({"backups":backups})
            })
            .map_err(|e| e.to_string()),
        Command::BackupRestore { name } => repo
            .restore_backup(&name)
            .map(|backup| json!({"restored":{"bookmarks":repo.all().len(),"backup":backup}}))
            .map_err(|e| e.to_string()),
        Command::LibraryClear => repo
            .clear_library()
            .map(|(removed, backup)| json!({"cleared":{"removed":removed,"backup":backup}}))
            .map_err(|e| e.to_string()),
        Command::LibraryLoadExamples => repo
            .load_examples()
            .map(|(added, backup)| json!({"examplesLoaded":{"added":added,"backup":backup}}))
            .map_err(|e| e.to_string()),
        Command::FetchMetadata {
            url,
            metadata_request_id,
        } => match metadata_allowed(repo, &url) {
            Ok(url) => {
                return Effect::Metadata {
                    response_id: id,
                    metadata_request_id,
                    url,
                };
            }
            Err(e) => Err(e),
        },
    };
    Effect::Response(match result {
        Ok(v) => Response::ok(id, v),
        Err(e) => Response::error(id, e),
    })
}
/// Reads a source only if discovery finds it, so a request cannot name an
/// arbitrary file.
fn read_import(
    repo: &Repository,
    source_id: &str,
) -> Result<(import::ImportSource, import::ImportRead), String> {
    let source = import::find(source_id)?;
    let scratch = repo.scratch_dir().map_err(|e| e.to_string())?;
    let read = import::read(&source, &scratch)?;
    Ok((source, read))
}
/// The worker enforces the page-lookup opt-in itself; missing or unreadable
/// settings never authorize a network request.
fn metadata_allowed(repo: &Repository, url: &str) -> Result<String, String> {
    let enabled = repo.settings().is_ok_and(|s| s.fetch_page_details);
    if !enabled {
        return Err("Fetching page details is turned off".into());
    }
    crate::url_key::normalize_url(url).map(|(url, _)| url)
}
fn open(repo: &mut Repository, id: &str, new_window: bool) -> Result<Value, String> {
    let b = repo.get(id).ok_or("Bookmark no longer exists")?;
    // Stored URLs are validated again so an edited database cannot pass
    // arbitrary arguments to the browser launcher.
    let (validated_url, _) = crate::url_key::normalize_url(&b.original_url)?;
    launch_url(&validated_url, new_window)?;
    repo.record_open(id).map_err(|e| e.to_string())?;
    Ok(json!({"opened":true}))
}
fn open_url(url: &str, new_window: bool) -> Result<Value, String> {
    let (validated_url, _) = crate::url_key::normalize_url(url)?;
    launch_url(&validated_url, new_window)?;
    Ok(json!({"opened":true}))
}
fn launch_url(url: &str, new_window: bool) -> Result<(), String> {
    let mut command = std::process::Command::new("omarchy-launch-browser");
    if new_window {
        command.arg("--new-window");
    }
    command.arg(url);
    let child = command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Could not open browser: {e}"))?;
    reap(child);
    Ok(())
}
/// The worker is long-lived, so every launched helper is waited on to avoid
/// accumulating zombie processes.
fn reap(mut child: std::process::Child) {
    std::thread::spawn(move || {
        let _ = child.wait();
    });
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
    let written = match child.stdin.take() {
        Some(mut stdin) => stdin
            .write_all(b.original_url.as_bytes())
            .map_err(|e| format!("Could not copy URL: {e}")),
        None => Err("Could not open clipboard input".into()),
    };
    reap(child);
    written?;
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
        assert_eq!(parse_request("not json").unwrap_err().0, 0);
        assert_eq!(
            parse_request(&"x".repeat(MAX_LINE + 1)).unwrap_err(),
            (0, "Protocol message is too large")
        );
        assert_eq!(
            parse_request(r#"{"version":1,"id":7,"type":"unknown"}"#).unwrap_err(),
            (7, "Invalid protocol message")
        );
        assert!(parse_request(r#"{"version":1,"id":1,"type":"hello"}"#).is_ok());
    }

    #[test]
    fn output_is_single_bounded_json_line() {
        let encoded = encode_response(&Response::ok(1, json!({"value":"ok"})));
        assert!(encoded.len() <= MAX_RESPONSE);
        assert!(!encoded.contains('\n'));
    }

    #[test]
    fn oversized_responses_become_errors_for_the_same_request() {
        let huge = "x".repeat(MAX_RESPONSE + 1);
        let encoded = encode_response(&Response::ok(42, json!({"value":huge})));
        let parsed: Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(parsed["id"], 42);
        assert_eq!(parsed["ok"], false);
    }

    #[test]
    fn removed_multi_browser_requests_are_rejected() {
        for request in [
            r#"{"version":1,"id":8,"type":"browsers"}"#,
            r#"{"version":1,"id":9,"type":"open_all","bookmark_id":"bookmark-1"}"#,
            r#"{"version":1,"id":10,"type":"open_url_all","url":"https://example.test"}"#,
        ] {
            assert!(parse_request(request).is_err(), "{request}");
        }
    }

    #[test]
    fn direct_urls_require_valid_http_or_https_syntax() {
        assert!(open_url("youtube.com", false).is_err());
        assert!(open_url("javascript:alert(1)", false).is_err());
        assert!(open_url("https://user:pass@example.test", false).is_err());
    }
}
