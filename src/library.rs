//! Whole-library operations: backups, restore, import, clearing, and example
//! bookmarks. Every operation that replaces or adds many bookmarks first saves
//! an automatic backup, so it can be undone from the restore list.

use std::{
    collections::HashSet,
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags, params};
use serde::Serialize;
use uuid::Uuid;

use crate::{
    Repository, RepositoryError,
    import::ImportRead,
    repository::{MAX_BOOKMARKS, MAX_STORE_BYTES, SCHEMA_VERSION, replace_tags},
    url_key::normalize_url,
};

/// Automatic backups kept; the oldest are removed after a new one is saved.
const KEEP_AUTOMATIC: usize = 20;
/// Manual backups kept, so a long-lived library cannot fill the disk.
const KEEP_MANUAL: usize = 50;
const BACKUP_PREFIX: &str = "bookmarks-";
const DELETE_LIBRARY: &str = "DELETE FROM bookmark_tags; DELETE FROM bookmarks; DELETE FROM tags;";
const BACKUP_SUFFIX: &str = ".sqlite3";
/// A backup can hold a full store plus SQLite's page overhead.
const MAX_BACKUP_BYTES: u64 = MAX_STORE_BYTES * 3;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BackupReason {
    Manual,
    BeforeRestore,
    BeforeImport,
    BeforeClear,
    BeforeExamples,
}

