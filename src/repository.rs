use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    model::{Bookmark, BookmarkInput, UserSettings},
    url_key::normalize_url,
};

const MAX_STORE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_BOOKMARKS: usize = 50_000;
const MAX_TITLE: usize = 2_048;
const MAX_DESCRIPTION: usize = 8_192;
const MAX_TAGS: usize = 64;
const MAX_TAG: usize = 128;
const MAX_KEYWORD: usize = 128;

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
    conn: Connection,
    index: Vec<Bookmark>,
}

impl Repository {
    pub fn open(db_path: &Path, legacy_path: &Path) -> Result<Self, RepositoryError> {
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        let mut this = Self {
            conn,
            index: Vec::new(),
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
        if done.is_some() || !path.exists() {
            return Ok(());
        }
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return Err(RepositoryError::Legacy(
                "bookmarks.json is not a regular file".into(),
            ));
        }
        if metadata.len() > MAX_STORE_BYTES {
            return Err(RepositoryError::Legacy(
                "bookmarks.json exceeds the 64 MiB safety limit".into(),
            ));
        }
        let raw = fs::read(path)?;
        let doc: LegacyDocument = serde_json::from_slice(&raw)
            .map_err(|e| RepositoryError::Legacy(format!("bookmarks.json is malformed ({e})")))?;
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
            if id.len() > 256 || !ids.insert(id.clone()) {
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
        fs::copy(path, &backup)?;
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
        if input.id.is_empty() {
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
        self.conn.execute("UPDATE bookmarks SET usage_score=usage_score+1,last_opened_at=?,modified_at=modified_at WHERE id=?",
                          params![Utc::now().timestamp_millis(),id])?;
        self.refresh_index()?;
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

    fn refresh_index(&mut self) -> Result<(), RepositoryError> {
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

fn validate_fields(
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
            .any(|t| t.trim().is_empty() || t.len() > MAX_TAG)
    {
        return Err("Tags exceed safety limits".into());
    }
    if keyword.len() > MAX_KEYWORD || keyword.chars().any(char::is_whitespace) {
        return Err("Keyword is invalid".into());
    }
    Ok(())
}
fn replace_tags(tx: &Transaction<'_>, id: &str, tags: &[String]) -> Result<(), rusqlite::Error> {
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
