# Existing architecture baseline

Recorded before the Rust worker migration on 2026-09-11.

## Repository and history

The v1.0.4 plugin is a keep-loaded Omarchy `menu` plugin whose entry point is
`Bookmarks.qml`.  The meaningful release history is an initial QML/Python
implementation followed by hardening passes for data validation, network
enrichment, shared-shell safety, serialized writes, and store-load deadlines.
The many `t3 checkpoint` refs are snapshots rather than authored releases.

At the start of this migration the only dirty tracked file was
`bookmark_helper.py`.  Its change is an import-order-only edit and is
user-owned.  It must remain in place.  The Python helper and JSON initializer
also remain in the repository until the SQLite migration has replacement
coverage.

## Runtime boundaries

- `Bookmarks.qml` owns the full-screen layer-shell surface, all search and
  ranking loops, navigation, launch actions, and coordination of secondary
  views.
- `BookmarkStore.qml` loads the complete JSON document into QML, validates it,
  mutates an in-memory JavaScript array, and serializes full snapshots.
- `bookmark_helper.py` is invoked as short-lived processes for guarded file
  I/O, import, clipboard access, browser discovery, menu integration, and
  optional metadata/favicon enrichment.
- `bookmark_store_init.sh` creates a private empty version-3 JSON store without
  replacing an existing path.
- `BookmarkEditor.qml`, `BookmarkImport.qml`, `BrowserPicker.qml`,
  `MenuEntryDialog.qml`, and `NetworkEnrichmentDialog.qml` are secondary views.

The current architecture therefore copies and iterates the whole collection in
the shared `omarchy-shell` QML process and starts helper processes for most I/O.

## Legacy data format

The authoritative file is
`$XDG_DATA_HOME/stefanmara.bookmarks/bookmarks.json` (falling back to
`~/.local/share/stefanmara.bookmarks/bookmarks.json`).  Version 3 is:

```json
{
  "version": 3,
  "bookmarks": [
    {
      "id": "string",
      "title": "string",
      "url": "https://example.test/path",
      "tags": ["tag"],
      "keyword": "optional-shortcut",
      "favicon": "optional-data:image/png;base64,...",
      "usageScore": 0.0,
      "lastOpenedAt": 0
    }
  ]
}
```

The helper accepts a bare array and older object versions when importing, but
rejects versions newer than 3.  Limits include 64 MiB per store, 50,000
bookmarks, 2,048 title characters, 8,192 URL characters, 64 tags of 128
characters, a 128-character whitespace-free keyword, and a bounded embedded
PNG favicon.  Invalid or partially invalid stores enter read-only recovery
instead of being overwritten.

## Existing behavior worth preserving

- HTTP(S)-only URL validation and conservative duplicate checks.
- Atomic serialized writes, private permissions, bounded parsing, import
  backups, and fail-closed recovery.
- Tags, parameterized `%s`, `%S`, and `{searchTerms}` keywords, usage score,
  last-opened time, browser launch, copy, and explicit delete confirmation.
- Optional bounded metadata fetches and deterministic local behavior when the
  network fails.

The new worker will make SQLite authoritative while preserving this JSON file,
creating a timestamped backup before first import, and recording successful
migration in SQLite.

