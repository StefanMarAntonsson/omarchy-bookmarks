use omarchy_bookmarks_worker::{
    Repository,
    model::{BookmarkInput, UserSettings},
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
fn migrates_backs_up_and_is_idempotent() {
    let d = tempdir().unwrap();
    let json = d.path().join("bookmarks.json");
    let db = d.path().join("bookmarks.sqlite3");
    legacy(
        &json,
        r#"{"version":3,"bookmarks":[{"id":"one","title":"One","url":"https://example.test/path?x=1#f","tags":["docs"],"keyword":"ex","usageScore":2.5,"lastOpenedAt":10}]}"#,
    );
    {
        let r = Repository::open(&db, &json).unwrap();
        assert_eq!(r.all().len(), 1);
        assert_eq!(r.all()[0].keyword, "ex");
    }
    assert!(json.exists());
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
            result_count: 10,
            open_in_new_window: true,
            fetch_page_details: false,
        }
    );
}
