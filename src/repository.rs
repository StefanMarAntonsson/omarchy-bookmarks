use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use chrono::Utc;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, params};
use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    model::{Bookmark, BookmarkInput, UserSettings},
    url_key::normalize_url,
};

pub(crate) const MAX_STORE_BYTES: u64 = 64 * 1024 * 1024;
pub(crate) const MAX_BOOKMARKS: usize = 50_000;
pub(crate) const MAX_TITLE: usize = 2_048;
pub(crate) const MAX_DESCRIPTION: usize = 8_192;
pub(crate) const MAX_TAGS: usize = 64;
pub(crate) const MAX_TAG: usize = 128;
pub(crate) const MAX_KEYWORD: usize = 128;
pub(crate) const MAX_ID: usize = 256;
/// The newest schema this worker understands; restores refuse newer backups.
pub(crate) const SCHEMA_VERSION: i64 = 1;

#[derive(Debug, Error)]
pub enum RepositoryError {
    #[error("database error: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("storage error: {0}")]
    Io(#[from] std::io::Error),
    #[error(
        "legacy migration stopped: {0}. The original JSON was preserved; repair or move it aside, then restart"
    )]
    Legacy(String),
    #[error("{0}")]
    Validation(String),
}

#[derive(Deserialize)]
struct LegacyDocument {
    version: Option<u64>,
    bookmarks: Vec<LegacyBookmark>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyBookmark {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
    url: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    keyword: String,
    #[serde(default)]
    usage_score: f64,
    #[serde(default)]
    last_opened_at: i64,
}

pub struct Repository {
    pub(crate) conn: Connection,
    pub(crate) index: Vec<Bookmark>,
    pub(crate) data_dir: PathBuf,
}

impl Repository {
    pub fn open(db_path: &Path, legacy_path: &Path) -> Result<Self, RepositoryError> {
        if let Some(parent) = db_path.parent() {
            ensure_private_data_dir(parent)?;
        }
        restrict_database_files(db_path)?;
        let conn = Connection::open_with_flags(
            db_path,
            OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW | OpenFlags::SQLITE_OPEN_URI,
        )?;
        reject_newer_schema(&conn)?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        let mut this = Self {
            conn,
            index: Vec::new(),
            data_dir: db_path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from(".")),
        };
        this.migrate_schema()?;
        this.migrate_legacy_once(legacy_path)?;
        this.refresh_index()?;
        Ok(this)
    }

