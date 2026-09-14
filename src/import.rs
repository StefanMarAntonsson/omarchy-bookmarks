//! Reads bookmarks from installed browser profiles.
//!
//! Firefox-based browsers keep bookmarks in `places.sqlite`, which is copied to
//! a private temporary directory before reading so a running browser's lock
//! and write-ahead log are never touched. Chromium-based browsers keep them in
//! a `Bookmarks` JSON file. Every file is opened without following symlinks,
//! checked to be a regular file, and read with size, count, and depth limits.

use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{self, Read},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{
    repository::{MAX_BOOKMARKS, MAX_KEYWORD, MAX_TAG, MAX_TAGS, MAX_TITLE},
    url_key::normalize_url,
};

const MAX_SOURCES: usize = 64;
const MAX_PROFILES_INI_BYTES: u64 = 256 * 1024;
const MAX_LOCAL_STATE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_CHROMIUM_BOOKMARKS_BYTES: u64 = 64 * 1024 * 1024;
const MAX_PLACES_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_CHROMIUM_NODES: usize = 250_000;
const MAX_FOLDER_DEPTH: usize = 128;
const MAX_NAME: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Family {
    Firefox,
    Chromium,
}

#[derive(Clone, Debug, Serialize)]
pub struct ImportSource {
    /// The bookmark file's path. Requests name a source by this value, and it
    /// is only accepted if discovery finds it again.
    pub id: String,
    pub browser: String,
    pub profile: String,
    #[serde(skip)]
    family: Family,
    #[serde(skip)]
    path: PathBuf,
}

/// A bookmark read from a browser, already validated for the store.
#[derive(Clone, Debug, PartialEq)]
pub struct ImportedBookmark {
    pub url: String,
    pub key: String,
    pub title: String,
    pub tags: Vec<String>,
    pub keyword: String,
    pub created_at: i64,
}

#[derive(Debug, Default, PartialEq)]
pub struct ImportRead {
    pub bookmarks: Vec<ImportedBookmark>,
    /// Entries that were not HTTP(S) bookmarks, such as `place:` queries or
    /// `javascript:` bookmarklets.
    pub skipped: usize,
    /// Entries whose URL appeared earlier in the same profile.
    pub duplicates: usize,
}

struct BrowserRoot {
    browser: &'static str,
    family: Family,
    path: PathBuf,
}

fn browser_roots(home: &Path) -> Vec<BrowserRoot> {
    let config = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    let flatpak = home.join(".var/app");
    let firefox = |browser, path: PathBuf| BrowserRoot {
        browser,
        family: Family::Firefox,
        path,
    };
    let chromium = |browser, path: PathBuf| BrowserRoot {
        browser,
        family: Family::Chromium,
        path,
    };
    vec![
        firefox("Firefox", home.join(".mozilla/firefox")),
        firefox("Firefox", config.join("mozilla/firefox")),
        firefox(
            "Firefox",
            flatpak.join("org.mozilla.firefox/.mozilla/firefox"),
        ),
        firefox("Zen", home.join(".zen")),
        firefox("Zen", config.join("zen")),
        firefox("Zen", flatpak.join("app.zen_browser.zen/.zen")),
        firefox("LibreWolf", home.join(".librewolf")),
        firefox("LibreWolf", config.join("librewolf/librewolf")),
        firefox(
            "LibreWolf",
            flatpak.join("io.gitlab.librewolf-community/.librewolf"),
        ),
        firefox("Floorp", home.join(".floorp")),
        firefox("Waterfox", home.join(".waterfox")),
        chromium("Chromium", config.join("chromium")),
        chromium(
            "Chromium",
            flatpak.join("org.chromium.Chromium/config/chromium"),
        ),
        chromium("Google Chrome", config.join("google-chrome")),
        chromium("Google Chrome Beta", config.join("google-chrome-beta")),
        chromium(
            "Google Chrome",
            flatpak.join("com.google.Chrome/config/google-chrome"),
        ),
        chromium("Brave", config.join("BraveSoftware/Brave-Browser")),
        chromium(
            "Brave",
            flatpak.join("com.brave.Browser/config/BraveSoftware/Brave-Browser"),
        ),
        chromium("Vivaldi", config.join("vivaldi")),
        chromium("Microsoft Edge", config.join("microsoft-edge")),
        chromium("Helium", config.join("net.imput.helium")),
        chromium("Thorium", config.join("thorium")),
        chromium("Opera", config.join("opera")),
    ]
}

