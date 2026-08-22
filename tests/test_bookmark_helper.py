import json
import base64
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

import bookmark_helper


def png_header(width=32, height=32):
    return (
        b"\x89PNG\r\n\x1a\n"
        + b"\x00\x00\x00\rIHDR"
        + int(width).to_bytes(4, "big")
        + int(height).to_bytes(4, "big")
        + b"\x08\x06\x00\x00\x00"
    )


class UrlTests(unittest.TestCase):
    def test_accepts_http_and_https_only(self):
        self.assertEqual(
            bookmark_helper.valid_url("https://example.com/path"),
            "https://example.com/path",
        )
        self.assertEqual(
            bookmark_helper.valid_url("example.com", add_scheme=True),
            "https://example.com",
        )
        for value in (
            "javascript:alert(1)",
            "file:///tmp/example",
            "mailto:user@example.com",
            "https://user:password@example.com",
            "https://example.com/a path",
            "https://:",
            "https://example.com:99999",
            "https://[broken",
            "https://[::::]",
            "https://999.999.999.999",
            "https://-invalid.example",
        ):
            with self.subTest(value=value):
                self.assertEqual(bookmark_helper.valid_url(value), "")

    def test_accepts_valid_ports_ip_addresses_and_local_hosts(self):
        for value in (
            "https://example.com:8443/path",
            "http://127.0.0.1:8080",
            "https://[::1]/",
            "http://localhost/test",
        ):
            with self.subTest(value=value):
                self.assertEqual(bookmark_helper.valid_url(value), value)

    def test_canonicalizes_default_ports_and_empty_paths(self):
        self.assertEqual(
            bookmark_helper.canonical_url("HTTPS://Example.COM:443"),
            "https://example.com/",
        )


class ImportTests(unittest.TestCase):
    def test_imports_html_tags_and_shortcut_url(self):
        html = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
  <DT><A HREF="https://github.com/" TAGS="development, code" SHORTCUTURL="gh">GitHub</A>
  <DT><A HREF="javascript:alert(1)">Rejected</A>
