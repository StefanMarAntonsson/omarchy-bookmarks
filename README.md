# Bookmarks for Omarchy

Bookmarks for Omarchy keeps your bookmarks independent of any one browser.
Search one library, open a bookmark in your default browser or another installed
browser, and copy its URL to share without remembering which browser originally
saved it. The menu searches only your bookmarks, never commands or installed
applications, and follows the active Omarchy theme.

![Bookmarks for Omarchy](preview.png)

## Features

- Search bookmark titles, URLs, tags, and keywords.
- Filter by tag with `#tag` and combine filters such as `#dash git`.
- Browse dedicated bookmark, tag, and keyword lists with `Tab`.
- Rank an empty search by frequently and recently opened bookmarks.
- Add, edit, delete, and import bookmarks without leaving the menu.
- Add an HTTP(S) URL directly from the clipboard and fetch its title/favicon.
- Import Netscape bookmark HTML or this plugin's JSON format.
- Open in a browser tab by default or in a new window with `Ctrl+T`.
- Open a bookmark in any installed HTTPS browser with `Ctrl+Tab` without
  changing the system default.
- Copy the selected bookmark URL with `Ctrl+C`.
- Optionally add a **Bookmarks** entry to the main Omarchy menu after an
  explicit in-plugin confirmation.
- Serialize and persist changes atomically, with timestamped backups before imports.

The plugin accepts HTTP and HTTPS URLs only. It intentionally rejects
JavaScript bookmarklets, `file:` URLs, `mailto:` links, and folders.

## Requirements

- Omarchy with shell plugin support.
- Python 3.
- `zenity` for the import file picker.
- `wl-clipboard` for adding from and copying to the clipboard.
- ImageMagick for favicons from imported HTML and clipboard metadata. Bookmark
  operations and plugin JSON imports still work without ImageMagick, but new
  external favicons cannot be converted and embedded.

On Omarchy, missing optional packages can be installed with:

```bash
omarchy pkg add python zenity wl-clipboard imagemagick
```

## Installation

Install and enable the plugin from GitHub:

```bash
omarchy plugin add https://github.com/StefanMarAntonsson/omarchy-bookmarks.git --enable
```

The plugin can always be opened directly with:

```bash
omarchy-shell shell toggle stefanmara.bookmarks
```

On first open, the plugin offers to add a **Bookmarks** entry to the main
Omarchy menu. It explains the exact configuration file involved and changes it
only after you choose **Add entry**. You can revisit this choice with `Ctrl+M`.
Once the entry is added, no separate keybinding is required.

For faster access, a direct keybinding is recommended. Use `Super+B` or replace
it with any key combination you prefer in `~/.config/hypr/bindings.lua`:

```lua
o.bind(
  "SUPER + B",
  "Bookmarks",
  "omarchy-shell shell toggle stefanmara.bookmarks"
)
```

## Keyboard controls

### Bookmark list

| Key | Action |
| --- | --- |
| Type | Search bookmarks |
| `Up` / `Down` | Select a bookmark |
| `Enter` | Open in a new tab |
| `Ctrl+C` | Copy the selected bookmark URL |
| `Ctrl+T` | Open in a new window |
| `Ctrl+Tab` | Choose an installed browser and open there |
| `Tab` | Show tags, then keywords |
| `Ctrl+M` | Add or remove the main Omarchy menu entry |
| `Ctrl+N` | Add a bookmark manually |
| `Ctrl+V` | Add the HTTP(S) URL in the clipboard |
| `Ctrl+I` | Import an HTML or JSON bookmark file |
| `Ctrl+E` | Edit the selected bookmark |
| `Delete` | Delete with confirmation |
| `Ctrl+Z` | Undo the most recent clipboard addition |
| `Escape` | Clear the search, then close |

### Tag and keyword lists

| Key | Action |
| --- | --- |
| Type | Search the current list |
| `Up` / `Down` | Select an item |
| `Enter` | Replace the bookmark search with the selected item |
| `Ctrl+Enter` | Append the selected item to the bookmark search |
| `Tab` / `Shift+Tab` | Cycle forward or backward between lists |
| `Escape` | Clear the list search, then return to bookmarks |

Parameterized keywords support `%s`, `%S`, and `{searchTerms}` URL templates.
For example, a keyword named `mdn` can be used as `mdn flexbox`.

## Data and privacy

Bookmarks are stored outside the plugin checkout at:

```text
$XDG_DATA_HOME/stefanmara.bookmarks/bookmarks.json
```

When `XDG_DATA_HOME` is unset, the location is:

```text
~/.local/share/stefanmara.bookmarks/bookmarks.json
```

The directory and an empty bookmark store are created automatically on first
run only when the data file does not already exist. An existing store is never
overwritten during initialization, so bookmarks survive plugin updates and
reinstallation.

Plugin updates and removal do not delete bookmarks. To remove all saved data,
delete the data directory manually after removing the plugin.

The plugin does not change the main Omarchy menu unless you explicitly choose
**Add entry**. If approved, the entry is stored as a clearly marked block in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. Existing menu entries and
comments are preserved. Your choice is stored privately in the plugin data
directory. The entry is hidden while the plugin is disabled or absent, and the
plugin removes its managed block during the normal disable/uninstall flow.

All writes are atomic and serialized. Imports create a private timestamped
backup beside `bookmarks.json`; the newest ten backups are retained so repeated
imports cannot grow the data directory indefinitely.

Usage-ranking updates are kept in memory and flushed after five opens or five
minutes, whichever comes first. Any bookmark edit flushes them immediately.
This avoids rewriting a favicon-heavy store for every individual launch while
keeping frequently used ordering persistent.

If the store is malformed, contains invalid or duplicate-ID entries, or uses a
newer data format, the plugin enters read-only recovery mode instead of
overwriting it. Repair the file, or move it aside and restart the shell to begin
with an empty store:

```bash
mv ~/.local/share/stefanmara.bookmarks/bookmarks.json \
  ~/.local/share/stefanmara.bookmarks/bookmarks.json.recovery-$(date +%Y%m%d-%H%M%S)
omarchy restart shell
```

Use the corresponding `$XDG_DATA_HOME` path if that variable is configured.

The plugin makes a network request only when `Ctrl+V` is used to fetch page
metadata and a favicon. Browser discovery reads local desktop entries, and
imported HTML is processed locally. Favicons are converted to small PNG data
URLs and stored inside `bookmarks.json`.

## Updates and removal

```bash
omarchy plugin update stefanmara.bookmarks
omarchy plugin remove stefanmara.bookmarks
```

Remove your recommended `Super+B` block (or custom binding) from
`~/.config/hypr/bindings.lua` if the plugin is uninstalled. If Omarchy was not
running during removal and could not perform automatic menu cleanup, remove the
small block between the `BEGIN stefanmara.bookmarks` and
`END stefanmara.bookmarks` comments in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`.

## Development

Validate the helper, storage initializer, manifest, QML, and live persistence
regression tests:

```bash
./tests/run
```

For live development, link the checkout into Omarchy's plugin directory:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/stefanmara.bookmarks
omarchy plugin enable stefanmara.bookmarks
omarchy restart shell
```

Before publishing, validate the same manifest users will install:

```bash
omarchy plugin validate .
```

## License

[MIT](LICENSE)

Third-party product names and site icons visible in the preview remain the
property of their respective owners and are shown only as bookmark examples.
