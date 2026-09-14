use omarchy_bookmarks_worker::{
    Repository,
    model::{BookmarkInput, DefaultResultOrder, UserSettings},
    protocol::{self, Command, Effect, Request, SearchScope},
};
use std::{fs, path::Path};
use tempfile::tempdir;

fn legacy(path: &Path, body: &str) {
    fs::write(path, body).unwrap()
}
fn input(id: &str, url: &str, title: &str) -> BookmarkInput {
    BookmarkInput {
        id: id.into(),
        url: url.into(),
        title: title.into(),
        description: String::new(),
        tags: vec!["rust".into()],
        keyword: String::new(),
    }
}

#[test]
fn exact_url_match_leads_related_results() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    let exact = r
        .add(input("", "https://www.youtube.com/", "Youtube"))
        .unwrap();
    for n in 0..6 {
        // Titles that outrank the exact bookmark on text score alone.
        r.add(input(
            "",
            &format!("https://www.youtube.com/watch?v={n}"),
            &format!("https://www.youtube.com/ video {n}"),
        ))
        .unwrap();
    }
    let effect = protocol::handle(
        &mut r,
        Request {
            version: 1,
            id: 1,
            command: Command::Search {
                query: "https://www.youtube.com/".into(),
                limit: 5,
                offset: 0,
                scope: SearchScope::All,
            },
        },
    );
    let Effect::Response(response) = effect else {
        panic!()
    };
    let result = response.result.unwrap();
    assert_eq!(result["exactMatch"], true);
    let items = result["items"].as_array().unwrap().clone();
    let ids: Vec<&str> = items.iter().map(|i| i["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 5);
    assert_eq!(ids[0], exact.id);
    assert_eq!(ids.iter().filter(|id| **id == exact.id).count(), 1);
}

#[test]
fn valid_unbookmarked_url_is_marked_for_direct_opening() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    let effect = protocol::handle(
        &mut r,
        Request {
            version: 1,
            id: 1,
            command: Command::Search {
                query: "https://example.test/new".into(),
                limit: 5,
                offset: 0,
                scope: SearchScope::All,
            },
        },
    );
    let Effect::Response(response) = effect else {
        panic!()
    };
    let result = response.result.unwrap();
    assert_eq!(result["isUrl"], true);
    assert_eq!(result["exactMatch"], false);
}

#[test]
fn migrates_public_v1_store_backs_up_and_is_idempotent() {
    let d = tempdir().unwrap();
    let json = d.path().join("bookmarks.json");
    let db = d.path().join("bookmarks.sqlite3");
    // Mirrors the version-3 shape written by the public v1.0.4 store. The
    // favicon is intentionally present: v2 no longer renders favicons, but an
    // otherwise valid v1 library must still migrate.
    let original = r#"{"version":3,"bookmarks":[{"id":"one","title":"One","url":"https://example.test/path?x=1#f","tags":["docs","reference"],"keyword":"ex","favicon":"data:image/png;base64,iVBORw0KGgo=","usageScore":2.5,"lastOpenedAt":10}]}"#;
    legacy(&json, original);
    {
        let r = Repository::open(&db, &json).unwrap();
        assert_eq!(r.all().len(), 1);
        let bookmark = &r.all()[0];
        assert_eq!(bookmark.id, "one");
        assert_eq!(bookmark.title, "One");
        assert_eq!(bookmark.original_url, "https://example.test/path?x=1#f");
        assert_eq!(bookmark.tags, ["docs", "reference"]);
        assert_eq!(bookmark.keyword, "ex");
        assert_eq!(bookmark.usage_score, 2.5);
        assert_eq!(bookmark.last_opened_at, 10);
    }
    assert!(json.exists());
    assert_eq!(fs::read_to_string(&json).unwrap(), original);
    assert_eq!(
        fs::read_dir(d.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("migration-backup"))
            .count(),
        1
    );
    {
        let r = Repository::open(&db, &json).unwrap();
        assert_eq!(r.all().len(), 1);
    }
    assert_eq!(
        fs::read_dir(d.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("migration-backup"))
            .count(),
        1
    );
}