</DL><p>
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "bookmarks.html"
            store = root / "bookmarks.json"
            source.write_text(html, encoding="utf-8")

            result = bookmark_helper.import_bookmarks(str(source), str(store))

        self.assertTrue(result["ok"])
        self.assertEqual(result["stats"]["found"], 2)
        self.assertEqual(result["stats"]["ready"], 1)
        self.assertEqual(result["stats"]["rejected"], 1)
        self.assertEqual(result["items"][0]["tags"], ["development", "code"])
        self.assertEqual(result["items"][0]["keyword"], "gh")

    def test_reports_existing_json_bookmarks(self):
        existing = {
            "version": 3,
            "bookmarks": [{"id": "one", "url": "https://example.com/"}],
        }
        incoming = {
            "bookmarks": [
                {"url": "https://example.com", "title": "Existing"},
                {"url": "https://other.example", "title": "New"},
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "incoming.json"
            store = root / "bookmarks.json"
            source.write_text(json.dumps(incoming), encoding="utf-8")
            store.write_text(json.dumps(existing), encoding="utf-8")

            result = bookmark_helper.import_bookmarks(str(source), str(store))

        self.assertEqual(result["stats"]["duplicatesExisting"], 1)
        self.assertEqual(result["stats"]["new"], 1)

    def test_rejects_json_with_an_invalid_root_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "invalid.json"
            source.write_text("1", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "array or object"):
                bookmark_helper.import_bookmarks(str(source), "missing-store.json")

            process = subprocess.run(
                [
                    sys.executable,
                    str(PROJECT_ROOT / "bookmark_helper.py"),
                    "import",
                    str(source),
                    str(Path(directory) / "store.json"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            response = json.loads(process.stdout)

        self.assertEqual(process.returncode, 1)
        self.assertFalse(response["ok"])
        self.assertIn("array or object", response["error"])
        self.assertEqual(process.stderr, "")

    def test_preserves_valid_plugin_png_without_imagemagick(self):
        raw = png_header()
        encoded = base64.b64encode(raw).decode("ascii")
        item = bookmark_helper.normalize_item({
            "url": "https://example.com",
            "favicon": "data:image/png;base64," + encoded,
        })

        self.assertIsNotNone(item)
        self.assertEqual(item["favicon"], "data:image/png;base64," + encoded)

    def test_rejects_oversized_import_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bookmarks.json"
            source.write_text("{}" * 20, encoding="utf-8")
            with mock.patch.object(bookmark_helper, "MAX_IMPORT_BYTES", 16):
                with self.assertRaisesRegex(ValueError, "too large"):
                    bookmark_helper.import_bookmarks(str(source), "missing-store.json")

    def test_rejects_excessive_bookmark_count(self):
        data = {"bookmarks": [
            {"url": "https://one.example"},
            {"url": "https://two.example"},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bookmarks.json"
            source.write_text(json.dumps(data), encoding="utf-8")
            with mock.patch.object(bookmark_helper, "MAX_BOOKMARKS", 1):
                with self.assertRaisesRegex(ValueError, "more than 1"):
                    bookmark_helper.import_bookmarks(str(source), "missing-store.json")

    def test_rejects_oversized_bookmark_fields(self):
        with mock.patch.object(bookmark_helper, "MAX_TITLE_LENGTH", 4):
            self.assertIsNone(bookmark_helper.normalize_item({
                "url": "https://example.com",
                "title": "oversized",
            }))
        with mock.patch.object(bookmark_helper, "MAX_URL_LENGTH", 16):
            self.assertEqual(bookmark_helper.valid_url("https://example.com/long"), "")


class StoreLoadTests(unittest.TestCase):
    def test_returns_a_bounded_store_document(self):
        stored = {
            "version": 3,
            "bookmarks": [{"id": "one", "url": "https://example.com"}],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bookmarks.json"
            path.write_text(json.dumps(stored), encoding="utf-8")
            result = bookmark_helper.load_store(str(path))

        self.assertTrue(result["ok"])
        self.assertEqual(result["data"]["bookmarks"][0]["id"], "one")

    def test_rejects_store_bytes_and_count_before_qml(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bookmarks.json"
            path.write_text('{"bookmarks":[]}', encoding="utf-8")
            with mock.patch.object(bookmark_helper, "MAX_STORE_BYTES", 8):
                with self.assertRaisesRegex(ValueError, "too large"):
                    bookmark_helper.load_store(str(path))

            path.write_text(json.dumps({
                "bookmarks": [
                    {"id": "one", "url": "https://one.example"},
                    {"id": "two", "url": "https://two.example"},
                ]
            }), encoding="utf-8")
            with mock.patch.object(bookmark_helper, "MAX_BOOKMARKS", 1):
                with self.assertRaisesRegex(ValueError, "more than 1"):
                    bookmark_helper.load_store(str(path))

    def test_atomically_saves_a_bounded_store_from_stdin(self):
        document = json.dumps({
            "version": 3,
            "bookmarks": [{"id": "one", "url": "https://example.com"}],
        }) + "\n"
        stdin = mock.Mock(buffer=io.BytesIO(document.encode("utf-8")))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bookmarks.json"
            path.write_text('{"version":3,"bookmarks":[]}\n', encoding="utf-8")
            path.chmod(0o600)
            with mock.patch.object(bookmark_helper.sys, "stdin", stdin):
                result = bookmark_helper.save_store(str(path))

            self.assertTrue(result["ok"])
            self.assertEqual(path.read_text(encoding="utf-8"), document)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_oversized_stdin_does_not_replace_the_store(self):
        stdin = mock.Mock(buffer=io.BytesIO(b"0123456789"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bookmarks.json"
            path.write_text("original\n", encoding="utf-8")
            with mock.patch.object(bookmark_helper, "MAX_STORE_BYTES", 4), \
                    mock.patch.object(bookmark_helper.sys, "stdin", stdin):
                with self.assertRaisesRegex(ValueError, "too large"):
                    bookmark_helper.save_store(str(path))

            self.assertEqual(path.read_text(encoding="utf-8"), "original\n")


class ImageSecurityTests(unittest.TestCase):
    def test_rejects_unknown_and_oversized_images_before_imagemagick(self):
        with mock.patch("bookmark_helper.subprocess.run") as run:
            self.assertEqual(bookmark_helper.png_data_url(b"<svg></svg>"), "")
            self.assertEqual(
                bookmark_helper.png_data_url(
                    png_header(bookmark_helper.MAX_ICON_DIMENSION + 1, 1)
                ),
                "",
            )
        run.assert_not_called()

    @mock.patch("bookmark_helper.subprocess.run")
    def test_uses_an_explicit_coder_and_hard_decoder_limits(self, run):
        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout=png_header(64, 64)
        )

        result = bookmark_helper.png_data_url(png_header(32, 24))

        self.assertTrue(result.startswith("data:image/png;base64,"))
        command = run.call_args.args[0]
        self.assertIn("PNG:-[0]", command)
        self.assertNotIn("-", command)
        self.assertEqual(command[command.index("width") + 1], "4096")
        self.assertEqual(command[command.index("height") + 1], "4096")
        self.assertEqual(command[command.index("list-length") + 1], "16")

    def test_detects_allowlisted_raster_headers(self):
        self.assertEqual(bookmark_helper.image_input(png_header(12, 8)), ("PNG", 12, 8))
        gif = b"GIF89a" + (12).to_bytes(2, "little") + (8).to_bytes(2, "little")
        self.assertEqual(bookmark_helper.image_input(gif), ("GIF", 12, 8))


class BackupTests(unittest.TestCase):
    def test_creates_private_backups_and_keeps_only_the_newest(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / "bookmarks.json"
            created = []
            for index in range(6):
                store.write_text(str(index), encoding="utf-8")
                result = bookmark_helper.create_store_backup(str(store), keep=3)
                created.append(Path(result["backup"]))

            backups = sorted(Path(directory).glob("bookmarks.json.backup-*"))
            self.assertEqual(len(backups), 3)
            self.assertFalse(created[0].exists())
            self.assertEqual(result["pruned"], 1)
            for backup in backups:
                self.assertEqual(os.stat(backup).st_mode & 0o777, 0o600)


class MenuEntryTests(unittest.TestCase):
    def test_installs_idempotently_and_preserves_existing_jsonc(self):
        original = """{
  // Keep this user's comment and formatting.
  "personal": {"label":"Personal","action":"open-personal"}
}
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "omarchy-menu.jsonc"
            path.write_text(original, encoding="utf-8")
            path.chmod(0o640)

            first = bookmark_helper.manage_menu_entry(str(path), True)
            installed = path.read_text(encoding="utf-8")
            second = bookmark_helper.manage_menu_entry(str(path), True)

            parsed = json.loads(bookmark_helper._strip_omarchy_jsonc(installed))
            self.assertEqual(parsed["personal"]["label"], "Personal")
            self.assertEqual(
                parsed[bookmark_helper.MENU_ENTRY_ID]["action"],
                "omarchy-shell shell toggle stefanmara.bookmarks",
            )
            self.assertIn("Keep this user's comment and formatting", installed)
            self.assertTrue(first["changed"])
            self.assertFalse(second["changed"])
            self.assertEqual(path.read_text(encoding="utf-8"), installed)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

            removed = bookmark_helper.manage_menu_entry(str(path), False)
            self.assertTrue(removed["changed"])
            self.assertNotIn(bookmark_helper.MENU_MARKER_BEGIN, path.read_text())
            self.assertEqual(
                json.loads(bookmark_helper._strip_omarchy_jsonc(path.read_text())),
                {"personal": {"label": "Personal", "action": "open-personal"}},
            )

    def test_supports_items_wrapper_and_creates_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapped = root / "wrapped.jsonc"
            wrapped.write_text('{"version":1,"items":{}}\n', encoding="utf-8")

            bookmark_helper.manage_menu_entry(str(wrapped), True)
            parsed = json.loads(bookmark_helper._strip_omarchy_jsonc(wrapped.read_text()))
            self.assertIn(bookmark_helper.MENU_ENTRY_ID, parsed["items"])

            missing = root / "new" / "omarchy-menu.jsonc"
            bookmark_helper.manage_menu_entry(str(missing), True)
            created = json.loads(bookmark_helper._strip_omarchy_jsonc(missing.read_text()))
            self.assertIn(bookmark_helper.MENU_ENTRY_ID, created)
            self.assertEqual(missing.stat().st_mode & 0o777, 0o644)

    def test_refuses_to_modify_an_invalid_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "omarchy-menu.jsonc"
            path.write_text("{ definitely not valid }\n", encoding="utf-8")

            with self.assertRaises(json.JSONDecodeError):
                bookmark_helper.manage_menu_entry(str(path), True)

            self.assertEqual(path.read_text(), "{ definitely not valid }\n")

    def test_requires_an_explicit_choice_before_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            menu = root / "omarchy-menu.jsonc"
            settings = root / "data" / "settings.json"
            menu.write_text("{}\n", encoding="utf-8")

            status = bookmark_helper.menu_entry_operation(
                "status", str(menu), str(settings)
            )
            self.assertFalse(status["installed"])
            self.assertEqual(status["decision"], "pending")
            self.assertEqual(menu.read_text(), "{}\n")

            dismissed = bookmark_helper.menu_entry_operation(
                "dismiss", str(menu), str(settings)
            )
            self.assertFalse(dismissed["installed"])
            self.assertEqual(dismissed["decision"], "dismissed")
            self.assertNotIn(bookmark_helper.MENU_MARKER_BEGIN, menu.read_text())
            self.assertEqual(settings.stat().st_mode & 0o777, 0o600)

            installed = bookmark_helper.menu_entry_operation(
                "install", str(menu), str(settings)
            )
            self.assertTrue(installed["installed"])
            self.assertEqual(installed["decision"], "installed")
            self.assertTrue(bookmark_helper.menu_entry_present(str(menu)))

            removed = bookmark_helper.menu_entry_operation(
                "remove", str(menu), str(settings)
            )
            self.assertFalse(removed["installed"])
            self.assertEqual(removed["decision"], "dismissed")
            self.assertFalse(bookmark_helper.menu_entry_present(str(menu)))

    def test_rejects_an_incomplete_managed_menu_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            menu = Path(directory) / "omarchy-menu.jsonc"
            menu.write_text(
                "// " + bookmark_helper.MENU_MARKER_BEGIN + "\n{}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "incomplete"):
                bookmark_helper.menu_entry_present(str(menu))


class ClipboardCopyTests(unittest.TestCase):
    @mock.patch("bookmark_helper.subprocess.run")
    def test_copies_a_valid_url_without_a_shell(self, run):
        run.return_value = subprocess.CompletedProcess([], 0)

        result = bookmark_helper.copy_url_to_clipboard("https://example.com/path")

        self.assertTrue(result["ok"])
        run.assert_called_once()
        arguments, options = run.call_args
        self.assertEqual(
            arguments[0],
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
        )
        self.assertEqual(options["input"], b"https://example.com/path")
        self.assertIs(options["stderr"], subprocess.DEVNULL)

    @mock.patch("bookmark_helper.subprocess.run")
    def test_refuses_to_copy_a_non_http_url(self, run):
        result = bookmark_helper.copy_url_to_clipboard("file:///tmp/private")

        self.assertFalse(result["ok"])
        run.assert_not_called()


class BrowserDiscoveryTests(unittest.TestCase):
    def test_discovers_https_handlers_and_sorts_default_first(self):
        with tempfile.TemporaryDirectory() as directory:
            applications = Path(directory)
            (applications / "alpha.desktop").write_text(
                """[Desktop Entry]
Type=Application
Name=Alpha Browser
Exec=alpha %u
MimeType=text/html;x-scheme-handler/https;
""",
                encoding="utf-8",
            )
            (applications / "zeta.desktop").write_text(
                """[Desktop Entry]
Type=Application
Name=Zeta Browser
Exec=zeta %u
MimeType=x-scheme-handler/http;x-scheme-handler/https;
""",
                encoding="utf-8",
            )
            (applications / "hidden.desktop").write_text(
                """[Desktop Entry]
Type=Application
Name=Hidden Browser
NoDisplay=true
Exec=hidden %u
MimeType=x-scheme-handler/https;
""",
                encoding="utf-8",
            )

            result = bookmark_helper.discover_browsers(
                [applications], "zeta.desktop"
            )

        self.assertEqual(
            [item["id"] for item in result["browsers"]],
            ["zeta.desktop", "alpha.desktop"],
        )
        self.assertTrue(result["browsers"][0]["isDefault"])
        self.assertFalse(result["browsers"][1]["isDefault"])

    def test_skips_oversized_desktop_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oversized.desktop"
            path.write_text(
                "[Desktop Entry]\nName=Browser\nMimeType=x-scheme-handler/https;\n",
                encoding="utf-8",
            )
            with mock.patch.object(bookmark_helper, "MAX_DESKTOP_FILE_BYTES", 16):
                self.assertIsNone(bookmark_helper.desktop_browser(path))

    def test_caps_the_discovered_browser_count(self):
        with tempfile.TemporaryDirectory() as directory:
            applications = Path(directory)
            for name in ("one", "two"):
                (applications / f"{name}.desktop").write_text(
                    "[Desktop Entry]\n"
                    f"Name={name.title()} Browser\n"
                    "MimeType=x-scheme-handler/https;\n",
                    encoding="utf-8",
                )
            with mock.patch.object(bookmark_helper, "MAX_BROWSERS", 1):
                result = bookmark_helper.discover_browsers([applications], "")

        self.assertEqual(len(result["browsers"]), 1)

    def test_skips_oversized_browser_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "browser.desktop"
            path.write_text(
                "[Desktop Entry]\n"
                "Name=Oversized Browser Name\n"
                "MimeType=x-scheme-handler/https;\n",
                encoding="utf-8",
            )
            with mock.patch.object(bookmark_helper, "MAX_BROWSER_NAME_LENGTH", 4):
                self.assertIsNone(bookmark_helper.desktop_browser(path))


class QmlSecurityTests(unittest.TestCase):
    def test_untrusted_text_sinks_are_plain_text(self):
        checks = {
            "Bookmarks.qml": (
                "text: root.currentQuery() || root.modePlaceholder()",
                "? root.displayTitle(row.bookmark)",
                '"Search for “" + root.keywordAction.terms',
            ),
            "BookmarkImport.qml": (
                "text: modelData.title || modelData.url",
                "text: modelData.url",
            ),
            "BrowserPicker.qml": (
                "text: root.bookmarkTitle",
                "browserRow.modelData.name",
                "text: browserRow.modelData.id",
            ),
        }
        for filename, needles in checks.items():
            source = (PROJECT_ROOT / filename).read_text(encoding="utf-8")
            for needle in needles:
                with self.subTest(filename=filename, needle=needle):
                    position = source.index(needle)
                    self.assertIn(
                        "textFormat: Text.PlainText",
                        source[position:position + 1000],
                    )


if __name__ == "__main__":
    unittest.main()