impl BackupReason {
    fn slug(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::BeforeRestore => "before-restore",
            Self::BeforeImport => "before-import",
            Self::BeforeClear => "before-clear",
            Self::BeforeExamples => "before-examples",
        }
    }
    fn from_slug(slug: &str) -> Option<Self> {
        [
            Self::Manual,
            Self::BeforeRestore,
            Self::BeforeImport,
            Self::BeforeClear,
            Self::BeforeExamples,
        ]
        .into_iter()
        .find(|reason| reason.slug() == slug)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupInfo {
    /// File name inside the backups directory; restores accept only this.
    pub name: String,
    pub created_at: i64,
    pub reason: &'static str,
    pub bookmarks: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportSummary {
    pub added: usize,
    pub already_saved: usize,
    pub skipped: usize,
    pub backup: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPreview {
    pub found: usize,
    pub new: usize,
    pub already_saved: usize,
    pub skipped: usize,
}

impl Repository {
    pub fn backups_dir(&self) -> PathBuf {
        self.data_dir.join("backups")
    }

    /// A private scratch location for import copies, inside the data dir.
    pub fn scratch_dir(&self) -> Result<PathBuf, RepositoryError> {
        let path = self.data_dir.clone();
        ensure_private_dir(&path)?;
        Ok(path)
    }

    pub fn create_backup(&self, reason: BackupReason) -> Result<BackupInfo, RepositoryError> {
        let directory = self.backups_dir();
        ensure_private_dir(&directory)?;
        let now = Utc::now();
        let stamp = now.format("%Y%m%dT%H%M%S%3fZ");
        let mut name = format!("{BACKUP_PREFIX}{stamp}-{}{BACKUP_SUFFIX}", reason.slug());
        let mut counter = 1;
        while fs::symlink_metadata(directory.join(&name)).is_ok() {
            name = format!(
                "{BACKUP_PREFIX}{stamp}-{counter}-{}{BACKUP_SUFFIX}",
                reason.slug()
            );
            counter += 1;
        }
        // Written under a temporary name and renamed, so the list never shows
        // a half-written backup.
        let temporary = directory.join(format!(".{}.partial", Uuid::new_v4()));
        let result = self
            .conn
            .execute("VACUUM INTO ?", [temporary.to_string_lossy().as_ref()])
            .map_err(RepositoryError::from)
            .and_then(|_| {
                fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
                fs::rename(&temporary, directory.join(&name))?;
                Ok(())
            });
        if let Err(error) = result {
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }
        self.prune_backups()?;
        Ok(BackupInfo {
            name,
            created_at: now.timestamp_millis(),
            reason: reason.slug(),
            bookmarks: self.index.len() as i64,
        })
    }

    /// Saves an automatic backup unless the library is empty, when there is
    /// nothing to lose.
    fn backup_before(&self, reason: BackupReason) -> Result<Option<String>, RepositoryError> {
        if self.index.is_empty() {
            return Ok(None);
        }
        self.create_backup(reason).map(|backup| Some(backup.name))
    }

    pub fn list_backups(&self) -> Result<Vec<BackupInfo>, RepositoryError> {
        let mut backups: Vec<BackupInfo> = self
            .backup_files()?
            .into_iter()
            .filter_map(|(name, created_at, reason)| {
                let bookmarks = count_bookmarks(&self.backups_dir().join(&name)).ok()?;
                Some(BackupInfo {
                    name,
                    created_at,
                    reason: reason.slug(),
                    bookmarks,
                })
            })
            .collect();
        backups.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(b.name.cmp(&a.name)));
        Ok(backups)
    }

    /// Replaces the bookmarks and tags with those in a backup. Settings are
    /// kept. The current library is backed up first.
    pub fn restore_backup(&mut self, name: &str) -> Result<Option<String>, RepositoryError> {
        let path = self.backup_path(name)?;
        let uri = backup_uri(&path)?;
        self.conn.execute("ATTACH DATABASE ? AS source", [&uri])?;
        let result = self.restore_attached();
        let detached = self.conn.execute("DETACH DATABASE source", []);
        let safety = result?;
        detached?;
        self.refresh_index()?;
        Ok(safety)
    }

    fn restore_attached(&mut self) -> Result<Option<String>, RepositoryError> {
        let check: String = self
            .conn
            .query_row("PRAGMA source.quick_check", [], |row| row.get(0))?;
        if check != "ok" {
            return Err(invalid_backup());
        }
        let tables: i64 = self.conn.query_row(
            "SELECT count(*) FROM source.sqlite_master WHERE type='table'
               AND name IN ('bookmarks','tags','bookmark_tags','schema_migrations')",
            [],
            |row| row.get(0),
        )?;
        if tables != 4 {
            return Err(invalid_backup());
        }
        let version: i64 = self.conn.query_row(
            "SELECT COALESCE(max(version), 0) FROM source.schema_migrations",
            [],
            |row| row.get(0),
        )?;
        if version > SCHEMA_VERSION {
            return Err(RepositoryError::Validation(
                "That backup was made by a newer version of Bookmarks".into(),
            ));
        }
        self.check_bounds_in("source")?;
        let safety = self.backup_before(BackupReason::BeforeRestore)?;
        let tx = self.conn.transaction()?;
        tx.execute_batch(
            "DELETE FROM main.bookmark_tags;
             DELETE FROM main.bookmarks;
             DELETE FROM main.tags;
             INSERT INTO main.tags(id, name) SELECT id, name FROM source.tags;
             INSERT INTO main.bookmarks(id, original_url, normalized_url_key, title, description,
               keyword, created_at, modified_at, usage_score, last_opened_at)
               SELECT id, original_url, normalized_url_key, title, description, keyword,
                 created_at, modified_at, usage_score, last_opened_at FROM source.bookmarks;
             INSERT INTO main.bookmark_tags(bookmark_id, tag_id)
               SELECT bookmark_id, tag_id FROM source.bookmark_tags;",
        )?;
        tx.commit()?;
        Ok(safety)
    }

    pub fn clear_library(&mut self) -> Result<(usize, Option<String>), RepositoryError> {
        let backup = self.backup_before(BackupReason::BeforeClear)?;
        let removed = self.index.len();
        let tx = self.conn.transaction()?;
        tx.execute_batch(DELETE_LIBRARY)?;
        tx.commit()?;
        self.refresh_index()?;
        Ok((removed, backup))
    }

    /// Replaces the library with a small set of example bookmarks, for trying
    /// the launcher or taking screenshots.
    pub fn load_examples(&mut self) -> Result<(usize, Option<String>), RepositoryError> {
        let backup = self.backup_before(BackupReason::BeforeExamples)?;
        let now = Utc::now().timestamp_millis();
        let tx = self.conn.transaction()?;
        tx.execute_batch(DELETE_LIBRARY)?;
        for (position, example) in EXAMPLES.iter().enumerate() {
            let (url, key) = normalize_url(example.url).map_err(RepositoryError::Validation)?;
            let id = Uuid::new_v4().to_string();
            // Earlier examples are "used" more, so the empty view shows them first.
            let usage = (EXAMPLES.len() - position) as f64;
            let opened = now - (position as i64) * 3_600_000;
            tx.execute(
                "INSERT INTO bookmarks(id,original_url,normalized_url_key,title,description,keyword,created_at,modified_at,usage_score,last_opened_at)
                 VALUES(?,?,?,?,?,?,?,?,?,?)",
                params![id, url, key, example.title, example.description, example.keyword, now, now, usage, opened],
            )?;
            let tags: Vec<String> = example.tags.iter().map(|tag| tag.to_string()).collect();
            replace_tags(&tx, &id, &tags)?;
        }
        tx.commit()?;
        self.refresh_index()?;
        Ok((EXAMPLES.len(), backup))
    }

    pub fn preview_import(&self, read: &ImportRead) -> ImportPreview {
        let existing = self.existing_keys();
        let already_saved = read
            .bookmarks
            .iter()
            .filter(|bookmark| existing.contains(&bookmark.key))
            .count();
        ImportPreview {
            found: read.bookmarks.len() + read.duplicates + read.skipped,
            new: read.bookmarks.len() - already_saved,
            already_saved,
            skipped: read.skipped + read.duplicates,
        }
    }

    /// Adds the bookmarks that are not saved yet, in one transaction.
    /// Bookmarks that already exist are left unchanged.
    pub fn import(&mut self, read: ImportRead) -> Result<ImportSummary, RepositoryError> {
        let preview = self.preview_import(&read);
        if preview.new == 0 {
            return Ok(ImportSummary {
                added: 0,
                already_saved: preview.already_saved,
                skipped: preview.skipped,
                backup: None,
            });
        }
        if self.index.len() + preview.new > MAX_BOOKMARKS {
            return Err(RepositoryError::Validation(format!(
                "Importing would exceed the {MAX_BOOKMARKS}-bookmark limit"
            )));
        }
        let backup = self.backup_before(BackupReason::BeforeImport)?;
        let existing = self.existing_keys();
        let now = Utc::now().timestamp_millis();
        let tx = self.conn.transaction()?;
        let mut added = 0;
        for bookmark in read.bookmarks {
            if existing.contains(&bookmark.key) {
                continue;
            }
            let id = Uuid::new_v4().to_string();
            let created = if bookmark.created_at > 0 {
                bookmark.created_at
            } else {
                now
            };
            tx.execute(
                "INSERT INTO bookmarks(id,original_url,normalized_url_key,title,keyword,created_at,modified_at)
                 VALUES(?,?,?,?,?,?,?)",
                params![id, bookmark.url, bookmark.key, bookmark.title, bookmark.keyword, created, now],
            )?;
            replace_tags(&tx, &id, &bookmark.tags)?;
            added += 1;
        }
        tx.commit()?;
        self.refresh_index()?;
        Ok(ImportSummary {
            added,
            already_saved: preview.already_saved,
            skipped: preview.skipped,
            backup,
        })
    }

    fn existing_keys(&self) -> HashSet<String> {
        self.index
            .iter()
            .filter_map(|bookmark| normalize_url(&bookmark.original_url).ok())
            .map(|(_, key)| key)
            .collect()
    }

    /// Backup files as (name, created_at, reason), validated by name only.
    fn backup_files(&self) -> Result<Vec<(String, i64, BackupReason)>, RepositoryError> {
        let directory = self.backups_dir();
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.into()),
        };
        let mut files = Vec::new();
        for entry in entries.flatten() {
            let Ok(name) = entry.file_name().into_string() else {
                continue;
            };
            let Some((created_at, reason)) = parse_backup_name(&name) else {
                continue;
            };
            if entry.file_type().is_ok_and(|kind| kind.is_file()) {
                files.push((name, created_at, reason));
            }
        }
        Ok(files)
    }

    fn prune_backups(&self) -> Result<(), RepositoryError> {
        let mut files = self.backup_files()?;
        files.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.cmp(&a.0)));
        let (mut manual, mut automatic) = (0, 0);
        for (name, _, reason) in files {
            let kept = if reason == BackupReason::Manual {
                manual += 1;
                manual <= KEEP_MANUAL
            } else {
                automatic += 1;
                automatic <= KEEP_AUTOMATIC
            };
            if !kept {
                fs::remove_file(self.backups_dir().join(name))?;
            }
        }
        Ok(())
    }

    fn backup_path(&self, name: &str) -> Result<PathBuf, RepositoryError> {
        if parse_backup_name(name).is_none() {
            return Err(RepositoryError::Validation("Unknown backup".into()));
        }
        let path = self.backups_dir().join(name);
        let metadata = fs::symlink_metadata(&path)
            .map_err(|_| RepositoryError::Validation("That backup no longer exists".into()))?;
        if !metadata.file_type().is_file() || metadata.len() > MAX_BACKUP_BYTES {
            return Err(invalid_backup());
        }
        Ok(path)
    }
}