#[test]
fn malformed_legacy_stops_without_backup_or_overwrite() {
    let d = tempdir().unwrap();
    let json = d.path().join("bookmarks.json");
    legacy(&json, "not json");
    let before = fs::read(&json).unwrap();
    let err = Repository::open(&d.path().join("db.sqlite3"), &json)
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("preserved"));
    assert_eq!(fs::read(&json).unwrap(), before);
    assert_eq!(
        fs::read_dir(d.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("migration-backup"))
            .count(),
        0
    );
}

#[test]
fn persistence_crud_duplicate_and_foreign_keys() {
    let d = tempdir().unwrap();
    let db = d.path().join("db.sqlite3");
    let json = d.path().join("missing.json");
    let id;
    {
        let mut r = Repository::open(&db, &json).unwrap();
        let b = r
            .add(input("", "https://Example.test:443/a/", "First"))
            .unwrap();
        id = b.id.clone();
        assert!(
            r.add(input("", "https://example.test/a/", "Duplicate"))
                .is_err()
        );
        let mut changed = input(&id, "https://example.test/a/?q=1", "Edited");
        changed.tags = vec!["new".into()];
        assert_eq!(r.edit(changed).unwrap().title, "Edited");
    }
    {
        let mut r = Repository::open(&db, &json).unwrap();
        assert_eq!(r.all().len(), 1);
        assert!(r.delete(&id).unwrap());
        assert!(r.all().is_empty());
    }
}

#[test]
fn protocol_invalid_version_and_bounded_search() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    for n in 0..12 {
        r.add(input(
            "",
            &format!("https://{n}.test"),
            &format!("Alpha {n}"),
        ))
        .unwrap();
    }
    let effect = protocol::handle(
        &mut r,
        Request {
            version: 1,
            id: 9,
            command: Command::Search {
                query: "alpha".into(),
                limit: 500,
                offset: 0,
                scope: SearchScope::All,
            },
        },
    );
    match effect {
        Effect::Response(response) => {
            let result = response.result.unwrap();
            assert_eq!(result["items"].as_array().unwrap().len(), 10);
            assert_eq!(result["hasMore"], true);
            assert_eq!(result["offset"], 0);
        }
        _ => panic!(),
    };
    let effect = protocol::handle(
        &mut r,
        Request {
            version: 1,
            id: 10,
            command: Command::Search {
                query: "alpha".into(),
                limit: 5,
                offset: 5,
                scope: SearchScope::All,
            },
        },
    );
    match effect {
        Effect::Response(response) => {
            let result = response.result.unwrap();
            assert_eq!(result["items"].as_array().unwrap().len(), 5);
            assert_eq!(result["hasMore"], true);
            assert_eq!(result["offset"], 5);
        }
        _ => panic!(),
    };
    let effect = protocol::handle(
        &mut r,
        Request {
            version: 99,
            id: 11,
            command: Command::Hello,
        },
    );
    match effect {
        Effect::Response(response) => assert!(!response.ok),
        _ => panic!(),
    }

    let effect = protocol::handle(
        &mut r,
        Request {
            version: 1,
            id: 12,
            command: Command::Hello,
        },
    );
    match effect {
        Effect::Response(response) => {
            assert_eq!(response.result.unwrap()["maxResults"], 10);
        }
        _ => panic!(),
    }
}

