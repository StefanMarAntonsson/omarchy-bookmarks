import json
import base64
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
        raw = b"\x89PNG\r\n\x1a\n" + b"test-payload"
        encoded = base64.b64encode(raw).decode("ascii")
        item = bookmark_helper.normalize_item({
            "url": "https://example.com",
            "favicon": "data:image/png;base64," + encoded,
        })

        self.assertIsNotNone(item)
        self.assertEqual(item["favicon"], "data:image/png;base64," + encoded)


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


if __name__ == "__main__":
    unittest.main()