/// Parses `bookmarks-<UTC stamp>[-n]-<reason>.sqlite3`. Names are the only
/// thing a client can pass to restore, so anything else is refused.
fn parse_backup_name(name: &str) -> Option<(i64, BackupReason)> {
    let middle = name
        .strip_prefix(BACKUP_PREFIX)?
        .strip_suffix(BACKUP_SUFFIX)?;
    if !middle
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return None;
    }
    let (stamp, rest) = middle.split_once('-')?;
    let reason = rest
        .split_once('-')
        .filter(|(counter, _)| counter.chars().all(|c| c.is_ascii_digit()))
        .and_then(|(_, slug)| BackupReason::from_slug(slug))
        .or_else(|| BackupReason::from_slug(rest))?;
    let created = DateTime::parse_from_str(
        &format!("{}+0000", stamp.trim_end_matches('Z')),
        "%Y%m%dT%H%M%S%3f%z",
    )
    .ok()?;
    Some((created.timestamp_millis(), reason))
}

/// Backups are opened read-only and immutable, so inspecting or restoring one
/// never writes to it or creates journal files beside it.
fn backup_uri(path: &Path) -> Result<String, RepositoryError> {
    let text = path
        .to_str()
        .ok_or_else(|| RepositoryError::Validation("Backup path is not valid UTF-8".into()))?;
    let mut encoded = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    Ok(format!("file:{encoded}?mode=ro&immutable=1"))
}