#[test]
fn cascade_deletes_relationships() {
    let d = tempdir().unwrap();
    let db = d.path().join("db");
    let mut r = Repository::open(&db, &d.path().join("none")).unwrap();
    let b = r.add(input("", "https://one.test", "One")).unwrap();
    r.delete(&b.id).unwrap();
    let c = rusqlite::Connection::open(db).unwrap();
    c.pragma_update(None, "foreign_keys", "ON").unwrap();
    let count: i64 = c
        .query_row("SELECT count(*) FROM bookmark_tags", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn settings_have_safe_defaults_validate_and_persist() {
    let d = tempdir().unwrap();
    let db = d.path().join("db");
    let missing = d.path().join("none");
    {
        let mut r = Repository::open(&db, &missing).unwrap();
        assert_eq!(r.settings().unwrap(), UserSettings::default());
        let saved = UserSettings {
            default_search_scope: "tags".into(),
            default_result_order: DefaultResultOrder::RecentlyUsed,
            result_count: 10,
            open_in_new_window: true,
            fetch_page_details: false,
        };
        assert_eq!(r.save_settings(saved.clone()).unwrap(), saved);
        assert!(
            r.save_settings(UserSettings {
                result_count: 2,
                ..UserSettings::default()
            })
            .is_err()
        );
        assert!(
            r.save_settings(UserSettings {
                result_count: 11,
                ..UserSettings::default()
            })
            .is_err()
        );
    }
    let r = Repository::open(&db, &missing).unwrap();
    assert_eq!(
        r.settings().unwrap(),
        UserSettings {
            default_search_scope: "tags".into(),
            default_result_order: DefaultResultOrder::RecentlyUsed,
            result_count: 10,
            open_in_new_window: true,
            fetch_page_details: false,
        }
    );
}

#[test]
fn settings_saved_before_result_order_was_added_keep_the_default() {
    let d = tempdir().unwrap();
    let db = d.path().join("db");
    let missing = d.path().join("none");
    {
        let _r = Repository::open(&db, &missing).unwrap();
    }
    {
        let connection = rusqlite::Connection::open(&db).unwrap();
        connection.execute(
            "INSERT INTO app_metadata(key,value) VALUES('user_settings_v1',?)",
            [r#"{"defaultSearchScope":"all","resultCount":5,"openInNewWindow":false,"fetchPageDetails":false}"#],
        ).unwrap();
    }
    let r = Repository::open(&db, &missing).unwrap();
    assert_eq!(
        r.settings().unwrap().default_result_order,
        DefaultResultOrder::MostUsed
    );
}

fn search(r: &mut Repository, query: &str, limit: usize, offset: usize) -> serde_json::Value {
    let Effect::Response(response) = protocol::handle(
        r,
        Request {
            version: 1,
            id: 1,
            command: Command::Search {
                query: query.into(),
                limit,
                offset,
                scope: SearchScope::All,
            },
        },
    ) else {
        panic!()
    };
    let encoded = protocol::encode_response(&response);
    assert!(encoded.len() <= protocol::MAX_RESPONSE);
    serde_json::from_str(&encoded).unwrap()
}

#[test]
fn empty_search_uses_the_saved_result_order() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    let frequent = r
        .add(input("", "https://frequent.test", "Frequent"))
        .unwrap();
    let recent = r.add(input("", "https://recent.test", "Recent")).unwrap();
    r.record_open(&frequent.id).unwrap();
    r.record_open(&frequent.id).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(2));
    r.record_open(&recent.id).unwrap();

    assert_eq!(
        search(&mut r, "", 2, 0)["result"]["items"][0]["id"],
        frequent.id
    );
    r.save_settings(UserSettings {
        default_result_order: DefaultResultOrder::RecentlyUsed,
        ..UserSettings::default()
    })
    .unwrap();
    assert_eq!(
        search(&mut r, "", 2, 0)["result"]["items"][0]["id"],
        recent.id
    );
}

#[test]
fn maximum_size_bookmarks_are_paged_within_the_response_limit() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    for n in 0..12 {
        let mut item = input("", &format!("https://example.test/{n}"), &"\"".repeat(2048));
        item.description = "\u{1}".repeat(8192);
        item.tags = (0..64)
            .map(|t| format!("{t}{}", "\"".repeat(120)))
            .collect();
        r.add(item).unwrap();
    }
    // Empty queries show one page of most-used bookmarks, shortened to fit.
    let result = search(&mut r, "", 10, 0);
    assert_eq!(result["ok"], true);
    let items = result["result"]["items"].as_array().unwrap().len();
    assert!((1..10).contains(&items));
    let mut offset = 0;
    loop {
        let result = search(&mut r, "example", 10, offset);
        assert_eq!(result["ok"], true);
        let page = result["result"]["items"].as_array().unwrap().len();
        assert!(page >= 1);
        offset += page;
        if result["result"]["hasMore"] != true {
            break;
        }
    }
    assert_eq!(offset, 12);
}

