import json
import base64
from email.message import Message
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
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


class BoundedProcessTests(unittest.TestCase):
    def test_captures_only_within_the_declared_budget(self):
        result = bookmark_helper.run_bounded_process(
            [
                sys.executable,
                "-c",
                "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())",
            ],
            input_data=b"bounded",
            output_limit=7,
            timeout=2,
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"bounded")

    def test_terminates_a_child_as_soon_as_output_exceeds_the_budget(self):
        with self.assertRaises(bookmark_helper.BoundedOutputError):
            bookmark_helper.run_bounded_process(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.buffer.write(b'x' * 4097)",
                ],
                output_limit=4096,
                timeout=2,
            )

    def test_terminates_a_child_at_the_wall_clock_deadline(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            bookmark_helper.run_bounded_process(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                output_limit=16,
                timeout=0.05,
            )

    def test_timeout_terminates_the_child_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_path = Path(directory) / "descendant.pid"
            script = (
                "import pathlib, subprocess, sys, time; "
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import time; time.sleep(30)']); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                "time.sleep(30)"
            )
            with self.assertRaises(subprocess.TimeoutExpired):
                bookmark_helper.run_bounded_process(
                    [sys.executable, "-c", script, str(pid_path)],
                    output_limit=16,
                    timeout=0.2,
                )

            descendant_pid = int(pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                stat_path = Path(f"/proc/{descendant_pid}/stat")
                if not stat_path.exists():
                    break
                # A killed child can remain briefly as a zombie while init
                # reaps it; it is no longer executing in that state.
                if stat_path.read_text(encoding="utf-8").split()[2] in ("Z", "X"):
                    break
                time.sleep(0.01)
            else:
                self.fail("bounded process left a running descendant")


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


class SafeFetchTests(unittest.TestCase):
    def headers(self, **values):
        headers = Message()
        for name, value in values.items():
            headers[name.replace("_", "-")] = value
        return headers

    def test_accepts_only_globally_routable_addresses(self):
        self.assertTrue(bookmark_helper._globally_routable_address("93.184.216.34"))
        self.assertTrue(bookmark_helper._globally_routable_address("2606:4700:4700::1111"))
        for address in (
            "127.0.0.1",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.0.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "::1",
            "fe80::1",
            "fc00::1",
            "fec0::1",
            "::ffff:127.0.0.1",
            "::ffff:8.8.8.8",
            "2002:7f00:1::",
        ):
            with self.subTest(address=address):
                self.assertFalse(bookmark_helper._globally_routable_address(address))

    def test_old_python_runtime_fails_closed_for_network_access(self):
        with mock.patch.object(bookmark_helper.sys, "version_info", (3, 12, 9)):
            self.assertFalse(
                bookmark_helper._globally_routable_address("93.184.216.34")
            )

    @mock.patch("bookmark_helper.socket.getaddrinfo")
    def test_rejects_a_hostname_if_any_dns_answer_is_not_public(self, getaddrinfo):
        getaddrinfo.return_value = [
            (bookmark_helper.socket.AF_INET, bookmark_helper.socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),
            (bookmark_helper.socket.AF_INET, bookmark_helper.socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443)),
        ]

        with self.assertRaisesRegex(bookmark_helper.UnsafeNetworkTarget, "non-public"):
            bookmark_helper._resolve_public_addresses("example.com", 443)

    @mock.patch("bookmark_helper.socket.socket")
    def test_pinned_socket_connects_to_the_checked_literal_ip(self, socket_type):
        stream = socket_type.return_value
        stream.getpeername.return_value = ("93.184.216.34", 443)

        result = bookmark_helper._pinned_socket("93.184.216.34", 443, 4)

        self.assertIs(result, stream)
        socket_type.assert_called_once_with(
            bookmark_helper.socket.AF_INET,
            bookmark_helper.socket.SOCK_STREAM,
        )
        stream.connect.assert_called_once_with(("93.184.216.34", 443))

    @mock.patch("bookmark_helper._pinned_socket")
    @mock.patch("bookmark_helper.ssl.create_default_context")
    def test_tls_uses_the_original_hostname_for_verification(self, context_type, pinned):
        context = context_type.return_value
        wrapped = context.wrap_socket.return_value

        connection = bookmark_helper._PinnedHTTPSConnection(
            "example.com", 443, "93.184.216.34", 4
        )
        connection.connect()

        pinned.assert_called_once_with("93.184.216.34", 443, 4)
        context.wrap_socket.assert_called_once_with(
            pinned.return_value, server_hostname="example.com"
        )
        self.assertIs(connection.sock, wrapped)

    @mock.patch("bookmark_helper._PinnedHTTPSConnection")
    def test_requests_do_not_include_ambient_credentials(self, connection_type):
        response = connection_type.return_value.getresponse.return_value
        response.status = 200
        response.reason = "OK"
        response.headers = self.headers(Content_Length="4")
        response.read.return_value = b"page"

        bookmark_helper._request_from_address(
            "https", "example.com", 443, "/", "93.184.216.34",
            1024, "text/html", 4,
        )

        headers = connection_type.return_value.request.call_args.kwargs["headers"]
        self.assertEqual(headers["Accept-Encoding"], "identity")
        self.assertNotIn("Cookie", headers)
        self.assertNotIn("Authorization", headers)
        self.assertNotIn("Referer", headers)

    @mock.patch("bookmark_helper.socket.getaddrinfo")
    def test_caps_public_connection_candidates_after_validating_all(self, getaddrinfo):
        getaddrinfo.return_value = [
            (
                bookmark_helper.socket.AF_INET,
                bookmark_helper.socket.SOCK_STREAM,
                6,
                "",
                (f"1.1.1.{index}", 443),
            )
            for index in range(1, 9)
        ]

        addresses = bookmark_helper._resolve_public_addresses("example.com", 443)

        self.assertEqual(len(addresses), bookmark_helper.MAX_FETCH_ADDRESSES)

    def test_network_fetch_rejects_nondefault_ports(self):
        with self.assertRaisesRegex(bookmark_helper.UnsafeNetworkTarget, "default"):
            bookmark_helper.fetch_bytes(
                "https://example.com:8443/", 1024, "text/html"
            )

    def test_network_fetch_rejects_scoped_hostnames(self):
        with self.assertRaisesRegex(bookmark_helper.UnsafeNetworkTarget, "Scoped"):
            bookmark_helper.fetch_bytes(
                "http://[fe80::1%25eth0]/", 1024, "text/html"
            )

    @mock.patch("bookmark_helper._request_from_address")
    @mock.patch("bookmark_helper._resolve_public_addresses")
    def test_resolves_validates_and_pins_every_redirect(self, resolve, request):
        resolve.side_effect = [["93.184.216.34"], ["203.0.113.8"]]
        request.side_effect = [
            (302, "Found", self.headers(Location="https://cdn.example/final"), b""),
            (200, "OK", self.headers(Content_Type="text/html"), b"page"),
        ]

        raw, final_url, content_type = bookmark_helper.fetch_bytes(
            "https://example.com/start", 1024, "text/html"
        )

        self.assertEqual(raw, b"page")
        self.assertEqual(final_url, "https://cdn.example/final")
        self.assertEqual(content_type, "text/html")
        self.assertEqual(resolve.call_args_list, [
            mock.call("example.com", 443),
            mock.call("cdn.example", 443),
        ])
        self.assertEqual(request.call_args_list[0].args[4], "93.184.216.34")
        self.assertEqual(request.call_args_list[1].args[4], "203.0.113.8")

    @mock.patch("bookmark_helper._request_from_address")
    @mock.patch("bookmark_helper._resolve_public_addresses")
    def test_rejects_a_redirect_to_a_private_service(self, resolve, request):
        resolve.side_effect = [
            ["93.184.216.34"],
            bookmark_helper.UnsafeNetworkTarget("non-public"),
        ]
        request.return_value = (
            302,
            "Found",
            self.headers(Location="http://169.254.169.254/latest/meta-data/"),
            b"",
        )

        with self.assertRaises(bookmark_helper.UnsafeNetworkTarget):
            bookmark_helper.fetch_bytes(
                "http://example.com/start", 1024, "text/html"
            )

        request.assert_called_once()

    @mock.patch("bookmark_helper._request_from_address")
    @mock.patch("bookmark_helper._resolve_public_addresses")
    def test_rejects_an_https_downgrade_redirect(self, resolve, request):
        resolve.return_value = ["93.184.216.34"]
        request.return_value = (
            302,
            "Found",
            self.headers(Location="http://example.com/final"),
            b"",
        )

        with self.assertRaisesRegex(bookmark_helper.UnsafeNetworkTarget, "may not redirect"):
            bookmark_helper.fetch_bytes(
                "https://example.com/start", 1024, "text/html"
            )

    @mock.patch("bookmark_helper._request_from_address")
    @mock.patch("bookmark_helper._resolve_public_addresses")
    def test_can_lock_redirects_to_the_original_origin(self, resolve, request):
        resolve.return_value = ["93.184.216.34"]
        request.return_value = (
            302,
            "Found",
            self.headers(Location="https://cdn.example/icon.png"),
            b"",
        )

        with self.assertRaisesRegex(bookmark_helper.UnsafeNetworkTarget, "across origins"):
            bookmark_helper.fetch_bytes(
                "https://example.com/favicon.ico",
                1024,
                "image/*",
                redirect_origin="https://example.com/",
            )

    @mock.patch("bookmark_helper.png_data_url", return_value="data:image/png;base64,AAAA")
    @mock.patch("bookmark_helper.fetch_bytes")
    def test_web_enrichment_uses_only_same_origin_icon_references(self, fetch, _png):
        fetch.side_effect = [
            (
                b'<html><title>Example</title>'
                b'<link rel="icon" href="https://attacker.example/icon.png">'
                b'<link rel="icon" href="/safe.png"></html>',
                "https://example.com/article",
                "text/html",
            ),
            (b"png", "https://example.com/safe.png", "image/png"),
        ]
        result = bookmark_helper.enrich_url_from_web(
            "https://example.com/article"
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["title"], "Example")
        self.assertEqual(result["favicon"], "data:image/png;base64,AAAA")
        self.assertEqual(fetch.call_args_list[1].args[0], "https://example.com/safe.png")
        self.assertEqual(
            fetch.call_args_list[1].kwargs["redirect_origin"],
            "https://example.com/article",
        )
        self.assertNotIn("attacker.example", str(fetch.call_args_list))

    @mock.patch(
        "bookmark_helper._run_web_enrichment",
        return_value=("Example", "data:image/png;base64,AAAA"),
    )
    @mock.patch("bookmark_helper.run_bounded_process")
    def test_opted_in_clipboard_path_uses_worker_result(self, run, enrich):
        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout=b"https://example.com/article"
        )
        with tempfile.TemporaryDirectory() as directory:
            result = bookmark_helper.clipboard_bookmark(
                str(Path(directory) / "bookmarks.json"),
                enrich_from_web=True,
                settings_path=str(Path(directory) / "settings.json"),
            )

        enrich.assert_called_once_with(
            "https://example.com/article", mock.ANY
        )
        self.assertEqual(result["item"]["title"], "Example")
        self.assertEqual(result["item"]["favicon"], "data:image/png;base64,AAAA")

    @mock.patch("bookmark_helper.run_bounded_process")
    def test_web_enrichment_worker_has_a_hard_timeout(self, run):
        run.side_effect = subprocess.TimeoutExpired(["python"], 15)

        self.assertEqual(
            bookmark_helper._run_web_enrichment(
                "https://example.com", "/tmp/settings.json"
            ),
            ("", ""),
        )
        self.assertEqual(run.call_args.kwargs["timeout"], 15)

    @mock.patch("bookmark_helper.fetch_bytes")
    @mock.patch("bookmark_helper.run_bounded_process")
    def test_default_clipboard_path_never_uses_the_network(self, run, fetch):
        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout=b"http://127.0.0.1/admin"
        )
        with tempfile.TemporaryDirectory() as directory:
            result = bookmark_helper.clipboard_bookmark(
                str(Path(directory) / "bookmarks.json")
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["item"]["title"], "")
        self.assertEqual(result["item"]["favicon"], "")
        fetch.assert_not_called()

    @mock.patch("bookmark_helper._run_web_enrichment")
    @mock.patch(
        "bookmark_helper.run_bounded_process",
        side_effect=bookmark_helper.BoundedOutputError("too large"),
    )
    def test_clipboard_output_is_bounded_before_url_validation(self, run, enrich):
        result = bookmark_helper.clipboard_bookmark("/tmp/missing-store.json")

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "Clipboard text is too large")
        self.assertEqual(
            run.call_args.kwargs["output_limit"],
            bookmark_helper.MAX_CLIPBOARD_BYTES,
        )
        enrich.assert_not_called()


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

    @mock.patch("bookmark_helper.run_bounded_process")
    def test_rerasterizes_favicons_from_external_json(self, run):
        incoming = png_header(32, 32)
        rendered = png_header(16, 16)
        run.return_value = subprocess.CompletedProcess([], 0, stdout=rendered)
        data = {
            "bookmarks": [{
                "url": "https://example.com",
                "favicon": "data:image/png;base64,"
                + base64.b64encode(incoming).decode("ascii"),
            }]
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bookmarks.json"
            source.write_text(json.dumps(data), encoding="utf-8")
            result = bookmark_helper.import_bookmarks(
                str(source), str(Path(directory) / "store.json")
            )

        self.assertEqual(
            result["items"][0]["favicon"],
            "data:image/png;base64," + base64.b64encode(rendered).decode("ascii"),
        )
        run.assert_called_once()

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

    def test_rejects_fifo_store_without_blocking(self):
        document = b'{"version":3,"bookmarks":[]}\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bookmarks.json"
            os.mkfifo(path)
            process = subprocess.run(
                [
                    sys.executable,
                    str(PROJECT_ROOT / "bookmark_helper.py"),
                    "store-load",
                    str(path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2,
                check=False,
            )

            stdin = mock.Mock(buffer=io.BytesIO(document))
            with mock.patch.object(bookmark_helper.sys, "stdin", stdin):
                with self.assertRaisesRegex(ValueError, "regular file"):
                    bookmark_helper.save_store(str(path))
            with self.assertRaisesRegex(ValueError, "regular file"):
                bookmark_helper.create_store_backup(str(path))

        result = json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(result["ok"])
        self.assertIn("regular file", result["error"])

    def test_rejects_symlink_store_for_reads_writes_and_backups(self):
        document = '{"version":3,"bookmarks":[]}\n'
        stdin = mock.Mock(buffer=io.BytesIO(document.encode("utf-8")))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.json"
            target.write_text(document, encoding="utf-8")
            path = Path(directory) / "bookmarks.json"
            path.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "regular file"):
                bookmark_helper.load_store(str(path))
            with mock.patch.object(bookmark_helper.sys, "stdin", stdin):
                with self.assertRaisesRegex(ValueError, "regular file"):
                    bookmark_helper.save_store(str(path))
            with self.assertRaisesRegex(ValueError, "regular file"):
                bookmark_helper.create_store_backup(str(path))

            self.assertEqual(target.read_text(encoding="utf-8"), document)

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
        with mock.patch("bookmark_helper.run_bounded_process") as run:
            self.assertEqual(bookmark_helper.png_data_url(b"<svg></svg>"), "")
            self.assertEqual(
                bookmark_helper.png_data_url(
                    png_header(bookmark_helper.MAX_ICON_DIMENSION + 1, 1)
                ),
                "",
            )
        run.assert_not_called()

    def test_rejects_oversized_embedded_icon_before_regex_or_decoder_work(self):
        value = "data:image/png;base64," + (
            "A" * (bookmark_helper.MAX_ICON_INPUT * 2)
        )
        with mock.patch("bookmark_helper.re.fullmatch") as fullmatch, \
                mock.patch("bookmark_helper.run_bounded_process") as run:
            self.assertEqual(bookmark_helper.embedded_icon(value), "")

        fullmatch.assert_not_called()
        run.assert_not_called()

    @mock.patch("bookmark_helper.run_bounded_process")
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
            self.assertEqual(
                Path(result["backup"]).read_text(encoding="utf-8"),
                "5",
            )
            for backup in backups:
                self.assertEqual(os.stat(backup).st_mode & 0o777, 0o600)


class MenuEntryTests(unittest.TestCase):
    def test_network_enrichment_defaults_off_and_preserves_menu_choice(self):
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "settings.json"

            initial = bookmark_helper.network_enrichment_operation(
                "status", str(settings_path)
            )
            enabled = bookmark_helper.network_enrichment_operation(
                "enable", str(settings_path)
            )
            bookmark_helper.write_menu_preference(str(settings_path), "installed")
            stored = bookmark_helper.read_settings(str(settings_path))
            disabled = bookmark_helper.network_enrichment_operation(
                "disable", str(settings_path)
            )

        self.assertFalse(initial["enabled"])
        self.assertTrue(enabled["enabled"])
        self.assertEqual(stored["menuEntry"], "installed")
        self.assertTrue(stored["networkEnrichment"])
        self.assertFalse(disabled["enabled"])

    def test_rejects_a_non_boolean_network_preference(self):
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "settings.json"
            settings_path.write_text(
                '{"version":1,"menuEntry":"pending","networkEnrichment":"yes"}',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "invalid network"):
                bookmark_helper.read_settings(str(settings_path))

    def test_rejects_fifo_settings_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "settings.json"
            os.mkfifo(settings_path)
            process = subprocess.run(
                [
                    sys.executable,
                    str(PROJECT_ROOT / "bookmark_helper.py"),
                    "network-enrichment",
                    "status",
                    str(settings_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2,
                check=False,
            )

        result = json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(result["ok"])
        self.assertIn("regular file", result["error"])

    def test_rejects_oversized_settings_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "settings.json"
            settings_path.write_text("{}" * 20, encoding="utf-8")

            with mock.patch.object(bookmark_helper, "MAX_SETTINGS_BYTES", 16):
                with self.assertRaisesRegex(ValueError, "too large"):
                    bookmark_helper.read_settings(str(settings_path))

    def test_rejects_oversized_shared_menu_before_status_or_modification(self):
        with tempfile.TemporaryDirectory() as directory:
            menu = Path(directory) / "omarchy-menu.jsonc"
            settings = Path(directory) / "settings.json"
            original = "{" + (" " * 32) + "}\n"
            menu.write_text(original, encoding="utf-8")

            with mock.patch.object(bookmark_helper, "MAX_MENU_EXTENSION_BYTES", 16):
                with self.assertRaisesRegex(ValueError, "menu extension is too large"):
                    bookmark_helper.menu_entry_operation(
                        "status", str(menu), str(settings)
                    )
                with self.assertRaisesRegex(ValueError, "menu extension is too large"):
                    bookmark_helper.manage_menu_entry(str(menu), False)

            self.assertEqual(menu.read_text(encoding="utf-8"), original)

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

    def test_refuses_to_create_an_oversized_shared_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            menu = Path(directory) / "omarchy-menu.jsonc"
            menu.write_text("{}\n", encoding="utf-8")

            with mock.patch.object(bookmark_helper, "MAX_MENU_EXTENSION_BYTES", 64):
                with self.assertRaisesRegex(ValueError, "menu extension is too large"):
                    bookmark_helper.manage_menu_entry(str(menu), True)

            self.assertEqual(menu.read_text(encoding="utf-8"), "{}\n")

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
            with self.assertRaisesRegex(ValueError, "incomplete"):
                bookmark_helper.manage_menu_entry(str(menu), False)


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


class CliSecurityTests(unittest.TestCase):
    @mock.patch("builtins.print")
    @mock.patch("bookmark_helper.enrich_url_from_web")
    @mock.patch(
        "bookmark_helper.read_settings",
        return_value={"networkEnrichment": False},
    )
    def test_internal_worker_refuses_network_when_setting_is_off(
        self, _read_settings, enrich, _print
    ):
        with mock.patch.object(
            bookmark_helper.sys,
            "argv",
            ["bookmark_helper.py", "enrich-url", "/tmp/settings.json"],
        ):
            self.assertEqual(bookmark_helper.main(), 1)

        enrich.assert_not_called()

    @mock.patch("builtins.print")
    @mock.patch("bookmark_helper.clipboard_bookmark")
    @mock.patch("bookmark_helper.read_settings")
    def test_enrichment_command_rechecks_persisted_opt_in(
        self, read_settings, clipboard_bookmark, _print
    ):
        clipboard_bookmark.return_value = {"ok": True}
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                read_settings.return_value = {"networkEnrichment": enabled}
                with mock.patch.object(
                    bookmark_helper.sys,
                    "argv",
                    [
                        "bookmark_helper.py",
                        "clipboard-enrich",
                        "/tmp/store.json",
                        "/tmp/settings.json",
                    ],
                ):
                    self.assertEqual(bookmark_helper.main(), 0)
                self.assertEqual(
                    clipboard_bookmark.call_args,
                    mock.call(
                        "/tmp/store.json",
                        enrich_from_web=enabled,
                        settings_path="/tmp/settings.json",
                    ),
                )


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
    def test_paste_defaults_to_local_helper_and_opens_editor_before_saving(self):
        source = (PROJECT_ROOT / "Bookmarks.qml").read_text(encoding="utf-8")

        self.assertIn(
            'root.networkEnrichmentEnabled ? "clipboard-enrich" : "clipboard"',
            source,
        )
        self.assertIn("clipboardCommand.push(root.menuPreferencePath)", source)
        self.assertIn("editor.openForClipboard(result.item)", source)
        quick_add_handler = source[
            source.index("id: quickAddProcess"):source.index("id: copyProcess")
        ]
        self.assertNotIn("store.addBookmark", quick_add_handler)

    def test_network_warning_is_plain_text_and_explains_the_risk(self):
        source = (PROJECT_ROOT / "NetworkEnrichmentDialog.qml").read_text(
            encoding="utf-8"
        )

        self.assertIn("This is off by default", source)
        self.assertIn("reveals your IP address", source)
        self.assertIn("up to three public redirect destinations", source)
        self.assertIn("fetching untrusted content is never risk-free", source)
        self.assertIn("Enable anyway", source)
        self.assertGreaterEqual(source.count("textFormat: Text.PlainText"), 3)

    def test_shared_delete_confirmation_never_receives_untrusted_text(self):
        source = (PROJECT_ROOT / "Bookmarks.qml").read_text(encoding="utf-8")
        confirm = source[
            source.index("ConfirmDialog {"):source.index("MenuEntryDialog {")
        ]

        self.assertIn('message: "Delete the selected bookmark?"', confirm)
        self.assertNotIn("deleteTarget", confirm)
        self.assertNotIn("displayTitle", confirm)

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


class QmlResidentLifecycleTests(unittest.TestCase):
    def test_hidden_menu_releases_derived_models_and_favicon_cache(self):
        source = (PROJECT_ROOT / "Bookmarks.qml").read_text(encoding="utf-8")

        for expression in (
            "root.opened && root.viewMode === 0",
            "? root.resolveKeywordAction(root.query)",
            "? root.bookmarksForQuery(root.query)",
            "root.opened && root.viewMode === 1 ? root.collectTags() : []",
            "root.opened && root.viewMode === 2 ? root.collectKeywords() : []",
            "!root.opened\n      ? []",
        ):
            self.assertIn(expression, source)
        favicon = source[source.index("id: faviconImage"):]
        self.assertIn("cache: false", favicon[:1000])

    def test_large_helper_responses_are_not_retained_by_collectors(self):
        checks = {
            "Bookmarks.qml": ("id: quickAddProcess", "id: copyProcess"),
            "BookmarkStore.qml": ("id: storeLoadProcess", "id: storeSaveProcess"),
            "BookmarkImport.qml": ("id: importProcess", "Rectangle {"),
            "BrowserPicker.qml": ("id: browserProcess", "Rectangle {"),
        }
        for filename, (start, end) in checks.items():
            source = (PROJECT_ROOT / filename).read_text(encoding="utf-8")
            process = source[source.index(start):source.index(end, source.index(start))]
            with self.subTest(filename=filename):
                self.assertIn("SplitParser", process)
                self.assertNotIn("StdioCollector", process)

        for path in PROJECT_ROOT.glob("*.qml"):
            with self.subTest(filename=path.name, parser="all"):
                self.assertNotIn(
                    "StdioCollector",
                    path.read_text(encoding="utf-8"),
                )

    def test_transient_dialog_payloads_are_cleared_on_close(self):
        checks = {
            "BookmarkEditor.qml": (
                'root.bookmarkId = ""',
                'titleField.text = ""',
                'urlField.text = ""',
                'tagsField.text = ""',
                'keywordField.text = ""',
            ),
            "BookmarkImport.qml": (
                'root.sourcePath = ""',
                "root.result = null",
            ),
            "BrowserPicker.qml": (
                'root.bookmarkTitle = ""',
                "root.browsers = []",
            ),
        }
        for filename, needles in checks.items():
            source = (PROJECT_ROOT / filename).read_text(encoding="utf-8")
            close = source[source.index("function close()") : source.index("function ", source.index("function close()") + 1)]
            for needle in needles:
                with self.subTest(filename=filename, needle=needle):
                    self.assertIn(needle, close)

    def test_store_file_events_are_debounced_and_loads_are_coalesced(self):
        source = (PROJECT_ROOT / "BookmarkStore.qml").read_text(encoding="utf-8")
        reload_function = source[
            source.index("function reload()") : source.index("function save(")
        ]
        watcher = source[source.index("FileView {") :]

        self.assertIn("if (storeLoadProcess.running)", reload_function)
        self.assertIn("root.reloadPending = true", reload_function)
        self.assertNotIn("storeLoadProcess.running = false", reload_function)
        self.assertIn("root.requestReload()", watcher)
        self.assertIn("id: reloadDebounce", source)
        self.assertIn("id: storeLoadDeadline", source)
        self.assertIn("storeLoadProcess.signal(9)", source)

    def test_failed_process_starts_release_busy_state(self):
        checks = {
            "Bookmarks.qml": (
                "root.quickAdding",
                "root.copyTargetTitle",
                "root.menuStatusPending",
                "root.menuEntryOperation",
                "root.networkSettingOperation",
                "root.fileDialogOpen",
            ),
            "BookmarkStore.qml": (
                "root.initializePending",
                "root.storeLoadAttemptActive",
                "root.storeSaveAttemptActive",
                "root.backupAttemptActive",
            ),
            "BookmarkImport.qml": ("root.loading",),
            "BrowserPicker.qml": ("root.loading",),
        }
        for filename, guards in checks.items():
            source = (PROJECT_ROOT / filename).read_text(encoding="utf-8")
            with self.subTest(filename=filename):
                self.assertIn("onRunningChanged", source)
                for guard in guards:
                    self.assertIn(guard, source)


if __name__ == "__main__":
    unittest.main()