pub fn discover() -> Result<Vec<ImportSource>, String> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is not set")?;
    Ok(discover_in(&browser_roots(&home)))
}

pub fn find(id: &str) -> Result<ImportSource, String> {
    discover()?
        .into_iter()
        .find(|source| source.id == id)
        .ok_or_else(|| "That browser profile is no longer available".into())
}

fn discover_in(roots: &[BrowserRoot]) -> Vec<ImportSource> {
    let mut sources = Vec::new();
    let mut seen = HashSet::new();
    for root in roots {
        let found = match root.family {
            Family::Firefox => firefox_profiles(root),
            Family::Chromium => chromium_profiles(root),
        };
        for source in found {
            // The same profile can be reachable through several roots.
            let key = source
                .path
                .canonicalize()
                .unwrap_or_else(|_| source.path.clone());
            if seen.insert(key) {
                sources.push(source);
            }
            if sources.len() >= MAX_SOURCES {
                return sources;
            }
        }
    }
    sources
}

fn firefox_profiles(root: &BrowserRoot) -> Vec<ImportSource> {
    let Some(ini) = read_text(&root.path.join("profiles.ini"), MAX_PROFILES_INI_BYTES) else {
        return Vec::new();
    };
    let mut profiles = Vec::new();
    let mut section = String::new();
    let mut fields: HashMap<String, String> = HashMap::new();
    let mut flush = |section: &str, fields: &mut HashMap<String, String>| {
        if section.starts_with("Profile")
            && let Some(path) = fields.get("Path")
        {
            let relative = fields.get("IsRelative").is_none_or(|value| value == "1");
            let directory = if relative {
                root.path.join(path)
            } else {
                PathBuf::from(path)
            };
            let places = directory.join("places.sqlite");
            if is_regular_file(&places) {
                let name = fields.get("Name").cloned().unwrap_or_else(|| path.clone());
                profiles.push(ImportSource {
                    id: places.to_string_lossy().into_owned(),
                    browser: root.browser.into(),
                    profile: bounded_name(&name),
                    family: Family::Firefox,
                    path: places,
                });
            }
        }
        fields.clear();
    };
    for raw in ini.lines() {
        let line = raw.trim();
        if line.starts_with('[') && line.ends_with(']') {
            flush(&section, &mut fields);
            section = line[1..line.len() - 1].to_string();
        } else if let Some((key, value)) = line.split_once('=') {
            fields.insert(key.trim().into(), value.trim().into());
        }
    }
    flush(&section, &mut fields);
    profiles
}

fn chromium_profiles(root: &BrowserRoot) -> Vec<ImportSource> {
    let mut names: HashMap<String, String> = HashMap::new();
    if let Some(state) = read_bytes(&root.path.join("Local State"), MAX_LOCAL_STATE_BYTES)
        && let Ok(value) = serde_json::from_slice::<Value>(&state)
        && let Some(cache) = value
            .pointer("/profile/info_cache")
            .and_then(Value::as_object)
    {
        for (directory, info) in cache {
            if let Some(name) = info.get("name").and_then(Value::as_str) {
                names.insert(directory.clone(), name.to_string());
            }
        }
    }
    let mut profiles = Vec::new();
    // Opera keeps a single profile in the root itself.
    let mut candidates = vec![(String::new(), root.path.clone())];
    if let Ok(entries) = fs::read_dir(&root.path) {
        let mut directories: Vec<_> = entries
            .flatten()
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name == "Default" || name.starts_with("Profile "))
            .collect();
        directories.sort();
        candidates.extend(
            directories
                .into_iter()
                .map(|name| (name.clone(), root.path.join(name))),
        );
    }
    for (directory, path) in candidates {
        let bookmarks = path.join("Bookmarks");
        if !is_regular_file(&bookmarks) {
            continue;
        }
        let profile = names.get(&directory).cloned().unwrap_or_else(|| {
            if directory.is_empty() {
                "Default".into()
            } else {
                directory.clone()
            }
        });
        profiles.push(ImportSource {
            id: bookmarks.to_string_lossy().into_owned(),
            browser: root.browser.into(),
            profile: bounded_name(&profile),
            family: Family::Chromium,
            path: bookmarks,
        });
    }
    profiles
}