#[test]
fn page_lookup_is_refused_unless_enabled_in_saved_settings() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    let request = |id| Request {
        version: 1,
        id,
        command: Command::FetchMetadata {
            url: "https://example.test/".into(),
            metadata_request_id: 1,
        },
    };
    let Effect::Response(response) = protocol::handle(&mut r, request(1)) else {
        panic!("lookup must not start while disabled")
    };
    assert!(!response.ok);
    r.save_settings(UserSettings {
        fetch_page_details: true,
        ..UserSettings::default()
    })
    .unwrap();
    assert!(matches!(
        protocol::handle(&mut r, request(2)),
        Effect::Metadata { .. }
    ));
}

#[test]
fn legacy_fifo_and_symlink_are_rejected_without_blocking() {
    let d = tempdir().unwrap();
    let fifo = d.path().join("fifo.json");
    let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let err = Repository::open(&d.path().join("a.sqlite3"), &fifo)
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("not a regular file"), "{err}");

    let target = d.path().join("real.json");
    legacy(&target, r#"{"version":3,"bookmarks":[]}"#);
    let link = d.path().join("link.json");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let err = Repository::open(&d.path().join("b.sqlite3"), &link)
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("not a regular file"), "{err}");
}

#[test]
fn malformed_legacy_errors_do_not_quote_file_content() {
    let d = tempdir().unwrap();
    let json = d.path().join("bookmarks.json");
    legacy(
        &json,
        r#"{"version":3,"bookmarks":[{"url":"https://a.test","usageScore":"<img src=x>"}]}"#,
    );
    let err = Repository::open(&d.path().join("db"), &json)
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("line 1"), "{err}");
    assert!(!err.contains("<img"), "{err}");
}

#[test]
fn externally_inflated_database_fails_closed() {
    let d = tempdir().unwrap();
    let db = d.path().join("db");
    {
        let mut r = Repository::open(&db, &d.path().join("none")).unwrap();
        r.add(input("", "https://one.test", "One")).unwrap();
    }
    let c = rusqlite::Connection::open(&db).unwrap();
    c.execute("UPDATE bookmarks SET description=?", [&"x".repeat(100_000)])
        .unwrap();
    drop(c);
    let err = Repository::open(&db, &d.path().join("none"))
        .err()
        .unwrap()
        .to_string();
    assert!(err.contains("safety limits"), "{err}");
}

#[test]
fn database_files_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let d = tempdir().unwrap();
    let db = d.path().join("data").join("bookmarks.sqlite3");
    fs::create_dir(db.parent().unwrap()).unwrap();
    fs::set_permissions(db.parent().unwrap(), fs::Permissions::from_mode(0o755)).unwrap();
    {
        let mut r = Repository::open(&db, &d.path().join("none")).unwrap();
        r.add(input("", "https://one.test", "One")).unwrap();
    }
    fs::set_permissions(&db, fs::Permissions::from_mode(0o644)).unwrap();
    let _r = Repository::open(&db, &d.path().join("none")).unwrap();
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&db), 0o600);
    assert_eq!(mode(db.parent().unwrap()), 0o700);
    let wal = db.with_file_name("bookmarks.sqlite3-wal");
    if wal.exists() {
        assert_eq!(mode(&wal), 0o600);
    }
}

#[test]
fn newer_database_schema_is_refused_without_migration() {
    let d = tempdir().unwrap();
    let db = d.path().join("bookmarks.sqlite3");
    let connection = rusqlite::Connection::open(&db).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
             INSERT INTO schema_migrations VALUES(999, 0);",
        )
        .unwrap();
    drop(connection);

    let error = Repository::open(&db, &d.path().join("none"))
        .err()
        .unwrap()
        .to_string();
    assert!(error.contains("newer version"), "{error}");

    let connection = rusqlite::Connection::open(&db).unwrap();
    let bookmarks_table: i64 = connection
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='bookmarks'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(bookmarks_table, 0);
}

