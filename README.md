# Bookmarks for Omarchy

A quiet, keyboard-first bookmark launcher for Omarchy. It is a Quickshell
overlay styled like a compact browser address bar, backed by a resident Rust
worker and SQLite.

The closed launcher consumes no window space. When opened it shows a centered
search field with the most-used bookmarks in individual result rows. Search
results replace those rows after typing in a scrollable three-to-ten-row
window, according to the user's setting. Literal query matches are highlighted
in result titles and URLs.

## Architecture

- `Bookmarks.qml` owns presentation, focus, keyboard handling, bounded result
  rows, selection previews in the input, and compact edit/delete modes.
- `WorkerClient.qml` owns one managed child process, version-1 newline-delimited
  JSON framing, response validation, stale-response IDs, and bounded exponential
  restart backoff.
- `src/main.rs` is the protocol/server loop. Linux parent-death signaling stops
  it when `omarchy-shell` exits.
- `src/repository.rs` owns SQLite, numbered migrations, CRUD, foreign keys,
  legacy migration, and the refreshed in-memory index.
- `src/search.rs`, `src/url_key.rs`, and `src/metadata.rs` own ranking,
  conservative duplicate keys, and bounded HTTP metadata retrieval.
- `src/browser.rs` discovers registered HTTPS handlers from XDG desktop files,
  identifies the default, and resolves explicit browser launches.

QML never reads SQLite, performs network requests, or scans the bookmark
collection. Messages are limited to 64 KiB and responses to 256 KiB. Search
returns at most ten bookmarks per page and loads further matches while scrolling.

The old QML store, import/editor components, `bookmark_helper.py`, and
`bookmark_store_init.sh` remain for compatibility and migration regression
coverage. See `docs/existing-architecture.md` for the pre-migration baseline.

## Build and worker location

Build the worker in the plugin checkout:

```bash
cargo build --release
```

During development the launcher uses:

```text
<plugin directory>/target/release/omarchy-bookmarks-worker
```

For an installed plugin, the launcher also accepts:

```text
$XDG_DATA_HOME/stefanmara.bookmarks/bin/omarchy-bookmarks-worker
```

falling back to `~/.local/share/stefanmara.bookmarks/bin/` when
`XDG_DATA_HOME` is unset. Copy the release binary there and keep it executable
if the plugin checkout does not contain `target/release`.