pub fn read(source: &ImportSource, scratch_dir: &Path) -> Result<ImportRead, String> {
    match source.family {
        Family::Firefox => read_firefox(&source.path, scratch_dir),
        Family::Chromium => read_chromium(&source.path),
    }
}

/// Collects validated bookmarks, merging tags of repeated URLs.
#[derive(Default)]
struct Collector {
    read: ImportRead,
    positions: HashMap<String, usize>,
}

impl Collector {
    fn add(
        &mut self,
        url: &str,
        title: &str,
        tags: Vec<String>,
        keyword: &str,
        created_at: i64,
    ) -> Result<(), String> {
        let Ok((url, key)) = normalize_url(url) else {
            self.read.skipped += 1;
            return Ok(());
        };
        let tags = clean_tags(tags);
        if let Some(&position) = self.positions.get(&key) {
            self.read.duplicates += 1;
            let existing = &mut self.read.bookmarks[position];
            if existing.title.is_empty() {
                existing.title = truncate(title.trim(), MAX_TITLE);
            }
            let mut merged = std::mem::take(&mut existing.tags);
            merged.extend(tags);
            existing.tags = clean_tags(merged);
            return Ok(());
        }
        if self.read.bookmarks.len() >= MAX_BOOKMARKS {
            return Err(format!(
                "That profile has more than {MAX_BOOKMARKS} bookmarks"
            ));
        }
        let keyword = keyword.trim();
        self.positions
            .insert(key.clone(), self.read.bookmarks.len());
        self.read.bookmarks.push(ImportedBookmark {
            url,
            key,
            title: truncate(title.trim(), MAX_TITLE),
            tags,
            keyword: if keyword.len() <= MAX_KEYWORD && !keyword.chars().any(char::is_whitespace) {
                keyword.to_string()
            } else {
                String::new()
            },
            created_at,
        });
        Ok(())
    }
}

fn read_firefox(places: &Path, scratch_dir: &Path) -> Result<ImportRead, String> {
    let scratch = ScratchDir::create(scratch_dir)?;
    let copy = scratch.path.join("places.sqlite");
    copy_bounded(places, &copy, MAX_PLACES_BYTES)?;
    // Include recent changes still in the write-ahead log, when present.
    let wal = PathBuf::from(format!("{}-wal", places.display()));
    if is_regular_file(&wal) {
        copy_bounded(
            &wal,
            &scratch.path.join("places.sqlite-wal"),
            MAX_PLACES_BYTES,
        )?;
    }
    let conn = Connection::open_with_flags(
        &copy,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|_| "Could not open the Firefox bookmark database")?;
    let unreadable = |_| String::from("The Firefox bookmark database could not be read");

    let mut tags_by_place: HashMap<i64, Vec<String>> = HashMap::new();
    {
        // Tags are folders under the tags root; a bookmark inside one marks
        // its place with that tag rather than being a bookmark of its own.
        let mut statement = conn
            .prepare(
                "SELECT b.fk, folder.title FROM moz_bookmarks b
                 JOIN moz_bookmarks folder ON folder.id = b.parent
                 JOIN moz_bookmarks root ON root.id = folder.parent AND root.guid = 'tags________'
                 WHERE b.type = 1 AND b.fk IS NOT NULL LIMIT ?",
            )
            .map_err(unreadable)?;
        let rows = statement
            .query_map([(MAX_BOOKMARKS * MAX_TAGS) as i64], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
            })
            .map_err(unreadable)?;
        for row in rows {
            let (place, tag) = row.map_err(unreadable)?;
            if let Some(tag) = tag {
                let tags = tags_by_place.entry(place).or_default();
                if tags.len() < MAX_TAGS {
                    tags.push(tag);
                }
            }
        }
    }

    let mut collector = Collector::default();
    let mut statement = conn
        .prepare(
            "SELECT p.url, COALESCE(b.title, ''), p.id,
               COALESCE((SELECT k.keyword FROM moz_keywords k WHERE k.place_id = p.id LIMIT 1), ''),
               COALESCE(b.dateAdded, 0)
             FROM moz_bookmarks b
             JOIN moz_places p ON p.id = b.fk
             JOIN moz_bookmarks parent ON parent.id = b.parent
             WHERE b.type = 1
               AND parent.parent NOT IN (SELECT id FROM moz_bookmarks WHERE guid = 'tags________')
             ORDER BY b.dateAdded, b.id
             LIMIT ?",
        )
        .map_err(unreadable)?;
    let rows = statement
        .query_map([(MAX_BOOKMARKS * 4) as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })
        .map_err(unreadable)?;
    for row in rows {
        let (url, title, place, keyword, added_micros) = row.map_err(unreadable)?;
        let tags = tags_by_place.get(&place).cloned().unwrap_or_default();
        collector.add(&url, &title, tags, &keyword, added_micros / 1000)?;
    }
    Ok(collector.read)
}