#[test]
fn symlinked_data_directory_is_refused() {
    let d = tempdir().unwrap();
    let real = d.path().join("real-data");
    fs::create_dir(&real).unwrap();
    let linked = d.path().join("linked-data");
    std::os::unix::fs::symlink(&real, &linked).unwrap();

    let error = Repository::open(&linked.join("bookmarks.sqlite3"), &linked.join("none"))
        .err()
        .unwrap()
        .to_string();
    assert!(error.contains("symlinked data directory"), "{error}");
    assert!(!real.join("bookmarks.sqlite3").exists());
}

#[test]
fn opening_records_usage_and_rejects_oversized_ids() {
    let d = tempdir().unwrap();
    let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
    let b = r.add(input("", "https://one.test", "One")).unwrap();
    r.record_open(&b.id).unwrap();
    assert_eq!(r.get(&b.id).unwrap().usage_score, 1.0);
    assert!(
        r.add(input(&"i".repeat(300), "https://two.test", "Two"))
            .is_err()
    );
    let mut tagged = input("", "https://three.test", "Three");
    tagged.tags = vec!["a\u{1f}b".into()];
    assert!(r.add(tagged).is_err());
}

mod library {
    use super::*;
    use omarchy_bookmarks_worker::{
        import::{ImportRead, ImportedBookmark},
        library::BackupReason,
    };
    use std::os::unix::fs::PermissionsExt;

    fn tagged(url: &str, title: &str, tags: &[&str]) -> BookmarkInput {
        let mut item = input("", url, title);
        item.tags = tags.iter().map(|t| t.to_string()).collect();
        item
    }

    fn summary(r: &Repository) -> Vec<(String, Vec<String>)> {
        let mut rows: Vec<_> = r
            .all()
            .iter()
            .map(|b| {
                let mut tags = b.tags.clone();
                tags.sort();
                (b.original_url.clone(), tags)
            })
            .collect();
        rows.sort();
        rows
    }