## Development and validation

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
./tests/run
omarchy plugin validate .
```

The test suite uses temporary SQLite databases and deterministic loopback HTTP
servers. It does not contact public websites or migrate the live store.

For local development, build and validate first. Only then link or install the
checkout under `~/.config/omarchy/plugins/stefanmara.bookmarks`. Changing the
active shell configuration is deliberately not part of the build.

Open the enabled plugin with:

```bash
omarchy-shell shell toggle stefanmara.bookmarks '{}'
```

## Hyprland shortcut

In `~/.config/hypr/bindings.lua`:

```lua
o.bind(
  "SUPER + B",
  "Bookmarks",
  "omarchy-shell shell toggle stefanmara.bookmarks '{}'"
)
```

## Keyboard controls

| Key | Action |
| --- | --- |
| Empty input | Show the configured number of most-used bookmarks as individual result rows |
| Type | Search; results replace the most-used rows |
| `Tab` | Switch between bookmark search and tag-only search |
| `Up` / `Down` | Change selection and preview its URL while searching |
| Edit a previewed URL | Clear the bookmark selection and use the field as a direct URL |
| `Enter` | Open the selected bookmark or a valid HTTP/HTTPS URL in the field |
| `Ctrl+1` – `Ctrl+9`, `Ctrl+0` | Open results 1–10 directly |
| Hold `Ctrl` | Replace the selected row with its actions and reveal result-row shortcuts; an empty input shows `Ctrl+N` and `Ctrl+S` |
| Hold `Ctrl+Alt` | Replace the selected row actions with configured non-default browsers |
| `Ctrl+N` | Add a bookmark, prefilling a valid non-duplicate URL from the field |
| `Ctrl+S` | Open settings |
| `Ctrl+E` | Edit the selected bookmark |
| `Ctrl+D` | Request deletion of the selected bookmark; `Enter` confirms |
| `Ctrl+C` | Copy the selected URL |
| `Ctrl+T` | Use the opposite of the configured opening behavior |
| `Ctrl+Alt+1` – `Ctrl+Alt+9` | Open the selected bookmark or direct URL in the corresponding configured non-default browser |
| `Escape` | Restore the search from a URL preview/edit; press again to close |

Settings use the same in-card form as adding a bookmark. They control the
default search scope, whether three through ten results are visible (the settings
row shows as many choices as fit the window), whether
bookmarks open in a new tab or a new browser window, and whether pasting a URL may
contact its website to suggest a title and description. Changes are saved in
the SQLite database and apply immediately after saving as well as on future
launcher opens. Website lookups are off by default because they disclose the
requested URL and the user's IP address to the destination.

When page-detail fetching is enabled, metadata suggestions never block saving.
A late response fills title or description only if the user has not edited that
field. Suggested tags are local, deterministic, limited to four, and require a
click to accept.

## Data, migration, and recovery

SQLite is authoritative at:

```text
$XDG_DATA_HOME/stefanmara.bookmarks/bookmarks.sqlite3
```

The legacy source remains at:

```text
$XDG_DATA_HOME/stefanmara.bookmarks/bookmarks.json
```

On the first worker start, when no successful migration is recorded, a valid
legacy version-3 JSON file is fully validated using the existing 64 MiB,
50,000-bookmark, URL, field, and duplicate limits. The worker then creates a
timestamped `bookmarks.json.migration-backup-*`, imports bookmarks, tags,
keywords, and usage data in one transaction, preserves the original JSON, and
records success in SQLite. It will not repeat the migration.

Malformed, unsafe, duplicate, or newer-format input stops migration without
overwriting the JSON or creating a misleading success marker. The worker
reports recovery guidance in the overlay. Repair the JSON or move it aside,
then remove only the incomplete `bookmarks.sqlite3` files before restarting.
Keep the JSON and timestamped backup until the migrated library has been
verified.

Foreign keys are enabled on every worker connection. Tags and bookmark-tag
relations use separate indexed tables and cascade safely when a bookmark is
deleted.

## URL and metadata policy

Only fully qualified HTTP and HTTPS URLs (including the scheme) without
embedded credentials are accepted. Duplicate
keys lowercase schemes/hosts and remove only default ports. Query parameters,
fragments, paths, percent encoding, and meaningful trailing slashes remain
distinct.

Metadata fetching uses an ordinary Rust HTTP client, follows at most four
redirects, has three-second connection and eight-second overall timeouts, reads
at most 1 MiB, accepts HTML only, and supports Open Graph title/description,
standard description metadata, and `<title>`. It executes no JavaScript and
embeds no browser.

## Remaining limitations

- Legacy keyword data is preserved and searchable. Parameter substitution for
  `%s`, `%S`, and `{searchTerms}` is not yet exposed by the minimal UI.
- The former full browser picker, HTML/JSON import dialog, menu-entry manager,
  favicon pipeline, and network opt-in panel remain in the repository but are
  not exposed in the minimal overlay. Alternate-browser launching is available
  directly through the first nine `Ctrl+Alt+number` shortcuts.
- Metadata fetching currently follows the HTTP client's normal network policy;
  deployments requiring SSRF-resistant destination filtering should keep the
  feature disabled at the network layer until the prior helper's address
  pinning is ported.
- The release binary is built separately rather than committed to Git.

## Performance

Measured on the development machine with a release build, warm filesystem cache,
and a private SQLite migration of the real 1,181-bookmark library:

| Measurement | Result |
| --- | ---: |
| Worker startup through the `hello` response, 20-run mean | 5.25 ms |
| Idle worker RSS | 1,884 KiB |
| Empty search, 500 pipelined protocol round trips | 27.37 ms total (0.055 ms/response) |
| `github` search, 500 pipelined protocol round trips | 417.04 ms total (0.834 ms/response) |

These are measurements, not promises. They include NDJSON encode/decode and
SQLite/index startup where applicable, but the pipelined figures are throughput
rather than interactive percentile latency. Hardware, library size, filesystem
cache, and system load will change them.

## License

[MIT](LICENSE)