fn read_chromium(path: &Path) -> Result<ImportRead, String> {
    let raw = read_bytes(path, MAX_CHROMIUM_BOOKMARKS_BYTES)
        .ok_or("The browser's bookmark file could not be read")?;
    let document: Value =
        serde_json::from_slice(&raw).map_err(|_| "The browser's bookmark file is not valid")?;
    let roots = document
        .get("roots")
        .and_then(Value::as_object)
        .ok_or("The browser's bookmark file has no bookmarks")?;
    let mut collector = Collector::default();
    let mut stack: Vec<(&Value, usize)> = roots.values().map(|node| (node, 0)).collect();
    let mut visited = 0usize;
    while let Some((node, depth)) = stack.pop() {
        visited += 1;
        if visited > MAX_CHROMIUM_NODES || depth > MAX_FOLDER_DEPTH {
            return Err("The browser's bookmark file is too large or too deeply nested".into());
        }
        match node.get("type").and_then(Value::as_str) {
            Some("url") => {
                let url = node.get("url").and_then(Value::as_str).unwrap_or("");
                let title = node.get("name").and_then(Value::as_str).unwrap_or("");
                collector.add(url, title, Vec::new(), "", chromium_time(node))?;
            }
            Some("folder") => {
                if let Some(children) = node.get("children").and_then(Value::as_array) {
                    // Reversed so bookmarks keep their order when popped.
                    stack.extend(children.iter().rev().map(|child| (child, depth + 1)));
                }
            }
            _ => {}
        }
    }
    Ok(collector.read)
}

/// Chromium stores microseconds since 1601-01-01 as a decimal string.
fn chromium_time(node: &Value) -> i64 {
    const UNIX_EPOCH_OFFSET_MICROS: i64 = 11_644_473_600_000_000;
    node.get("date_added")
        .and_then(Value::as_str)
        .and_then(|value| value.parse::<i64>().ok())
        .map(|micros| (micros - UNIX_EPOCH_OFFSET_MICROS) / 1000)
        .filter(|millis| *millis > 0)
        .unwrap_or(0)
}

fn clean_tags(tags: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    tags.into_iter()
        .map(|tag| {
            tag.chars()
                .filter(|c| !c.is_control())
                .collect::<String>()
                .trim()
                .to_string()
        })
        .filter(|tag| !tag.is_empty() && tag.len() <= MAX_TAG && seen.insert(tag.to_lowercase()))
        .take(MAX_TAGS)
        .collect()
}

fn truncate(value: &str, max_bytes: usize) -> String {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn bounded_name(value: &str) -> String {
    truncate(
        &value
            .chars()
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect::<String>(),
        MAX_NAME,
    )
}

fn is_regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

fn open_regular(path: &Path, limit: u64) -> io::Result<fs::File> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() || metadata.len() > limit {
        return Err(io::Error::other("not a bounded regular file"));
    }
    Ok(file)
}