fn count_bookmarks(path: &Path) -> Result<i64, RepositoryError> {
    let conn = Connection::open_with_flags(
        backup_uri(path)?,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    Ok(conn.query_row("SELECT count(*) FROM bookmarks", [], |row| row.get(0))?)
}

fn ensure_private_dir(path: &Path) -> Result<(), RepositoryError> {
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(RepositoryError::Validation(format!(
            "Refusing to use a symlinked directory: {}",
            path.display()
        )));
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    Ok(())
}

fn invalid_backup() -> RepositoryError {
    RepositoryError::Validation("That backup is damaged or is not a Bookmarks backup".into())
}

struct Example {
    title: &'static str,
    url: &'static str,
    description: &'static str,
    tags: &'static [&'static str],
    keyword: &'static str,
}

const EXAMPLES: &[Example] = &[
    Example {
        title: "The Omarchy Manual",
        url: "https://learn.omacom.io/2/the-omarchy-manual",
        description: "Keybindings, themes, and everything else about Omarchy.",
        tags: &["omarchy", "docs"],
        keyword: "omarchy",
    },
    Example {
        title: "GitHub",
        url: "https://github.com/",
        description: "Code hosting, pull requests, and issues.",
        tags: &["dev", "code"],
        keyword: "gh",
    },
    Example {
        title: "Hyprland Wiki",
        url: "https://wiki.hypr.land/",
        description: "Configuration reference for the Hyprland compositor.",
        tags: &["linux", "docs", "hyprland"],
        keyword: "",
    },
    Example {
        title: "ArchWiki",
        url: "https://wiki.archlinux.org/",
        description: "Documentation for Arch Linux and much of the Linux desktop.",
        tags: &["linux", "docs"],
        keyword: "aw",
    },
    Example {
        title: "YouTube",
        url: "https://www.youtube.com/",
        description: "",
        tags: &["video"],
        keyword: "yt",
    },
    Example {
        title: "Hacker News",
        url: "https://news.ycombinator.com/",
        description: "Links and discussion about technology and startups.",
        tags: &["news", "tech"],
        keyword: "hn",
    },
    Example {
        title: "The Rust Programming Language",
        url: "https://doc.rust-lang.org/book/",
        description: "The official book for learning Rust.",
        tags: &["rust", "docs", "learning"],
        keyword: "",
    },
    Example {
        title: "MDN Web Docs",
        url: "https://developer.mozilla.org/en-US/",
        description: "Reference for HTML, CSS, and JavaScript.",
        tags: &["web", "docs"],
        keyword: "mdn",
    },
    Example {
        title: "Excalidraw",
        url: "https://excalidraw.com/",
        description: "Hand-drawn style diagrams and whiteboarding.",
        tags: &["design", "tools"],
        keyword: "",
    },
    Example {
        title: "Wikipedia",
        url: "https://en.wikipedia.org/wiki/Main_Page",
        description: "The free encyclopedia.",
        tags: &["reference"],
        keyword: "wiki",
    },
    Example {
        title: "Tailwind CSS",
        url: "https://tailwindcss.com/docs",
        description: "Utility-first CSS framework documentation.",
        tags: &["web", "css", "docs"],
        keyword: "",
    },
    Example {
        title: "Figma",
        url: "https://www.figma.com/",
        description: "Collaborative interface design.",
        tags: &["design"],
        keyword: "",
    },
    Example {
        title: "Linear",
        url: "https://linear.app/",
        description: "Issue tracking and project planning.",
        tags: &["work", "planning"],
        keyword: "",
    },
    Example {
        title: "Basecamp",
        url: "https://basecamp.com/",
        description: "Project management and team communication.",
        tags: &["work", "planning"],
        keyword: "",
    },
    Example {
        title: "HEY",
        url: "https://www.hey.com/",
        description: "Email.",
        tags: &["email"],
        keyword: "",
    },
    Example {
        title: "Google Calendar",
        url: "https://calendar.google.com/",
        description: "",
        tags: &["work", "calendar"],
        keyword: "cal",
    },
    Example {
        title: "Spotify",
        url: "https://open.spotify.com/",
        description: "Music and podcasts.",
        tags: &["music"],
        keyword: "",
    },
    Example {
        title: "crates.io",
        url: "https://crates.io/",
        description: "The Rust package registry.",
        tags: &["rust", "dev"],
        keyword: "crates",
    },
    Example {
        title: "Stack Overflow",
        url: "https://stackoverflow.com/",
        description: "Questions and answers for programmers.",
        tags: &["dev", "reference"],
        keyword: "so",
    },
    Example {
        title: "Neovim Documentation",
        url: "https://neovim.io/doc/",
        description: "User manual and API reference for Neovim.",
        tags: &["editor", "docs"],
        keyword: "",
    },
    Example {
        title: "Ghostty Documentation",
        url: "https://ghostty.org/docs",
        description: "Configuration for the Ghostty terminal.",
        tags: &["terminal", "docs"],
        keyword: "",
    },
    Example {
        title: "Arch Linux Packages",
        url: "https://archlinux.org/packages/",
        description: "Search the official Arch Linux repositories.",
        tags: &["linux", "packages"],
        keyword: "pkg",
    },
    Example {
        title: "Unsplash",
        url: "https://unsplash.com/",
        description: "Free photos for wallpapers and projects.",
        tags: &["design", "wallpapers"],
        keyword: "",
    },
    Example {
        title: "Weather",
        url: "https://weather.com/",
        description: "",
        tags: &["daily"],
        keyword: "",
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_names_round_trip_and_reject_paths() {
        let (created, reason) =
            parse_backup_name("bookmarks-20260913T161500123Z-before-import.sqlite3").unwrap();
        assert_eq!(reason, BackupReason::BeforeImport);
        assert_eq!(created, 1_789_316_100_123);
        assert!(parse_backup_name("bookmarks-20260913T161500123Z-2-manual.sqlite3").is_some());
        for bad in [
            "../bookmarks-20260913T161500123Z-manual.sqlite3",
            "bookmarks-20260913T161500123Z-manual.sqlite3/x",
            "bookmarks-20260913T161500123Z-unknown.sqlite3",
            "bookmarks.sqlite3",
            "bookmarks-notadate-manual.sqlite3",
        ] {
            assert!(parse_backup_name(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn examples_are_valid_bookmarks() {
        let mut keys = HashSet::new();
        for example in EXAMPLES {
            let (_, key) = normalize_url(example.url).unwrap();
            assert!(keys.insert(key), "{}", example.url);
            let tags: Vec<String> = example.tags.iter().map(|t| t.to_string()).collect();
            crate::repository::validate_fields(
                example.title,
                example.description,
                &tags,
                example.keyword,
            )
            .unwrap();
        }
    }

    #[test]
    fn backup_uris_escape_special_characters() {
        assert_eq!(
            backup_uri(Path::new("/tmp/a b?c#d/x.sqlite3")).unwrap(),
            "file:/tmp/a%20b%3Fc%23d/x.sqlite3?mode=ro&immutable=1"
        );
    }
}