    fn migrate_schema(&mut self) -> Result<(), RepositoryError> {
        self.conn.execute_batch("BEGIN IMMEDIATE;
          CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS bookmarks(
            id TEXT PRIMARY KEY, original_url TEXT NOT NULL, normalized_url_key TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', keyword TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL, modified_at INTEGER NOT NULL,
            usage_score REAL NOT NULL DEFAULT 0, last_opened_at INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE IF NOT EXISTS tags(id INTEGER PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE);
          CREATE TABLE IF NOT EXISTS bookmark_tags(
            bookmark_id TEXT NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY(bookmark_id, tag_id)
          );
          CREATE INDEX IF NOT EXISTS bookmark_tags_tag_idx ON bookmark_tags(tag_id, bookmark_id);
          CREATE INDEX IF NOT EXISTS bookmarks_keyword_idx ON bookmarks(keyword COLLATE NOCASE);
          CREATE TABLE IF NOT EXISTS app_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
          INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, unixepoch());
          COMMIT;")?;
        Ok(())
    }

    fn migrate_legacy_once(&mut self, path: &Path) -> Result<(), RepositoryError> {
        let done: Option<String> = self
            .conn
            .query_row(
                "SELECT value FROM app_metadata WHERE key='legacy_json_migrated'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if done.is_some() {
            return Ok(());
        }
        // Checked without following symlinks, so a dangling link is reported
        // rather than silently treated as "no legacy data".
        match fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            _ => {}
        }
        let raw = read_legacy(path)?;
        // Only the position is reported; serde messages can quote file content.
        let doc: LegacyDocument = serde_json::from_slice(&raw).map_err(|e| {
            RepositoryError::Legacy(format!(
                "bookmarks.json is malformed near line {}, column {}",
                e.line(),
                e.column()
            ))
        })?;
        if doc.version.unwrap_or(0) > 3 {
            return Err(RepositoryError::Legacy(
                "bookmarks.json uses an unsupported newer format".into(),
            ));
        }
        if doc.bookmarks.len() > MAX_BOOKMARKS {
            return Err(RepositoryError::Legacy(
                "bookmarks.json has too many entries".into(),
            ));
        }
        let mut prepared = Vec::with_capacity(doc.bookmarks.len());
        let mut ids = HashSet::new();
        let mut keys = HashSet::new();
        for item in doc.bookmarks {
            let id = if item.id.is_empty() {
                Uuid::new_v4().to_string()
            } else {
                item.id.clone()
            };
            if id.len() > MAX_ID || !ids.insert(id.clone()) {
                return Err(RepositoryError::Legacy(
                    "duplicate or invalid bookmark ID".into(),
                ));
            }
            let (url, key) = normalize_url(&item.url).map_err(RepositoryError::Legacy)?;
            if !keys.insert(key.clone()) {
                return Err(RepositoryError::Legacy("duplicate bookmark URL".into()));
            }
            validate_fields(&item.title, &item.description, &item.tags, &item.keyword)
                .map_err(RepositoryError::Legacy)?;
            prepared.push((id, url, key, item));
        }
        let backup = timestamped_backup(path)?;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&backup)?
            .write_all(&raw)?;
        let tx = self.conn.transaction()?;
        for (id, url, key, item) in prepared {
            let now = Utc::now().timestamp_millis();
            tx.execute("INSERT INTO bookmarks(id,original_url,normalized_url_key,title,description,keyword,created_at,modified_at,usage_score,last_opened_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                params![id,url,key,item.title,item.description,item.keyword,now,now,item.usage_score.max(0.0),item.last_opened_at.max(0)])?;
            replace_tags(&tx, &id, &item.tags)?;
        }
        tx.execute(
            "INSERT INTO app_metadata(key,value) VALUES('legacy_json_migrated',?)",
            [backup.to_string_lossy().as_ref()],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn all(&self) -> &[Bookmark] {
        &self.index
    }
    pub fn find_url(&self, url: &str) -> Result<Option<Bookmark>, RepositoryError> {
        let (_, key) = normalize_url(url).map_err(RepositoryError::Validation)?;
        Ok(self
            .index
            .iter()
            .find(|b| normalize_url(&b.original_url).is_ok_and(|(_, k)| k == key))
            .cloned())
    }
    pub fn get(&self, id: &str) -> Option<Bookmark> {
        self.index.iter().find(|b| b.id == id).cloned()
    }

    pub fn settings(&self) -> Result<UserSettings, RepositoryError> {
        let stored: Option<String> = self
            .conn
            .query_row(
                "SELECT value FROM app_metadata WHERE key='user_settings_v1'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        match stored {
            Some(value) => {
                let settings: UserSettings = serde_json::from_str(&value).map_err(|_| {
                    RepositoryError::Validation("Saved settings are malformed".into())
                })?;
                validate_settings(&settings)?;
                Ok(settings)
            }
            None => Ok(UserSettings::default()),
        }
    }

    pub fn save_settings(
        &mut self,
        settings: UserSettings,
    ) -> Result<UserSettings, RepositoryError> {
        validate_settings(&settings)?;
        let value = serde_json::to_string(&settings).map_err(|_| {
            RepositoryError::Validation("Could not encode bookmark settings".into())
        })?;
        self.conn.execute(
            "INSERT INTO app_metadata(key,value) VALUES('user_settings_v1',?) \
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [value],
        )?;
        Ok(settings)
    }

    pub fn add(&mut self, input: BookmarkInput) -> Result<Bookmark, RepositoryError> {
        validate_fields(
            &input.title,
            &input.description,
            &input.tags,
            &input.keyword,
        )
        .map_err(RepositoryError::Validation)?;
        let (url, key) = normalize_url(&input.url).map_err(RepositoryError::Validation)?;
        if input.id.len() > MAX_ID {
            return Err(RepositoryError::Validation("Bookmark ID is invalid".into()));
        }
        if self.index.len() >= MAX_BOOKMARKS {
            return Err(RepositoryError::Validation(format!(
                "The library is limited to {MAX_BOOKMARKS} bookmarks"
            )));
        }
        if self
            .conn
            .query_row(
                "SELECT 1 FROM bookmarks WHERE normalized_url_key=?",
                [&key],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            return Err(RepositoryError::Validation(
                "That URL is already bookmarked".into(),
            ));
        }
        let id = if input.id.is_empty() {
            Uuid::new_v4().to_string()
        } else {
            input.id
        };
        let now = Utc::now().timestamp_millis();
        let tx = self.conn.transaction()?;
        tx.execute("INSERT INTO bookmarks(id,original_url,normalized_url_key,title,description,keyword,created_at,modified_at) VALUES(?,?,?,?,?,?,?,?)",
                   params![id,url,key,input.title,input.description,input.keyword,now,now])?;
        replace_tags(&tx, &id, &input.tags)?;
        tx.commit()?;
        self.refresh_index()?;
        self.get(&id)
            .ok_or_else(|| RepositoryError::Validation("Saved bookmark was not found".into()))
    }

    pub fn edit(&mut self, input: BookmarkInput) -> Result<Bookmark, RepositoryError> {
        if input.id.is_empty() || input.id.len() > MAX_ID {
            return Err(RepositoryError::Validation(
                "Bookmark ID is required".into(),
            ));
        }
        validate_fields(
            &input.title,
            &input.description,
            &input.tags,
            &input.keyword,
        )
        .map_err(RepositoryError::Validation)?;
        let (url, key) = normalize_url(&input.url).map_err(RepositoryError::Validation)?;
        let tx = self.conn.transaction()?;
        let changed=tx.execute("UPDATE bookmarks SET original_url=?,normalized_url_key=?,title=?,description=?,keyword=?,modified_at=? WHERE id=?",
            params![url,key,input.title,input.description,input.keyword,Utc::now().timestamp_millis(),input.id])?;
        if changed == 0 {
            return Err(RepositoryError::Validation(
                "Bookmark no longer exists".into(),
            ));
        }
        replace_tags(&tx, &input.id, &input.tags)?;
        tx.commit()?;
        self.refresh_index()?;
        self.get(&input.id)
            .ok_or_else(|| RepositoryError::Validation("Updated bookmark was not found".into()))
    }

    pub fn delete(&mut self, id: &str) -> Result<bool, RepositoryError> {
        let changed = self
            .conn
            .execute("DELETE FROM bookmarks WHERE id=?", [id])?;
        self.conn.execute(
            "DELETE FROM tags WHERE NOT EXISTS(SELECT 1 FROM bookmark_tags WHERE tag_id=tags.id)",
            [],
        )?;
        self.refresh_index()?;
        Ok(changed > 0)
    }

    pub fn record_open(&mut self, id: &str) -> Result<(), RepositoryError> {
        let now = Utc::now().timestamp_millis();
        self.conn.execute(
            "UPDATE bookmarks SET usage_score=usage_score+1,last_opened_at=? WHERE id=?",
            params![now, id],
        )?;
        // Only usage changed, so update the index in place instead of reloading.
        if let Some(bookmark) = self.index.iter_mut().find(|b| b.id == id) {
            bookmark.usage_score += 1.0;
            bookmark.last_opened_at = now;
        }
        Ok(())
    }

    pub fn suggestions(&self, text: &str) -> Vec<String> {
        let words: HashSet<String> = text
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| w.len() >= 3)
            .map(str::to_lowercase)
            .collect();
        let mut tags: Vec<String> = self
            .index
            .iter()
            .flat_map(|b| b.tags.iter().cloned())
            .filter(|tag| words.contains(&tag.to_lowercase()))
            .collect();
        tags.sort_by_key(|s| s.to_lowercase());
        tags.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
        tags.truncate(4);
        tags
    }

    /// Checks the database against the same limits the worker enforces on
    /// input before loading it, so an externally edited or corrupted database
    /// cannot exhaust memory.
    fn check_store_bounds(&self) -> Result<(), RepositoryError> {
        self.check_bounds_in("main")
    }

    /// Checks a database attached under `schema` (`main` or an attached
    /// backup) against the store limits.
    pub(crate) fn check_bounds_in(&self, schema: &str) -> Result<(), RepositoryError> {
        let (count, bytes, oversized): (i64, i64, i64) = self.conn.query_row(
            &format!(
                "SELECT count(*),
               COALESCE(sum(length(CAST(id AS BLOB)) + length(CAST(original_url AS BLOB))
                 + length(CAST(title AS BLOB)) + length(CAST(description AS BLOB))
                 + length(CAST(keyword AS BLOB))), 0),
               COALESCE(max(length(CAST(id AS BLOB)) > ?1 OR length(CAST(original_url AS BLOB)) > ?2
                 OR length(CAST(title AS BLOB)) > ?3 OR length(CAST(description AS BLOB)) > ?4
                 OR length(CAST(keyword AS BLOB)) > ?5), 0)
             FROM {schema}.bookmarks"
            ),
            params![
                MAX_ID as i64,
                crate::url_key::MAX_URL_LEN as i64,
                MAX_TITLE as i64,
                MAX_DESCRIPTION as i64,
                MAX_KEYWORD as i64
            ],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        let (tag_bytes, most_tags, longest_tag): (i64, i64, i64) = self.conn.query_row(
            &format!("SELECT COALESCE(sum(length(CAST(t.name AS BLOB))), 0),
               COALESCE((SELECT max(n) FROM (SELECT count(*) n FROM {schema}.bookmark_tags GROUP BY bookmark_id)), 0),
               COALESCE((SELECT max(length(CAST(name AS BLOB))) FROM {schema}.tags), 0)
             FROM {schema}.bookmark_tags bt JOIN {schema}.tags t ON t.id = bt.tag_id"),
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        if count as usize > MAX_BOOKMARKS
            || oversized != 0
            || most_tags as usize > MAX_TAGS
            || longest_tag as usize > MAX_TAG
            || (bytes + tag_bytes) as u64 > MAX_STORE_BYTES
        {
            return Err(RepositoryError::Validation(
                "The bookmark database exceeds safety limits".into(),
            ));
        }
        Ok(())
    }

    pub(crate) fn refresh_index(&mut self) -> Result<(), RepositoryError> {
        self.check_store_bounds()?;
        let mut stmt=self.conn.prepare("SELECT b.id,b.original_url,b.title,b.description,b.keyword,b.created_at,b.modified_at,b.usage_score,b.last_opened_at,COALESCE(group_concat(t.name,char(31)),'') FROM bookmarks b LEFT JOIN bookmark_tags bt ON bt.bookmark_id=b.id LEFT JOIN tags t ON t.id=bt.tag_id GROUP BY b.id ORDER BY b.id")?;
        self.index = stmt
            .query_map([], |r| {
                let packed: String = r.get(9)?;
                Ok(Bookmark {
                    id: r.get(0)?,
                    original_url: r.get(1)?,
                    title: r.get(2)?,
                    description: r.get(3)?,
                    keyword: r.get(4)?,
                    created_at: r.get(5)?,
                    modified_at: r.get(6)?,
                    usage_score: r.get(7)?,
                    last_opened_at: r.get(8)?,
                    tags: if packed.is_empty() {
                        vec![]
                    } else {
                        packed.split('\u{1f}').map(str::to_string).collect()
                    },
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(())
    }
}

/// Refuse a database created by a newer worker before running any migrations
/// or enabling WAL, both of which can write to the file.
fn reject_newer_schema(conn: &Connection) -> Result<(), RepositoryError> {
    let has_migrations: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations')",
        [],
        |row| row.get(0),
    )?;
    if !has_migrations {
        return Ok(());
    }
    let version: i64 = conn.query_row(
        "SELECT COALESCE(max(version), 0) FROM schema_migrations",
        [],
        |row| row.get(0),
    )?;
    if version > SCHEMA_VERSION {
        return Err(RepositoryError::Validation(
            "The bookmark database was created by a newer version of Bookmarks".into(),
        ));
    }
    Ok(())
}

fn ensure_private_data_dir(path: &Path) -> Result<(), RepositoryError> {
    use std::os::unix::fs::PermissionsExt;

    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(RepositoryError::Validation(format!(
            "Refusing to use a symlinked data directory: {}",
            path.display()
        )));
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() {
        return Err(RepositoryError::Validation(
            "The bookmark data location is not a directory".into(),
        ));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn validate_settings(settings: &UserSettings) -> Result<(), RepositoryError> {
    if settings.default_search_scope != "all" && settings.default_search_scope != "tags" {
        return Err(RepositoryError::Validation(
            "Default search must be all bookmarks or tags".into(),
        ));
    }
    if !(3..=10).contains(&settings.result_count) {
        return Err(RepositoryError::Validation(
            "Visible result count must be between 3 and 10".into(),
        ));
    }
    Ok(())
}

pub(crate) fn validate_fields(
    title: &str,
    description: &str,
    tags: &[String],
    keyword: &str,
) -> Result<(), String> {
    if title.len() > MAX_TITLE {
        return Err("Title is too long".into());
    }
    if description.len() > MAX_DESCRIPTION {
        return Err("Description is too long".into());
    }
    if tags.len() > MAX_TAGS
        || tags
            .iter()
            .any(|t| t.trim().is_empty() || t.len() > MAX_TAG || t.chars().any(char::is_control))
    {
        return Err("Tags exceed safety limits".into());
    }
    if keyword.len() > MAX_KEYWORD || keyword.chars().any(char::is_whitespace) {
        return Err("Keyword is invalid".into());
    }
    Ok(())
}
pub(crate) fn replace_tags(
    tx: &Transaction<'_>,
    id: &str,
    tags: &[String],
) -> Result<(), rusqlite::Error> {
    tx.execute("DELETE FROM bookmark_tags WHERE bookmark_id=?", [id])?;
    let mut seen = HashSet::new();
    for raw in tags {
        let tag = raw.trim();
        if tag.is_empty() || !seen.insert(tag.to_lowercase()) {
            continue;
        }
        tx.execute("INSERT OR IGNORE INTO tags(name) VALUES(?)", [tag])?;
        tx.execute("INSERT INTO bookmark_tags(bookmark_id,tag_id) SELECT ?,id FROM tags WHERE name=? COLLATE NOCASE",params![id,tag])?;
    }
    Ok(())
}
/// Bookmarks are private, so the database and SQLite's journal files are
/// readable only by the user. SQLite gives new journal files the database's
/// permissions, so creating the database with mode 0600 covers future files.
fn restrict_database_files(db_path: &Path) -> Result<(), RepositoryError> {
    use std::os::unix::fs::PermissionsExt;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(db_path)?;
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = PathBuf::from(format!("{}{suffix}", db_path.display()));
        if let Ok(metadata) = fs::symlink_metadata(&path)
            && metadata.file_type().is_file()
            && metadata.permissions().mode() & 0o077 != 0
        {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
    }
    Ok(())
}

/// Opens the legacy file without following symlinks or blocking on FIFOs,
/// then validates and reads it from the same descriptor.
fn read_legacy(path: &Path) -> Result<Vec<u8>, RepositoryError> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::ELOOP) {
                RepositoryError::Legacy("bookmarks.json is not a regular file".into())
            } else {
                RepositoryError::Io(e)
            }
        })?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() {
        return Err(RepositoryError::Legacy(
            "bookmarks.json is not a regular file".into(),
        ));
    }
    if metadata.len() > MAX_STORE_BYTES {
        return Err(RepositoryError::Legacy(
            "bookmarks.json exceeds the 64 MiB safety limit".into(),
        ));
    }
    let mut raw = Vec::new();
    file.take(MAX_STORE_BYTES + 1).read_to_end(&mut raw)?;
    if raw.len() as u64 > MAX_STORE_BYTES {
        return Err(RepositoryError::Legacy(
            "bookmarks.json exceeds the 64 MiB safety limit".into(),
        ));
    }
    Ok(raw)
}
fn timestamped_backup(path: &Path) -> Result<PathBuf, std::io::Error> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut out = PathBuf::from(format!("{}.migration-backup-{stamp}", path.display()));
    let mut n = 0;
    while out.exists() {
        n += 1;
        out = PathBuf::from(format!("{}.migration-backup-{stamp}-{n}", path.display()));
    }
    Ok(out)
}