fn read_bytes(path: &Path, limit: u64) -> Option<Vec<u8>> {
    let file = open_regular(path, limit).ok()?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= limit).then_some(bytes)
}

fn read_text(path: &Path, limit: u64) -> Option<String> {
    String::from_utf8(read_bytes(path, limit)?).ok()
}

fn copy_bounded(from: &Path, to: &Path, limit: u64) -> Result<(), String> {
    let source = open_regular(from, limit)
        .map_err(|_| "The browser's bookmark database could not be read")?;
    let mut destination = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)
        .map_err(|_| "Could not prepare a private copy of the bookmark database")?;
    let copied = io::copy(&mut source.take(limit + 1), &mut destination)
        .map_err(|_| "Could not copy the browser's bookmark database")?;
    if copied > limit {
        return Err("The browser's bookmark database is too large".into());
    }
    Ok(())
}

/// A private directory removed when dropped, so copies of browser data never
/// outlive the import.
struct ScratchDir {
    path: PathBuf,
}

impl ScratchDir {
    fn create(parent: &Path) -> Result<Self, String> {
        cleanup_stale_scratch(parent);
        let path = parent.join(format!(".import-{}", Uuid::new_v4()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|_| "Could not create a private import directory")?;
        Ok(Self { path })
    }
}

/// A killed worker cannot run `Drop`; clear only scratch directories whose
/// names match the UUID format this module creates.
fn cleanup_stale_scratch(parent: &Path) {
    let Ok(entries) = fs::read_dir(parent) else {
        return;
    };
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Some(id) = name.strip_prefix(".import-") else {
            continue;
        };
        if Uuid::parse_str(id).is_err() {
            continue;
        }
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn chromium_source(path: PathBuf) -> ImportSource {
        ImportSource {
            id: path.to_string_lossy().into_owned(),
            browser: "Chromium".into(),
            profile: "Default".into(),
            family: Family::Chromium,
            path,
        }
    }

    #[test]
    fn reads_chromium_folders_in_order_and_skips_non_web_urls() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("Bookmarks");
        fs::write(
            &path,
            r#"{"roots":{"bookmark_bar":{"type":"folder","children":[
                {"type":"url","name":"One","url":"https://one.test/","date_added":"13370000000000000"},
                {"type":"folder","name":"Dev","children":[
                    {"type":"url","name":"Two","url":"https://two.test/"},
                    {"type":"url","name":"Script","url":"javascript:alert(1)"}
                ]},
                {"type":"url","name":"One again","url":"HTTPS://ONE.test/"}
            ]}}}"#,
        )
        .unwrap();
        let read = read(&chromium_source(path), temp.path()).unwrap();
        let titles: Vec<_> = read.bookmarks.iter().map(|b| b.title.as_str()).collect();
        assert_eq!(titles, ["One", "Two"]);
        assert_eq!(read.skipped, 1);
        assert_eq!(read.duplicates, 1);
        assert!(read.bookmarks[0].created_at > 0);
    }

    #[test]
    fn chromium_depth_is_bounded() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("Bookmarks");
        let mut node = r#"{"type":"url","name":"x","url":"https://x.test/"}"#.to_string();
        for _ in 0..(MAX_FOLDER_DEPTH + 2) {
            node = format!(r#"{{"type":"folder","children":[{node}]}}"#);
        }
        fs::write(&path, format!(r#"{{"roots":{{"bar":{node}}}}}"#)).unwrap();
        assert!(read(&chromium_source(path), temp.path()).is_err());
    }

    #[test]
    fn symlinked_bookmark_files_are_not_read() {
        let temp = tempdir().unwrap();
        let real = temp.path().join("real");
        fs::write(&real, r#"{"roots":{}}"#).unwrap();
        let link = temp.path().join("Bookmarks");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(read(&chromium_source(link), temp.path()).is_err());
    }

    #[test]
    fn stale_import_scratch_is_removed_but_unrelated_data_is_kept() {
        let temp = tempdir().unwrap();
        let stale = temp
            .path()
            .join(".import-00000000-0000-4000-8000-000000000000");
        fs::create_dir(&stale).unwrap();
        fs::write(stale.join("places.sqlite"), b"private browser data").unwrap();
        let unrelated = temp.path().join(".import-not-a-uuid");
        fs::create_dir(&unrelated).unwrap();

        let scratch = ScratchDir::create(temp.path()).unwrap();
        assert!(!stale.exists());
        assert!(unrelated.exists());
        assert!(scratch.path.exists());
    }

    fn firefox_places(path: &Path) {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(
            "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT);
             CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, title TEXT, guid TEXT, dateAdded INTEGER);
             CREATE TABLE moz_keywords(id INTEGER PRIMARY KEY, keyword TEXT, place_id INTEGER);
             INSERT INTO moz_places VALUES (1, 'https://rust.test/'), (2, 'place:sort=8'), (3, 'https://arch.test/');
             INSERT INTO moz_bookmarks VALUES
               (1, 2, NULL, 0, '', 'root________', 0),
               (2, 2, NULL, 1, 'menu', 'menu________', 0),
               (3, 2, NULL, 1, 'tags', 'tags________', 0),
               (10, 1, 1, 2, 'Rust', 'a', 1700000000000000),
               (11, 1, 2, 2, 'Recent', 'b', 1700000000000001),
               (12, 1, 3, 2, 'Arch', 'c', 1700000000000002),
               (20, 2, NULL, 3, 'lang', 'd', 0),
               (21, 1, 1, 20, NULL, 'e', 0);
             INSERT INTO moz_keywords VALUES (1, 'rs', 1);",
        )
        .unwrap();
    }

    #[test]
    fn reads_firefox_bookmarks_tags_and_keywords_from_a_private_copy() {
        let profile = tempdir().unwrap();
        let scratch = tempdir().unwrap();
        let places = profile.path().join("places.sqlite");
        firefox_places(&places);
        let source = ImportSource {
            id: places.to_string_lossy().into_owned(),
            browser: "Firefox".into(),
            profile: "default".into(),
            family: Family::Firefox,
            path: places,
        };
        let read = read(&source, scratch.path()).unwrap();
        assert_eq!(read.bookmarks.len(), 2);
        assert_eq!(read.skipped, 1);
        let rust = &read.bookmarks[0];
        assert_eq!(rust.title, "Rust");
        assert_eq!(rust.tags, ["lang"]);
        assert_eq!(rust.keyword, "rs");
        assert_eq!(rust.created_at, 1_700_000_000_000);
        assert_eq!(fs::read_dir(scratch.path()).unwrap().count(), 0);
    }

    #[test]
    fn discovers_firefox_and_chromium_profiles() {
        let temp = tempdir().unwrap();
        let firefox = temp.path().join("firefox");
        fs::create_dir_all(firefox.join("abc.default")).unwrap();
        fs::write(
            firefox.join("profiles.ini"),
            "[General]\nStartWithLastProfile=1\n[Profile0]\nName=default-release\nIsRelative=1\nPath=abc.default\n",
        )
        .unwrap();
        firefox_places(&firefox.join("abc.default/places.sqlite"));
        let chromium = temp.path().join("chromium");
        fs::create_dir_all(chromium.join("Profile 1")).unwrap();
        fs::write(chromium.join("Profile 1/Bookmarks"), "{}").unwrap();
        fs::write(
            chromium.join("Local State"),
            r#"{"profile":{"info_cache":{"Profile 1":{"name":"Work"}}}}"#,
        )
        .unwrap();
        let sources = discover_in(&[
            BrowserRoot {
                browser: "Firefox",
                family: Family::Firefox,
                path: firefox,
            },
            BrowserRoot {
                browser: "Chromium",
                family: Family::Chromium,
                path: chromium,
            },
        ]);
        let labels: Vec<_> = sources
            .iter()
            .map(|s| format!("{} {}", s.browser, s.profile))
            .collect();
        assert_eq!(labels, ["Firefox default-release", "Chromium Work"]);
    }
}