    #[test]
    fn backup_clear_and_restore_round_trip_keeps_settings() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(tagged("https://one.test/", "One", &["a", "b"]))
            .unwrap();
        r.add(tagged("https://two.test/", "Two", &["b"])).unwrap();
        let before = summary(&r);
        let backup = r.create_backup(BackupReason::Manual).unwrap();
        assert_eq!(backup.bookmarks, 2);
        let mode = fs::metadata(r.backups_dir().join(&backup.name))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);

        let (removed, clear_backup) = r.clear_library().unwrap();
        assert_eq!(removed, 2);
        assert!(clear_backup.is_some());
        assert!(r.all().is_empty());
        r.save_settings(UserSettings {
            result_count: 7,
            ..UserSettings::default()
        })
        .unwrap();

        // Restoring into an empty library needs no safety backup.
        assert_eq!(r.restore_backup(&backup.name).unwrap(), None);
        assert_eq!(summary(&r), before);
        assert_eq!(r.settings().unwrap().result_count, 7);

        let listed = r.list_backups().unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].reason, "before-clear");
        assert!(listed.iter().all(|b| b.bookmarks == 2));

        // Reopening sees the restored library.
        drop(r);
        let r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        assert_eq!(summary(&r), before);
    }

    #[test]
    fn restore_refuses_unknown_names_and_damaged_files_without_changes() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(input("", "https://keep.test/", "Keep")).unwrap();
        for name in [
            "../bookmarks.sqlite3",
            "bookmarks.sqlite3",
            "bookmarks-20260101T000000000Z-manual.sqlite3",
        ] {
            assert!(r.restore_backup(name).is_err(), "{name}");
        }
        fs::create_dir_all(r.backups_dir()).unwrap();
        let damaged = "bookmarks-20260101T000000000Z-manual.sqlite3";
        fs::write(r.backups_dir().join(damaged), b"not a database").unwrap();
        assert!(r.restore_backup(damaged).is_err());
        let foreign = "bookmarks-20260101T000001000Z-manual.sqlite3";
        rusqlite::Connection::open(r.backups_dir().join(foreign))
            .unwrap()
            .execute_batch("CREATE TABLE other(x);")
            .unwrap();
        assert!(r.restore_backup(foreign).is_err());
        assert_eq!(r.all().len(), 1);
        // A failed restore never leaves a safety backup behind.
        assert!(
            r.list_backups()
                .unwrap()
                .iter()
                .all(|b| b.reason == "manual")
        );
    }

    #[test]
    fn restore_refuses_backups_from_newer_versions() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(input("", "https://one.test/", "One")).unwrap();
        let backup = r.create_backup(BackupReason::Manual).unwrap();
        let path = r.backups_dir().join(&backup.name);
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute("INSERT INTO schema_migrations VALUES(99, 0)", [])
            .unwrap();
        let err = r.restore_backup(&backup.name).unwrap_err().to_string();
        assert!(err.contains("newer"), "{err}");
    }

    #[test]
    fn examples_replace_the_library_and_can_be_undone() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(input("", "https://mine.test/", "Mine")).unwrap();
        let (added, backup) = r.load_examples().unwrap();
        assert!(added >= 20);
        assert_eq!(r.all().len(), added);
        let top = search(&mut r, "", 5, 0);
        assert_eq!(top["result"]["items"][0]["title"], "The Omarchy Manual");
        r.restore_backup(&backup.unwrap()).unwrap();
        assert_eq!(r.all().len(), 1);
        assert_eq!(r.all()[0].title, "Mine");
    }

    #[test]
    fn automatic_backups_are_pruned_but_manual_ones_are_kept() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(input("", "https://one.test/", "One")).unwrap();
        let manual = r.create_backup(BackupReason::Manual).unwrap();
        for _ in 0..25 {
            r.create_backup(BackupReason::BeforeImport).unwrap();
        }
        let listed = r.list_backups().unwrap();
        assert_eq!(
            listed
                .iter()
                .filter(|b| b.reason == "before-import")
                .count(),
            20
        );
        assert!(listed.iter().any(|b| b.name == manual.name));
    }

    fn imported(url: &str, title: &str, tags: &[&str]) -> ImportedBookmark {
        let (url, key) = omarchy_bookmarks_worker::url_key::normalize_url(url).unwrap();
        ImportedBookmark {
            url,
            key,
            title: title.into(),
            tags: tags.iter().map(|t| t.to_string()).collect(),
            keyword: String::new(),
            created_at: 1_700_000_000_000,
        }
    }

    #[test]
    fn import_adds_only_new_bookmarks_after_a_backup() {
        let d = tempdir().unwrap();
        let mut r =
            Repository::open(&d.path().join("bookmarks.sqlite3"), &d.path().join("none")).unwrap();
        r.add(input("", "https://existing.test/", "Existing title"))
            .unwrap();
        let read = ImportRead {
            bookmarks: vec![
                imported("https://existing.test/", "Browser title", &[]),
                imported("https://new.test/", "New", &["from-browser"]),
            ],
            skipped: 2,
            duplicates: 1,
        };
        let preview = r.preview_import(&read);
        assert_eq!(
            (
                preview.found,
                preview.new,
                preview.already_saved,
                preview.skipped
            ),
            (5, 1, 1, 3)
        );
        let summary = r.import(read).unwrap();
        assert_eq!(summary.added, 1);
        assert!(summary.backup.is_some());
        assert_eq!(r.all().len(), 2);
        let existing = r.find_url("https://existing.test/").unwrap().unwrap();
        assert_eq!(existing.title, "Existing title");
        let new = r.find_url("https://new.test/").unwrap().unwrap();
        assert_eq!(new.tags, ["from-browser"]);
        assert_eq!(new.created_at, 1_700_000_000_000);

        let again = r.import(ImportRead {
            bookmarks: vec![imported("https://new.test/", "New", &[])],
            ..ImportRead::default()
        });
        let again = again.unwrap();
        assert_eq!(again.added, 0);
        assert!(again.backup.is_none());
    }

    #[test]
    fn protocol_refuses_import_sources_it_did_not_discover() {
        let d = tempdir().unwrap();
        let mut r = Repository::open(&d.path().join("db"), &d.path().join("none")).unwrap();
        let Effect::Response(response) = protocol::handle(
            &mut r,
            Request {
                version: 1,
                id: 1,
                command: Command::ImportPreview {
                    source_id: "/etc/passwd".into(),
                },
            },
        ) else {
            panic!()
        };
        assert!(!response.ok);
    }
}
