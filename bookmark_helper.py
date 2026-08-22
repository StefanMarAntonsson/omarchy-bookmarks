#!/usr/bin/env python3
"""Small, dependency-free helper for bookmark import and clipboard metadata."""

from __future__ import annotations

import base64
import configparser
from datetime import datetime
import errno
import html
from html.parser import HTMLParser
from http.client import HTTPConnection, HTTPSConnection, HTTPException
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any
from urllib.parse import quote, unquote, urljoin, urlsplit, urlunsplit


MAX_HTML = 1_000_000
MAX_ICON_INPUT = 256_000
MAX_ICON_OUTPUT = 96_000
MAX_ICON_DIMENSION = 4096
MAX_ICON_PIXELS = 4096 * 4096
MAX_ICON_FRAMES = 16
MAX_STORE_BYTES = 64 * 1024 * 1024
MAX_IMPORT_BYTES = 50_000_000
MAX_BOOKMARKS = 50_000
MAX_IMPORT_ICONS = 512
MAX_TITLE_LENGTH = 2048
MAX_URL_LENGTH = 8192
MAX_ID_LENGTH = 256
MAX_TAGS = 64
MAX_TAG_LENGTH = 128
MAX_KEYWORD_LENGTH = 128
MAX_DESKTOP_FILE_BYTES = 256 * 1024
MAX_APPLICATION_ENTRIES = 10_000
MAX_BROWSERS = 256
MAX_BROWSER_NAME_LENGTH = 512
MAX_BROWSER_ICON_LENGTH = 1024
MAX_PATH_LENGTH = 4096
MAX_SETTINGS_BYTES = 16 * 1024
MAX_MENU_EXTENSION_BYTES = 1024 * 1024
MAX_CLIPBOARD_BYTES = MAX_URL_LENGTH * 4
MAX_PLUGIN_LIST_OUTPUT = 1024 * 1024
MAX_DEFAULT_BROWSER_OUTPUT = 16 * 1024
MAX_ICON_CANDIDATES = 8
MAX_FETCH_REDIRECTS = 3
MAX_FETCH_ADDRESSES = 4
MAX_ENRICHMENT_SECONDS = 15
MAX_ENRICHMENT_OUTPUT = 256 * 1024
BACKUP_LIMIT = 10
USER_AGENT = "Omarchy Bookmarks/1.0"
MENU_ENTRY_ID = "stefanmara-bookmarks"
MENU_MARKER_BEGIN = "BEGIN stefanmara.bookmarks managed menu entry"
MENU_MARKER_END = "END stefanmara.bookmarks managed menu entry"
SETTINGS_VERSION = 1


class BoundedOutputError(ValueError):
    """A child process exceeded its declared output budget."""


def run_bounded_process(
    command: list[str],
    *,
    output_limit: int,
    timeout: float,
    input_data: bytes | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    """Capture stdout without allowing a child to fill unbounded memory."""
    if output_limit < 0 or timeout <= 0:
        raise ValueError("Process limits must be positive")

    input_stream = None
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    output = bytearray()
    try:
        if input_data is not None:
            input_stream = tempfile.TemporaryFile()
            input_stream.write(input_data)
            input_stream.seek(0)

        deadline = time.monotonic() + timeout
        process = subprocess.Popen(
            command,
            stdin=input_stream if input_stream is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
        if process.stdout is None:
            raise OSError("Could not capture process output")
        selector.register(process.stdout, selectors.EVENT_READ)

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(command, timeout)
            chunk = os.read(
                process.stdout.fileno(),
                min(64 * 1024, output_limit + 1 - len(output)),
            )
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > output_limit:
                raise BoundedOutputError("Process output is too large")

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout)
        return_code = process.wait(timeout=remaining)
        return subprocess.CompletedProcess(command, return_code, bytes(output), None)
    finally:
        selector.close()
        if process is not None:
            if process.stdout is not None:
                process.stdout.close()
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        if input_stream is not None:
            input_stream.close()


def read_limited_bytes(
    path: Path,
    limit: int,
    description: str,
    *,
    follow_symlinks: bool = True,
) -> bytes:
    """Read one descriptor-validated regular file without blocking on special files."""
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
    if not follow_symlinks:
        if not hasattr(os, "O_NOFOLLOW"):
            raise OSError("This platform cannot safely open fixed bookmark paths")
        flags |= os.O_NOFOLLOW

    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        if not follow_symlinks and error.errno == errno.ELOOP:
            raise ValueError(f"{description} path is not a regular file") from error
        raise

    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"{description} path is not a regular file")
        if info.st_size > limit:
            raise ValueError(f"{description} is too large")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            raw = stream.read(limit + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    if len(raw) > limit:
        raise ValueError(f"{description} is too large")
    return raw


def read_limited_text(
    path: Path,
    limit: int,
    description: str,
    *,
    follow_symlinks: bool = True,
) -> str:
    """Read one bounded regular file as UTF-8 text."""
    raw = read_limited_bytes(
        path,
        limit,
        description,
        follow_symlinks=follow_symlinks,
    )
    return raw.decode("utf-8", errors="replace")


def existing_regular_mode(path: Path, description: str, default: int) -> int:
    """Return a fixed path's mode without following symlinks or special files."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return default
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{description} path is not a regular file")
    return stat.S_IMODE(info.st_mode)


def _strip_omarchy_jsonc(value: str) -> str:
    """Strip the supported JSONC subset with bounded linear scans."""
    uncommented: list[str] = []
    for line in value.splitlines(keepends=True):
        if line.lstrip(" \t").startswith("//"):
            if line.endswith("\r\n"):
                uncommented.append("\r\n")
            elif line.endswith("\n") or line.endswith("\r"):
                uncommented.append(line[-1])
            continue
        uncommented.append(line)

    source = "".join(uncommented)
    output: list[str] = []
    index = 0
    inside_string = False
    escaped = False
    while index < len(source):
        character = source[index]
        if inside_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                inside_string = False
            index += 1
            continue
        if character == '"':
            inside_string = True
            output.append(character)
            index += 1
            continue
        if character == ",":
            lookahead = index + 1
            while lookahead < len(source) and source[lookahead].isspace():
                lookahead += 1
            if lookahead < len(source) and source[lookahead] in "}]":
                index += 1
                continue
        output.append(character)
        index += 1
    return "".join(output)


def _jsonc_tokens(value: str) -> list[dict[str, Any]]:
    """Return enough JSONC tokens to locate an object without reformatting it."""
    tokens: list[dict[str, Any]] = []
    index = 0
    depth = 0
    while index < len(value):
        character = value[index]
        if character.isspace():
            index += 1
            continue
        if value.startswith("//", index):
            newline = value.find("\n", index + 2)
            index = len(value) if newline < 0 else newline + 1
            continue
        if value.startswith("/*", index):
            closing = value.find("*/", index + 2)
            if closing < 0:
                raise ValueError("Unterminated comment in Omarchy menu extension")
            index = closing + 2
            continue
        if character == '"':
            start = index
            index += 1
            while index < len(value):
                if value[index] == "\\":
                    index += 2
                    continue
                if value[index] == '"':
                    index += 1
                    break
                index += 1
            else:
                raise ValueError("Unterminated string in Omarchy menu extension")
            try:
                decoded = json.loads(value[start:index])
            except json.JSONDecodeError as error:
                raise ValueError("Invalid string in Omarchy menu extension") from error
            tokens.append({
                "kind": "string", "value": decoded,
                "start": start, "end": index, "depth": depth,
            })
            continue
        if character in "{[":
            tokens.append({
                "kind": character, "value": character,
                "start": index, "end": index + 1, "depth": depth,
            })
            depth += 1
            index += 1
            continue
        if character in "}]":
            depth -= 1
            if depth < 0:
                raise ValueError("Unbalanced Omarchy menu extension")
            tokens.append({
                "kind": character, "value": character,
                "start": index, "end": index + 1, "depth": depth,
            })
            index += 1
            continue
        if character in ":,":
            tokens.append({
                "kind": character, "value": character,
                "start": index, "end": index + 1, "depth": depth,
            })
            index += 1
            continue

        start = index
        while index < len(value) and not value[index].isspace() and value[index] not in "{}[],:\"":
            index += 1
        tokens.append({
            "kind": "literal", "value": value[start:index],
            "start": start, "end": index, "depth": depth,
        })
    if depth != 0:
        raise ValueError("Unbalanced Omarchy menu extension")
    return tokens


def _menu_object_bounds(value: str) -> tuple[int, int, str, str]:
    """Locate the root menu object, including the optional `items` wrapper."""
    parsed = json.loads(_strip_omarchy_jsonc(value))
    if not isinstance(parsed, dict):
        raise ValueError("Omarchy menu extension must contain an object")

    tokens = _jsonc_tokens(value)
    root_open = next(
        (index for index, token in enumerate(tokens)
         if token["kind"] == "{" and token["depth"] == 0),
        None,
    )
    if root_open is None:
        raise ValueError("Omarchy menu extension must contain an object")

    open_index = root_open
    if isinstance(parsed.get("items"), dict):
        for index in range(root_open + 1, len(tokens) - 2):
            token = tokens[index]
            if (
                token["kind"] == "string"
                and token["depth"] == 1
                and token["value"] == "items"
                and tokens[index + 1]["kind"] == ":"
                and tokens[index + 2]["kind"] == "{"
            ):
                open_index = index + 2
                break
        else:
            raise ValueError("Could not locate items in Omarchy menu extension")

    opening = tokens[open_index]
    target_depth = opening["depth"]
    close_index = next(
        (index for index in range(open_index + 1, len(tokens))
         if tokens[index]["kind"] == "}" and tokens[index]["depth"] == target_depth),
        None,
    )
    if close_index is None:
        raise ValueError("Unbalanced Omarchy menu extension")

    closing = tokens[close_index]
    previous = tokens[close_index - 1]
    line_start = value.rfind("\n", 0, closing["start"]) + 1
    closing_prefix = value[line_start:closing["start"]]
    if closing_prefix.strip():
        insertion = closing["start"]
        base_indent = ""
    else:
        insertion = line_start
        base_indent = closing_prefix
    entry_indent = base_indent + "  "
    needs_comma = previous["kind"] not in ("{", ",")
    return insertion, closing["start"], entry_indent, "," if needs_comma else ""


def _remove_managed_menu_entry(value: str) -> tuple[str, bool]:
    """Remove complete managed blocks in one pass without backtracking."""
    begin = "// " + MENU_MARKER_BEGIN
    end = "// " + MENU_MARKER_END
    output: list[str] = []
    inside = False
    removed = False
    for line in value.splitlines(keepends=True):
        marker = line.rstrip("\r\n").lstrip(" \t")
        if marker == begin:
            if inside:
                raise ValueError("Omarchy menu extension has nested Bookmarks entries")
            inside = True
            continue
        if marker == end:
            if not inside:
                raise ValueError("Omarchy menu extension has an incomplete Bookmarks entry")
            inside = False
            removed = True
            continue
        if not inside:
            output.append(line)
    if inside:
        raise ValueError("Omarchy menu extension has an incomplete Bookmarks entry")
    return "".join(output), removed


def _atomic_write_text(path: Path, value: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".tmp-", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_write_bytes(path: Path, value: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".tmp-", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def manage_menu_entry(menu_path: str, install: bool) -> dict[str, Any]:
    """Add or remove only this plugin's marked block in the user menu JSONC."""
    requested = Path(menu_path).expanduser()
    path = requested.resolve(strict=False) if requested.is_symlink() else requested
    if path.exists() and not path.is_file():
        raise ValueError("Omarchy menu extension path is not a regular file")

    original = (
        read_limited_text(path, MAX_MENU_EXTENSION_BYTES, "Omarchy menu extension")
        if path.exists()
        else "{}\n"
    )
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    without_entry, removed = _remove_managed_menu_entry(original)

    if not install:
        if removed:
            json.loads(_strip_omarchy_jsonc(without_entry))
            _atomic_write_text(path, without_entry, mode)
        return {"ok": True, "changed": removed, "installed": False, "path": str(requested)}

    insertion, _, indent, comma = _menu_object_bounds(without_entry)
    entry = {
        "icon": "",
        "label": "Bookmarks",
        "action": "omarchy-shell shell toggle stefanmara.bookmarks",
        "when": (
            "omarchy plugin list --json 2>/dev/null | "
            "jq -e 'any(.[]; .id == \"stefanmara.bookmarks\" and .enabled == true)' "
            ">/dev/null"
        ),
    }
    serialized = json.dumps(entry, ensure_ascii=False, indent=2)
    serialized_lines = serialized.splitlines()
    property_lines = [
        indent + json.dumps(MENU_ENTRY_ID) + ": " + serialized_lines[0]
    ]
    property_lines.extend(indent + line for line in serialized_lines[1:])
    block_lines = [indent + "// " + MENU_MARKER_BEGIN]
    if comma:
        block_lines.append(indent + comma)
    block_lines.extend(property_lines)
    block_lines.append(indent + "// " + MENU_MARKER_END)
    block = "\n".join(block_lines) + "\n"

    prefix = without_entry[:insertion]
    if prefix and not prefix.endswith("\n"):
        block = "\n" + block
    updated = prefix + block + without_entry[insertion:]
    if len(updated.encode("utf-8")) > MAX_MENU_EXTENSION_BYTES:
        raise ValueError("Omarchy menu extension is too large")
    json.loads(_strip_omarchy_jsonc(updated))
    changed = updated != original
    if changed:
        _atomic_write_text(path, updated, mode)
    return {"ok": True, "changed": changed, "installed": True, "path": str(requested)}


def menu_entry_present(menu_path: str) -> bool:
    """Report whether this plugin's complete managed block is present."""
    path = Path(menu_path).expanduser()
    if not path.exists():
        return False
    if not path.is_file():
        raise ValueError("Omarchy menu extension path is not a regular file")
    value = read_limited_text(path, MAX_MENU_EXTENSION_BYTES, "Omarchy menu extension")
    has_begin = MENU_MARKER_BEGIN in value
    has_end = MENU_MARKER_END in value
    if has_begin != has_end:
        raise ValueError("Omarchy menu extension has an incomplete Bookmarks entry")
    return has_begin


def read_settings(settings_path: str) -> dict[str, Any]:
    """Read plugin-owned settings with network access defaulting to disabled."""
    path = Path(settings_path).expanduser()
    try:
        raw = read_limited_text(
            path,
            MAX_SETTINGS_BYTES,
            "Bookmarks settings",
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return {
            "version": SETTINGS_VERSION,
            "menuEntry": "pending",
            "networkEnrichment": False,
        }
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("version") != SETTINGS_VERSION:
        raise ValueError("Bookmarks settings use an unsupported format")
    decision = data.get("menuEntry", "pending")
    if decision not in ("pending", "installed", "dismissed"):
        raise ValueError("Bookmarks settings contain an invalid menu-entry choice")
    network_enrichment = data.get("networkEnrichment", False)
    if not isinstance(network_enrichment, bool):
        raise ValueError("Bookmarks settings contain an invalid network choice")
    return {
        "version": SETTINGS_VERSION,
        "menuEntry": str(decision),
        "networkEnrichment": network_enrichment,
    }


def write_settings(settings_path: str, settings: dict[str, Any]) -> None:
    """Atomically persist validated settings without touching shared config."""
    decision = settings.get("menuEntry", "pending")
    network_enrichment = settings.get("networkEnrichment", False)
    if decision not in ("pending", "installed", "dismissed"):
        raise ValueError("Invalid menu-entry choice")
    if not isinstance(network_enrichment, bool):
        raise ValueError("Invalid network choice")
    path = Path(settings_path).expanduser()
    if not path.parent.exists():
        path.parent.mkdir(parents=True, mode=0o700)
    mode = existing_regular_mode(path, "Bookmarks settings", 0o600)
    value = json.dumps(
        {
            "version": SETTINGS_VERSION,
            "menuEntry": decision,
            "networkEnrichment": network_enrichment,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    ) + "\n"
    _atomic_write_text(path, value, mode)


def read_menu_preference(preference_path: str) -> str:
    """Read the user's menu-entry choice from plugin-owned data."""
    return str(read_settings(preference_path)["menuEntry"])


def write_menu_preference(preference_path: str, decision: str) -> None:
    """Update only the menu-entry choice while preserving safer defaults."""
    settings = read_settings(preference_path)
    settings["menuEntry"] = decision
    write_settings(preference_path, settings)


def network_enrichment_operation(operation: str, settings_path: str) -> dict[str, Any]:
    """Inspect or explicitly update the opt-in network enrichment setting."""
    settings = read_settings(settings_path)
    if operation == "status":
        return {"ok": True, "enabled": settings["networkEnrichment"]}
    if operation not in ("enable", "disable"):
        raise ValueError("network enrichment operation must be status, enable, or disable")
    settings["networkEnrichment"] = operation == "enable"
    write_settings(settings_path, settings)
    return {"ok": True, "enabled": settings["networkEnrichment"]}


def menu_entry_operation(
    operation: str,
    menu_path: str,
    preference_path: str,
) -> dict[str, Any]:
    """Inspect or apply an explicit user choice for main-menu integration."""
    if operation == "status":
        settings = read_settings(preference_path)
        return {
            "ok": True,
            "installed": menu_entry_present(menu_path),
            "decision": settings["menuEntry"],
            "networkEnrichment": settings["networkEnrichment"],
            "path": str(Path(menu_path).expanduser()),
        }
    if operation == "install":
        result = manage_menu_entry(menu_path, True)
        write_menu_preference(preference_path, "installed")
        result["decision"] = "installed"
        return result
    if operation == "remove":
        result = manage_menu_entry(menu_path, False)
        write_menu_preference(preference_path, "dismissed")
        result["decision"] = "dismissed"
        return result
    if operation == "dismiss":
        write_menu_preference(preference_path, "dismissed")
        return {
            "ok": True,
            "changed": True,
            "installed": menu_entry_present(menu_path),
            "decision": "dismissed",
            "path": str(Path(menu_path).expanduser()),
        }
    raise ValueError("menu-entry operation must be status, install, remove, or dismiss")


def plugin_enabled_state(plugin_id: str) -> bool | None:
    """Return None when the shell cannot answer, so shutdown never removes config."""
    try:
        process = run_bounded_process(
            ["omarchy", "plugin", "list", "--json"],
            output_limit=MAX_PLUGIN_LIST_OUTPUT,
            timeout=5,
        )
        if process.returncode != 0:
            return None
        plugins = json.loads(process.stdout.decode("utf-8"))
    except (
        OSError,
        UnicodeDecodeError,
        BoundedOutputError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
    ):
        return None
    if not isinstance(plugins, list):
        return None
    for plugin in plugins:
        if isinstance(plugin, dict) and plugin.get("id") == plugin_id:
            return plugin.get("enabled") is True
    return False


def xdg_application_dirs() -> list[Path]:
    home = Path.home()
    configured_home = os.environ.get("XDG_DATA_HOME", "")
    data_home = Path(configured_home) if os.path.isabs(configured_home) else home / ".local/share"
    configured_dirs = os.environ.get("XDG_DATA_DIRS", "")
    data_dirs = configured_dirs.split(":") if configured_dirs else ["/usr/local/share", "/usr/share"]
    candidates = [data_home / "applications", home / ".nix-profile/share/applications"]
    candidates.extend(Path(value) / "applications" for value in data_dirs if os.path.isabs(value))
    result: list[Path] = []
    seen: set[Path] = set()
    for path in candidates:
        if path not in seen:
            seen.add(path)
            result.append(path)
    return result


def default_browser_desktop() -> str:
    environment = {**os.environ, "LC_ALL": "C"}
    environment.pop("BROWSER", None)
    for command in (
        ["xdg-settings", "get", "default-web-browser"],
        ["xdg-mime", "query", "default", "x-scheme-handler/https"],
    ):
        try:
            process = run_bounded_process(
                command,
                output_limit=MAX_DEFAULT_BROWSER_OUTPUT,
                timeout=2,
                env=environment,
            )
            result = process.stdout.decode("utf-8").strip()
        except (
            OSError,
            UnicodeDecodeError,
            BoundedOutputError,
            subprocess.TimeoutExpired,
        ):
            continue
        if result:
            identifier = Path(result).name
            return identifier if len(identifier) <= MAX_ID_LENGTH else ""
    return ""


def desktop_browser(path: Path) -> dict[str, Any] | None:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        raw = read_limited_text(path, MAX_DESKTOP_FILE_BYTES, "Desktop entry")
        parser.read_string(raw, source=str(path))
        entry = parser["Desktop Entry"]
    except (OSError, UnicodeError, ValueError, configparser.Error, KeyError):
        return None
    if entry.get("Type", "Application") != "Application":
        return None
    if entry.get("Hidden", "false").lower() == "true":
        return None
    if entry.get("NoDisplay", "false").lower() == "true":
        return None
    mime_types = {value for value in entry.get("MimeType", "").split(";") if value}
    if "x-scheme-handler/https" not in mime_types:
        return None
    try_exec = entry.get("TryExec", "").strip()
    if try_exec:
        executable = try_exec if os.path.isabs(try_exec) else shutil.which(try_exec)
        if not executable or not os.access(executable, os.X_OK):
            return None
    name = entry.get("Name", "").strip()
    icon = entry.get("Icon", "").strip()
    identifier = path.name
    try:
        desktop_path = str(path.resolve())
    except (OSError, RuntimeError):
        return None
    if (
        not name
        or len(name) > MAX_BROWSER_NAME_LENGTH
        or len(icon) > MAX_BROWSER_ICON_LENGTH
        or len(identifier) > MAX_ID_LENGTH
        or len(desktop_path) > MAX_PATH_LENGTH
    ):
        return None
    return {
        "id": identifier,
        "name": name,
        "icon": icon,
        "desktopPath": desktop_path,
    }


def discover_browsers(
    application_dirs: list[Path] | None = None,
    default_desktop: str | None = None,
) -> dict[str, Any]:
    directories = application_dirs if application_dirs is not None else xdg_application_dirs()
    default_id = (
        default_browser_desktop()
        if default_desktop is None
        else Path(default_desktop).name
    )
    if len(default_id) > MAX_ID_LENGTH:
        default_id = ""
    browsers: list[dict[str, Any]] = []
    seen: set[str] = set()
    scanned = 0
    exhausted = False
    for directory in directories:
        if not directory.is_dir():
            continue
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    scanned += 1
                    if scanned > MAX_APPLICATION_ENTRIES:
                        exhausted = True
                        break
                    if not entry.name.endswith(".desktop") or entry.name in seen:
                        continue
                    seen.add(entry.name)
                    try:
                        if not entry.is_file(follow_symlinks=True):
                            continue
                    except OSError:
                        continue
                    path = Path(entry.path)
                    browser = desktop_browser(path)
                    if browser is None:
                        continue
                    browser["isDefault"] = path.name == default_id
                    browsers.append(browser)
                    if len(browsers) >= MAX_BROWSERS:
                        exhausted = True
                        break
        except OSError:
            continue
        if exhausted:
            break
    browsers.sort(key=lambda item: (not item["isDefault"], item["name"].casefold(), item["id"]))
    return {"ok": True, "browsers": browsers, "defaultDesktop": default_id}


def valid_hostname(value: str) -> bool:
    if not value:
        return False
    if ":" in value:
        address = value.split("%", 1)[0]
        try:
            ipaddress.IPv6Address(address)
            return True
        except ValueError:
            return False

    comparable = value[:-1] if value.endswith(".") else value
    if not comparable or len(comparable) > 253 or ".." in comparable:
        return False
    if re.search(r"[\[\]<>\\^`{|}]", comparable):
        return False
    if re.fullmatch(r"[0-9.]+", comparable) and "." in comparable:
        try:
            ipaddress.IPv4Address(comparable)
            return True
        except ValueError:
            return False
    return all(
        label and len(label) <= 63 and not label.startswith("-") and not label.endswith("-")
        for label in comparable.split(".")
    )


def valid_url(value: Any, add_scheme: bool = False) -> str:
    value = str(value or "").strip()
    if add_scheme and value and ":" not in value.split("/", 1)[0]:
        value = "https://" + value
    if not value or len(value) > MAX_URL_LENGTH or re.search(r"\s", value):
        return ""
    try:
        parsed = urlsplit(value)
        if parsed.scheme.lower() not in ("http", "https"):
            return ""
        if (
            not parsed.hostname
            or not valid_hostname(parsed.hostname)
            or parsed.username is not None
            or parsed.password is not None
        ):
            return ""
        # Accessing port validates it and catches values outside 0..65535.
        parsed.port
    except (ValueError, UnicodeError):
        return ""
    return value


def canonical_url(value: Any) -> str:
    value = valid_url(value)
    if not value:
        return ""
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    if ":" in host and not host.startswith("["):
        host = "[" + host + "]"
    port = parsed.port
    if port and not ((parsed.scheme.lower() == "http" and port == 80)
                     or (parsed.scheme.lower() == "https" and port == 443)):
        host += ":" + str(port)
    path = parsed.path or "/"
    return urlunsplit((parsed.scheme.lower(), host, path, parsed.query, parsed.fragment))


def normalize_tags(value: Any) -> list[str]:
    if isinstance(value, list):
        source = value[:MAX_TAGS]
    else:
        serialized = str(value or "")
        if len(serialized) > MAX_TAGS * (MAX_TAG_LENGTH + 1):
            return []
        source = serialized.split(",", MAX_TAGS)[:MAX_TAGS]
    result: list[str] = []
    seen: set[str] = set()
    for item in source:
        tag = str(item).strip()
        key = tag.casefold()
        if tag and len(tag) <= MAX_TAG_LENGTH and key not in seen:
            result.append(tag)
            seen.add(key)
    return result


def normalize_keyword(value: Any) -> str:
    keyword = str(value or "").strip()
    return (
        keyword
        if keyword and len(keyword) <= MAX_KEYWORD_LENGTH and not re.search(r"\s", keyword)
        else ""
    )


def stored_png_data_url(value: Any) -> str:
    value = str(value or "").strip()
    if len(value) > 140_000:
        return ""
    match = re.fullmatch(r"data:image/png;base64,([A-Za-z0-9+/]+=*)", value)
    if not match:
        return ""
    try:
        raw = base64.b64decode(match.group(1), validate=True)
    except (ValueError, TypeError):
        return ""
    source = image_input(raw)
    if (
        len(raw) > MAX_ICON_OUTPUT
        or source is None
        or source[0] != "PNG"
    ):
        return ""
    return "data:image/png;base64," + base64.b64encode(raw).decode("ascii")


def jpeg_dimensions(raw: bytes) -> tuple[int, int] | None:
    """Read JPEG SOF dimensions without invoking an image decoder."""
    if not raw.startswith(b"\xff\xd8"):
        return None
    index = 2
    sof_markers = {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    }
    while index < len(raw):
        if raw[index] != 0xFF:
            index += 1
            continue
        while index < len(raw) and raw[index] == 0xFF:
            index += 1
        if index >= len(raw):
            return None
        marker = raw[index]
        index += 1
        if marker == 0x00 or marker == 0xD8 or 0xD0 <= marker <= 0xD9:
            continue
        if index + 2 > len(raw):
            return None
        segment_length = int.from_bytes(raw[index:index + 2], "big")
        if segment_length < 2 or index + segment_length > len(raw):
            return None
        if marker in sof_markers:
            if segment_length < 7:
                return None
            height = int.from_bytes(raw[index + 3:index + 5], "big")
            width = int.from_bytes(raw[index + 5:index + 7], "big")
            return width, height
        index += segment_length
    return None


def webp_dimensions(raw: bytes) -> tuple[int, int] | None:
    if len(raw) < 30 or raw[:4] != b"RIFF" or raw[8:12] != b"WEBP":
        return None
    chunk = raw[12:16]
    if chunk == b"VP8X":
        width = 1 + int.from_bytes(raw[24:27], "little")
        height = 1 + int.from_bytes(raw[27:30], "little")
        return width, height
    if chunk == b"VP8L" and raw[20] == 0x2F:
        bits = int.from_bytes(raw[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if chunk == b"VP8 " and raw[23:26] == b"\x9d\x01\x2a":
        width = int.from_bytes(raw[26:28], "little") & 0x3FFF
        height = int.from_bytes(raw[28:30], "little") & 0x3FFF
        return width, height
    return None


def image_input(raw: bytes) -> tuple[str, int, int] | None:
    """Return an allowlisted ImageMagick coder and header dimensions."""
    result: tuple[str, int, int] | None = None
    if (
        len(raw) >= 24
        and raw.startswith(b"\x89PNG\r\n\x1a\n")
        and raw[12:16] == b"IHDR"
    ):
        result = (
            "PNG",
            int.from_bytes(raw[16:20], "big"),
            int.from_bytes(raw[20:24], "big"),
        )
    elif len(raw) >= 10 and raw[:6] in (b"GIF87a", b"GIF89a"):
        result = (
            "GIF",
            int.from_bytes(raw[6:8], "little"),
            int.from_bytes(raw[8:10], "little"),
        )
    elif raw.startswith(b"\xff\xd8"):
        dimensions = jpeg_dimensions(raw)
        if dimensions:
            result = ("JPEG", dimensions[0], dimensions[1])
    elif len(raw) >= 6 and raw[:4] == b"\x00\x00\x01\x00":
        count = int.from_bytes(raw[4:6], "little")
        if 0 < count <= MAX_ICON_FRAMES and len(raw) >= 6 + count * 16:
            widths = [raw[6 + index * 16] or 256 for index in range(count)]
            heights = [raw[7 + index * 16] or 256 for index in range(count)]
            result = ("ICO", max(widths), max(heights))
    elif len(raw) >= 30 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        dimensions = webp_dimensions(raw)
        if dimensions:
            result = ("WEBP", dimensions[0], dimensions[1])

    if result is None:
        return None
    _, width, height = result
    if (
        width <= 0
        or height <= 0
        or width > MAX_ICON_DIMENSION
        or height > MAX_ICON_DIMENSION
        or width * height > MAX_ICON_PIXELS
    ):
        return None
    return result


def png_data_url(raw: bytes) -> str:
    if not raw or len(raw) > MAX_ICON_INPUT:
        return ""
    source = image_input(raw)
    if source is None:
        return ""
    coder, _, _ = source
    try:
        proc = run_bounded_process(
            [
                "magick",
                "-limit", "width", str(MAX_ICON_DIMENSION),
                "-limit", "height", str(MAX_ICON_DIMENSION),
                "-limit", "area", str(MAX_ICON_PIXELS),
                "-limit", "list-length", str(MAX_ICON_FRAMES),
                f"{coder}:-[0]",
                "-strip", "-thumbnail", "64x64>", "PNG:-",
            ],
            input_data=raw,
            output_limit=MAX_ICON_OUTPUT,
            timeout=5,
            env={
                **os.environ,
                "MAGICK_AREA_LIMIT": str(MAX_ICON_PIXELS),
                "MAGICK_DISK_LIMIT": "128MiB",
                "MAGICK_HEIGHT_LIMIT": str(MAX_ICON_DIMENSION),
                "MAGICK_LIST_LENGTH_LIMIT": str(MAX_ICON_FRAMES),
                "MAGICK_MAP_LIMIT": "64MiB",
                "MAGICK_MEMORY_LIMIT": "64MiB",
                "MAGICK_TIME_LIMIT": "5",
                "MAGICK_WIDTH_LIMIT": str(MAX_ICON_DIMENSION),
            },
        )
    except (OSError, BoundedOutputError, subprocess.TimeoutExpired):
        return ""
    output = proc.stdout
    if proc.returncode or not output.startswith(b"\x89PNG\r\n\x1a\n"):
        return ""
    return "data:image/png;base64," + base64.b64encode(output).decode("ascii")


def embedded_icon(value: Any) -> str:
    value = str(value or "").strip()
    encoded_limit = ((MAX_ICON_INPUT + 2) // 3) * 4 + 4
    if len(value) > encoded_limit + 256:
        return ""
    match = re.fullmatch(r"data:image/[^;,]+(?:;[^,]*)?;base64,(.+)", value, re.I | re.S)
    if not match:
        return ""
    if len(match.group(1)) > encoded_limit:
        return ""
    try:
        raw = base64.b64decode(match.group(1), validate=True)
    except (ValueError, TypeError):
        return ""
    # Reject active/external SVG content before handing it to the rasterizer.
    if b"<svg" in raw[:4096].lower():
        lowered = raw.lower()
        if (b"<!doctype" in lowered or b"<!entity" in lowered
                or b"@import" in lowered
                or re.search(br"url\s*\(\s*['\"]?(?:/|file:|https?:|ftp:)", lowered)):
            return ""
        raw = re.sub(
            br"(?:xlink:)?href\s*=\s*(['\"])(?!(?:#|data:)).*?\1",
            b"",
            raw,
            flags=re.I | re.S,
        )
    return png_data_url(raw)


class BookmarkHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.items: list[dict[str, Any]] = []
        self._attrs: dict[str, str] | None = None
        self._title: list[str] = []
        self._title_length = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() == "a":
            self._attrs = {str(k).upper(): str(v or "") for k, v in attrs}
            self._title = []
            self._title_length = 0

    def handle_data(self, data: str) -> None:
        if self._attrs is not None:
            remaining = MAX_TITLE_LENGTH - self._title_length
            if remaining > 0:
                part = data[:remaining]
                self._title.append(part)
                self._title_length += len(part)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or self._attrs is None:
            return
        if len(self.items) >= MAX_BOOKMARKS:
            raise ValueError(f"Bookmark file contains more than {MAX_BOOKMARKS} entries")
        self.items.append({
            "title": html.unescape("".join(self._title)).strip(),
            "url": html.unescape(self._attrs.get("HREF", "")).strip(),
            "tags": normalize_tags(self._attrs.get("TAGS", "")),
            "keyword": self._attrs.get("SHORTCUTURL", "").strip(),
            "iconSource": self._attrs.get("ICON", "").strip(),
        })
        self._attrs = None
        self._title = []


def read_store(path: str) -> list[dict[str, Any]]:
    store_path = Path(path)
    try:
        raw = read_limited_text(
            store_path,
            MAX_STORE_BYTES,
            "Bookmarks store",
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return []
    data = json.loads(raw)
    if isinstance(data, list):
        source = data
    elif isinstance(data, dict) and isinstance(data.get("bookmarks"), list):
        if int(data.get("version") or 0) > 3:
            raise ValueError("bookmarks.json uses a newer data format")
        source = data["bookmarks"]
    else:
        raise ValueError("bookmarks.json must contain a bookmarks array")
    if len(source) > MAX_BOOKMARKS:
        raise ValueError(f"Bookmarks store contains more than {MAX_BOOKMARKS} entries")
    return source


def load_store(path: str) -> dict[str, Any]:
    """Return a byte- and count-bounded store document for the QML process."""
    source = read_store(path)
    bookmarks: list[dict[str, Any]] = []
    invalid = 0
    for raw_item in source:
        item = normalize_item(raw_item, icon_policy="stored")
        identifier = (
            str(raw_item.get("id") or "").strip()
            if isinstance(raw_item, dict)
            else ""
        )
        if item is None or not identifier or len(identifier) > MAX_ID_LENGTH:
            invalid += 1
            continue
        item["id"] = identifier
        bookmarks.append(item)
    return {
        "ok": True,
        "data": {"version": 3, "bookmarks": bookmarks},
        "invalid": invalid,
    }


def save_store(path: str) -> dict[str, Any]:
    """Atomically save one bounded store document received over stdin."""
    raw = sys.stdin.buffer.read(MAX_STORE_BYTES + 1)
    if len(raw) > MAX_STORE_BYTES:
        raise ValueError("Bookmarks store is too large")
    text = raw.decode("utf-8")
    data = json.loads(text)
    if not isinstance(data, dict) or not isinstance(data.get("bookmarks"), list):
        raise ValueError("bookmarks.json must contain a bookmarks array")
    if len(data["bookmarks"]) > MAX_BOOKMARKS:
        raise ValueError(f"Bookmarks store contains more than {MAX_BOOKMARKS} entries")

    destination = Path(path)
    mode = existing_regular_mode(destination, "Bookmarks store", 0o600)
    _atomic_write_text(destination, text, mode)
    return {"ok": True}


def normalize_item(
    item: Any,
    icon_policy: str = "stored",
    preserve_usage: bool = True,
) -> dict[str, Any] | None:
    if not isinstance(item, dict):
        return None
    url = valid_url(item.get("url") or item.get("href"))
    if not url:
        return None
    title = str(item.get("title") or "").strip()
    if len(title) > MAX_TITLE_LENGTH:
        return None
    if icon_policy == "external":
        favicon = embedded_icon(item.get("iconSource") or item.get("favicon"))
    elif icon_policy == "none":
        favicon = ""
    elif icon_policy == "stored":
        favicon = stored_png_data_url(item.get("favicon"))
    else:
        raise ValueError("Invalid favicon processing policy")
    try:
        usage_score = float(item.get("usageScore") or 0) if preserve_usage else 0.0
        if not math.isfinite(usage_score) or usage_score < 0:
            usage_score = 0.0
    except (TypeError, ValueError):
        usage_score = 0.0
    try:
        last_opened_at = int(item.get("lastOpenedAt") or 0) if preserve_usage else 0
        if last_opened_at < 0:
            last_opened_at = 0
    except (TypeError, ValueError, OverflowError):
        last_opened_at = 0
    return {
        "title": title,
        "url": url,
        "tags": normalize_tags(item.get("tags")),
        "keyword": normalize_keyword(item.get("keyword") or item.get("shortcuturl")),
        "favicon": favicon,
        "usageScore": usage_score,
        "lastOpenedAt": last_opened_at,
    }


def import_bookmarks(source_arg: str, store_path: str) -> dict[str, Any]:
    if source_arg.startswith("file:"):
        parsed = urlsplit(source_arg)
        source_arg = unquote(parsed.path)
    source_path = Path(source_arg)
    suffix = source_path.suffix.lower()
    raw = read_limited_text(source_path, MAX_IMPORT_BYTES, "Bookmark file")

    if suffix in (".html", ".htm") or "<!DOCTYPE NETSCAPE-Bookmark-file" in raw[:1000]:
        parser = BookmarkHTMLParser()
        parser.feed(raw)
        source_items = parser.items
        source_format = "HTML"
        external_icon_field = "iconSource"
        preserve_usage = False
    else:
        data = json.loads(raw)
        if isinstance(data, list):
            source_items = data
        elif isinstance(data, dict):
            source_items = data.get("bookmarks", [])
        else:
            raise ValueError("JSON must be an array or object containing bookmarks")
        if not isinstance(source_items, list):
            raise ValueError("JSON must contain a bookmarks array")
        source_format = "JSON"
        external_icon_field = "favicon"
        preserve_usage = True

    if len(source_items) > MAX_BOOKMARKS:
        raise ValueError(f"Bookmark file contains more than {MAX_BOOKMARKS} entries")

    existing = {canonical_url(item.get("url")): item for item in read_store(store_path)}
    result: list[dict[str, Any]] = []
    positions: dict[str, int] = {}
    rejected = 0
    duplicates_in_file = 0
    duplicates_existing = 0
    icons = 0
    processed_icons = 0

    for raw_item in source_items:
        should_process_icon = (
            processed_icons < MAX_IMPORT_ICONS
            and isinstance(raw_item, dict)
            and bool(raw_item.get(external_icon_field))
        )
        if should_process_icon:
            processed_icons += 1
        item = normalize_item(
            raw_item,
            icon_policy="external" if should_process_icon else "none",
            preserve_usage=preserve_usage,
        )
        if item is None:
            rejected += 1
            continue
        key = canonical_url(item["url"])
        if key in positions:
            duplicates_in_file += 1
            current = result[positions[key]]
            if not current["title"] and item["title"]:
                current["title"] = item["title"]
            current["tags"] = normalize_tags(current["tags"] + item["tags"])
            if not current["keyword"] and item["keyword"]:
                current["keyword"] = item["keyword"]
            if not current["favicon"] and item["favicon"]:
                current["favicon"] = item["favicon"]
            if item["usageScore"] > current["usageScore"]:
                current["usageScore"] = item["usageScore"]
                current["lastOpenedAt"] = item["lastOpenedAt"]
            continue
        positions[key] = len(result)
        result.append(item)
        if key in existing:
            duplicates_existing += 1

    icons = sum(1 for item in result if item["favicon"])
    untitled = sum(1 for item in result if not item["title"])
    return {
        "ok": True,
        "items": result,
        "stats": {
            "format": source_format,
            "found": len(source_items),
            "ready": len(result),
            "rejected": rejected,
            "duplicatesInFile": duplicates_in_file,
            "duplicatesExisting": duplicates_existing,
            "new": len(result) - duplicates_existing,
            "favicons": icons,
            "untitled": untitled,
        },
    }


def create_store_backup(store_path: str, keep: int = BACKUP_LIMIT) -> dict[str, Any]:
    source = Path(store_path)
    try:
        contents = read_limited_bytes(
            source,
            MAX_STORE_BYTES,
            "Bookmarks store",
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return {"ok": True, "skipped": True, "backup": "", "pruned": 0}

    keep = max(1, int(keep))
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = Path(str(source) + ".backup-" + stamp)
    counter = 0
    while destination.exists():
        counter += 1
        destination = Path(str(source) + f".backup-{stamp}-{counter}")

    _atomic_write_bytes(destination, contents, 0o600)

    pattern = source.name + ".backup-*"
    backups = sorted(
        (path for path in source.parent.glob(pattern) if path.is_file()),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
        reverse=True,
    )
    pruned = 0
    for old_backup in backups[keep:]:
        old_backup.unlink()
        pruned += 1
    return {
        "ok": True,
        "skipped": False,
        "backup": str(destination),
        "pruned": pruned,
    }


class UnsafeNetworkTarget(ValueError):
    """A URL must not be fetched because its network destination is unsafe."""


def _ascii_hostname(hostname: str) -> str:
    """Return the unambiguous ASCII hostname used for DNS, TLS, and Host."""
    hostname = hostname.rstrip(".")
    if not hostname:
        raise UnsafeNetworkTarget("URL has no hostname")
    if "%" in hostname:
        raise UnsafeNetworkTarget("Scoped or percent-encoded hostnames are not fetched")
    try:
        return str(ipaddress.ip_address(hostname))
    except ValueError:
        try:
            encoded = hostname.encode("idna").decode("ascii").lower()
        except (UnicodeError, ValueError) as error:
            raise UnsafeNetworkTarget("URL hostname is invalid") from error
        if (
            not valid_hostname(encoded)
            or any(not re.fullmatch(r"[a-z0-9-]+", label) for label in encoded.split("."))
        ):
            raise UnsafeNetworkTarget("URL hostname is invalid")
        return encoded


def _globally_routable_address(value: str) -> bool:
    """Reject every special-purpose address, including embedded private IPv4."""
    if sys.version_info < (3, 13):
        # Python 3.13 corrected known is_global false positives and negatives.
        # Older runtimes may store bookmarks but must not authorize fetching.
        return False
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address):
        if (
            address.ipv4_mapped is not None
            or address.sixtofour is not None
            or address.teredo is not None
            or address.is_site_local
        ):
            # Transition and deprecated site-local addresses are unnecessary
            # here and have destination semantics that are easy to misread.
            return False
    return bool(
        address.is_global
        and not address.is_private
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_multicast
        and not address.is_reserved
        and not address.is_unspecified
    )


def _resolve_public_addresses(hostname: str, port: int) -> list[str]:
    """Resolve once and reject the entire hostname if any answer is non-public."""
    try:
        answers = socket.getaddrinfo(
            hostname,
            port,
            family=socket.AF_UNSPEC,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
    except socket.gaierror as error:
        raise UnsafeNetworkTarget("URL hostname could not be resolved") from error

    addresses: list[str] = []
    for family, _type, _proto, _canonical, sockaddr in answers:
        if family not in (socket.AF_INET, socket.AF_INET6) or not sockaddr:
            raise UnsafeNetworkTarget("URL resolved to an unsupported address")
        value = str(sockaddr[0]).split("%", 1)[0]
        if not _globally_routable_address(value):
            raise UnsafeNetworkTarget("URL resolved to a non-public address")
        normalized = str(ipaddress.ip_address(value))
        if normalized not in addresses:
            addresses.append(normalized)
    if not addresses:
        raise UnsafeNetworkTarget("URL hostname had no public addresses")
    return addresses[:MAX_FETCH_ADDRESSES]


def _pinned_socket(address: str, port: int, timeout: int) -> socket.socket:
    """Connect to the literal address that was checked, without another DNS lookup."""
    parsed = ipaddress.ip_address(address)
    family = socket.AF_INET6 if parsed.version == 6 else socket.AF_INET
    destination: tuple[Any, ...] = (
        (address, port, 0, 0) if family == socket.AF_INET6 else (address, port)
    )
    stream = socket.socket(family, socket.SOCK_STREAM)
    stream.settimeout(timeout)
    try:
        stream.connect(destination)
        peer = str(stream.getpeername()[0]).split("%", 1)[0]
        if ipaddress.ip_address(peer) != parsed or not _globally_routable_address(peer):
            raise UnsafeNetworkTarget("Connected peer did not match the checked address")
    except BaseException:
        stream.close()
        raise
    return stream


class _PinnedHTTPConnection(HTTPConnection):
    def __init__(self, host: str, port: int, address: str, timeout: int) -> None:
        super().__init__(host, port, timeout=timeout)
        self._pinned_address = address

    def connect(self) -> None:
        self.sock = _pinned_socket(self._pinned_address, self.port, self.timeout)


class _PinnedHTTPSConnection(HTTPSConnection):
    def __init__(self, host: str, port: int, address: str, timeout: int) -> None:
        super().__init__(host, port, timeout=timeout, context=ssl.create_default_context())
        self._pinned_address = address

    def connect(self) -> None:
        stream = _pinned_socket(self._pinned_address, self.port, self.timeout)
        try:
            self.sock = self._context.wrap_socket(stream, server_hostname=self.host)
        except BaseException:
            stream.close()
            raise


def _network_url_parts(url: str) -> tuple[str, str, int, str]:
    value = valid_url(url)
    if not value:
        raise UnsafeNetworkTarget("URL is invalid")
    parsed = urlsplit(value)
    scheme = parsed.scheme.lower()
    hostname = _ascii_hostname(parsed.hostname or "")
    default_port = 443 if scheme == "https" else 80
    port = parsed.port or default_port
    if port != default_port:
        raise UnsafeNetworkTarget("URL does not use the default HTTP(S) port")
    path = quote(parsed.path or "/", safe="/%:@!$&'()*+,;=-._~")
    if parsed.query:
        path += "?" + quote(parsed.query, safe="/?%:@!$&'()*+,;=-._~")
    return scheme, hostname, port, path


def _request_from_address(
    scheme: str,
    hostname: str,
    port: int,
    path: str,
    address: str,
    limit: int,
    accept: str,
    timeout: int,
) -> tuple[int, str, Any, bytes]:
    connection_type = _PinnedHTTPSConnection if scheme == "https" else _PinnedHTTPConnection
    connection = connection_type(hostname, port, address, timeout)
    try:
        connection.request("GET", path, headers={
            "User-Agent": USER_AGENT,
            "Accept": accept,
            "Accept-Encoding": "identity",
            "Connection": "close",
        })
        response = connection.getresponse()
        if response.status in (301, 302, 303, 307, 308):
            return response.status, response.reason, response.headers, b""
        encoding = response.headers.get("Content-Encoding", "identity").strip().lower()
        if encoding not in ("", "identity"):
            raise ValueError("encoded responses are not accepted")
        length = response.headers.get("Content-Length")
        if length:
            try:
                content_length = int(length)
            except ValueError as error:
                raise ValueError("response has an invalid content length") from error
            if content_length < 0:
                raise ValueError("response has an invalid content length")
            if content_length > limit:
                raise ValueError("response is too large")
        raw = response.read(limit + 1)
        if len(raw) > limit:
            raise ValueError("response is too large")
        return response.status, response.reason, response.headers, raw
    finally:
        connection.close()


def fetch_bytes(
    url: str,
    limit: int,
    accept: str,
    timeout: int = 7,
    redirect_origin: str = "",
) -> tuple[bytes, str, str]:
    """Fetch bounded public HTTP(S) content without DNS rebinding or auto-redirects."""
    current_url = url
    for redirect_count in range(MAX_FETCH_REDIRECTS + 1):
        scheme, hostname, port, path = _network_url_parts(current_url)
        addresses = _resolve_public_addresses(hostname, port)
        last_error: BaseException | None = None
        response: tuple[int, str, Any, bytes] | None = None
        for address in addresses:
            try:
                response = _request_from_address(
                    scheme, hostname, port, path, address, limit, accept, timeout
                )
                break
            except (OSError, ssl.SSLError, HTTPException) as error:
                last_error = error
        if response is None:
            raise OSError("Could not connect to the public URL") from last_error

        status, reason, headers, raw = response
        if status in (301, 302, 303, 307, 308):
            if redirect_count >= MAX_FETCH_REDIRECTS:
                raise ValueError("response redirected too many times")
            location = headers.get("Location", "")
            redirected = valid_url(urljoin(current_url, location))
            if not redirected:
                raise UnsafeNetworkTarget("response redirected to an invalid URL")
            if scheme == "https" and urlsplit(redirected).scheme.lower() != "https":
                raise UnsafeNetworkTarget("HTTPS responses may not redirect to HTTP")
            if redirect_origin and not _same_origin(redirected, redirect_origin):
                raise UnsafeNetworkTarget("response redirected across origins")
            current_url = redirected
            continue
        if not 200 <= status < 300:
            raise ValueError(f"HTTP request failed with status {status} {reason}")
        return raw, current_url, headers.get_content_type()
    raise ValueError("response redirected too many times")


def _same_origin(first: str, second: str) -> bool:
    try:
        first_scheme, first_host, first_port, _ = _network_url_parts(first)
        second_scheme, second_host, second_port, _ = _network_url_parts(second)
    except (ValueError, UnicodeError):
        return False
    return (first_scheme, first_host, first_port) == (
        second_scheme, second_host, second_port
    )


class MetadataParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_title = False
        self.title_parts: list[str] = []
        self.title_length = 0
        self.og_title = ""
        self.icons: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {str(k).lower(): str(v or "") for k, v in attrs}
        if tag.lower() == "title":
            self.in_title = True
        elif tag.lower() == "meta" and values.get("property", "").lower() == "og:title":
            self.og_title = values.get("content", "").strip()[:MAX_TITLE_LENGTH]
        elif tag.lower() == "link" and "icon" in values.get("rel", "").lower().split():
            href = values.get("href", "")
            if (
                href
                and len(href) <= MAX_URL_LENGTH
                and len(self.icons) < MAX_ICON_CANDIDATES
            ):
                self.icons.append(href)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        if self.in_title:
            remaining = MAX_TITLE_LENGTH - self.title_length
            if remaining > 0:
                part = data[:remaining]
                self.title_parts.append(part)
                self.title_length += len(part)

    @property
    def title(self) -> str:
        title = " ".join("".join(self.title_parts).split())
        return (title or self.og_title)[:MAX_TITLE_LENGTH]


def enrich_url_from_web(url: str) -> dict[str, Any]:
    """Fetch optional web details inside the time-bounded worker process."""
    url = valid_url(url)
    if not url:
        raise ValueError("Web enrichment requires one valid HTTP(S) URL")

    hostname = urlsplit(url).hostname or url
    title = hostname
    favicon = ""
    try:
        raw, final_url, content_type = fetch_bytes(
            url, MAX_HTML, "text/html,application/xhtml+xml"
        )
        if (
            content_type in ("text/html", "application/xhtml+xml")
            or b"<html" in raw[:2048].lower()
        ):
            charset_match = re.search(
                br"charset\s*=\s*['\"]?([A-Za-z0-9._-]+)", raw[:8192], re.I
            )
            charset = (
                charset_match.group(1).decode("ascii", errors="ignore")
                if charset_match
                else "utf-8"
            )
            page = raw.decode(charset, errors="replace")
            parser = MetadataParser()
            parser.feed(page)
            title = parser.title or hostname
            icon_candidates = [
                candidate
                for value in parser.icons
                if valid_url(candidate := urljoin(final_url, value))
                and _same_origin(candidate, final_url)
            ]
            icon_candidates.append(urljoin(final_url, "/favicon.ico"))
            seen_icons: set[str] = set()
            for icon_url in icon_candidates[:4]:
                key = canonical_url(
                    urlunsplit(urlsplit(icon_url)._replace(fragment=""))
                )
                if not key or key in seen_icons:
                    continue
                seen_icons.add(key)
                try:
                    icon_raw, _, _ = fetch_bytes(
                        icon_url,
                        MAX_ICON_INPUT,
                        "image/*",
                        timeout=3,
                        redirect_origin=final_url,
                    )
                    favicon = png_data_url(icon_raw)
                    if favicon:
                        break
                except (OSError, ValueError):
                    continue
    except (OSError, ValueError, LookupError):
        pass
    return {"ok": True, "title": title, "favicon": favicon}


def _run_web_enrichment(url: str, settings_path: str) -> tuple[str, str]:
    """Run all optional network and decoder work behind a hard wall-clock limit."""
    try:
        process = run_bounded_process(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "enrich-url",
                settings_path,
            ],
            input_data=url.encode("utf-8"),
            output_limit=MAX_ENRICHMENT_OUTPUT,
            timeout=MAX_ENRICHMENT_SECONDS,
        )
    except (OSError, BoundedOutputError, subprocess.TimeoutExpired):
        return "", ""
    if process.returncode != 0:
        return "", ""
    try:
        result = json.loads(process.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "", ""
    if not isinstance(result, dict) or result.get("ok") is not True:
        return "", ""
    title = str(result.get("title") or "").strip()
    if len(title) > MAX_TITLE_LENGTH:
        title = ""
    return title, stored_png_data_url(result.get("favicon"))


def clipboard_bookmark(
    store_path: str,
    enrich_from_web: bool = False,
    settings_path: str = "",
) -> dict[str, Any]:
    try:
        process = run_bounded_process(
            ["wl-paste", "--no-newline", "--type", "text"],
            output_limit=MAX_CLIPBOARD_BYTES,
            timeout=2,
        )
        clipboard = process.stdout.decode("utf-8", errors="replace").strip()
    except BoundedOutputError:
        return {"ok": False, "error": "Clipboard text is too large"}
    except (OSError, subprocess.TimeoutExpired):
        return {"ok": False, "error": "Could not read the clipboard"}

    url = valid_url(clipboard)
    if not url:
        return {"ok": False, "error": "Clipboard must contain exactly one HTTP(S) URL"}

    key = canonical_url(url)
    for item in read_store(store_path):
        if canonical_url(item.get("url")) == key:
            return {"ok": True, "duplicate": True, "id": str(item.get("id") or ""), "url": url}

    title = ""
    favicon = ""
    if enrich_from_web:
        if not settings_path:
            raise ValueError("Web enrichment requires an explicit settings path")
        title, favicon = _run_web_enrichment(url, settings_path)
        if not title:
            title = urlsplit(url).hostname or url

    return {
        "ok": True,
        "duplicate": False,
        "item": {"title": title, "url": url, "tags": [], "keyword": "", "favicon": favicon},
    }


def copy_url_to_clipboard(value: str) -> dict[str, Any]:
    """Copy one validated bookmark URL without invoking a shell."""
    url = valid_url(value)
    if not url:
        return {"ok": False, "error": "Could not copy an invalid bookmark URL"}
    try:
        process = subprocess.run(
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
            input=url.encode("utf-8"),
            stdout=subprocess.DEVNULL,
            # wl-copy forks a clipboard-serving child. A PIPE here remains
            # open in that child, so subprocess.run waits until its timeout
            # even though the copy succeeded.
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except FileNotFoundError:
        return {"ok": False, "error": "Could not copy URL · install wl-clipboard"}
    except (OSError, subprocess.TimeoutExpired):
        return {"ok": False, "error": "Could not copy URL to the clipboard"}
    if process.returncode != 0:
        return {"ok": False, "error": "Could not copy URL to the clipboard"}
    return {"ok": True, "url": url}


def main() -> int:
    # Quickshell terminates helpers when a transient dialog closes. Raising
    # SystemExit lets active bounded subprocesses run their cleanup blocks and
    # terminate their entire process groups instead of leaving descendants.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    signal.signal(signal.SIGINT, lambda signum, frame: sys.exit(128 + signum))
    try:
        action = sys.argv[1]
        if action == "import" and len(sys.argv) == 4:
            result = import_bookmarks(sys.argv[2], sys.argv[3])
        elif action == "store-load" and len(sys.argv) == 3:
            result = load_store(sys.argv[2])
        elif action == "store-save" and len(sys.argv) == 3:
            result = save_store(sys.argv[2])
        elif action == "clipboard" and len(sys.argv) == 3:
            result = clipboard_bookmark(sys.argv[2], enrich_from_web=False)
        elif action == "clipboard-enrich" and len(sys.argv) == 4:
            settings = read_settings(sys.argv[3])
            result = clipboard_bookmark(
                sys.argv[2],
                enrich_from_web=settings["networkEnrichment"] is True,
                settings_path=sys.argv[3],
            )
        elif action == "enrich-url" and len(sys.argv) == 3:
            settings = read_settings(sys.argv[2])
            if settings["networkEnrichment"] is not True:
                raise ValueError("Web enrichment is disabled")
            raw_url = sys.stdin.buffer.read(MAX_URL_LENGTH * 4 + 1)
            if len(raw_url) > MAX_URL_LENGTH * 4:
                raise ValueError("Web enrichment URL is too large")
            result = enrich_url_from_web(raw_url.decode("utf-8"))
        elif action == "copy" and len(sys.argv) == 3:
            result = copy_url_to_clipboard(sys.argv[2])
        elif action == "browsers" and len(sys.argv) == 2:
            result = discover_browsers()
        elif action == "backup" and len(sys.argv) == 3:
            result = create_store_backup(sys.argv[2])
        elif action == "menu-entry" and len(sys.argv) == 5:
            operation = sys.argv[2]
            result = menu_entry_operation(operation, sys.argv[3], sys.argv[4])
        elif action == "menu-entry" and len(sys.argv) == 4 and sys.argv[2] == "cleanup":
            state = plugin_enabled_state("stefanmara.bookmarks")
            result = (
                manage_menu_entry(sys.argv[3], False)
                if state is False
                else {"ok": True, "changed": False, "installed": True,
                      "path": sys.argv[3]}
            )
        elif action == "network-enrichment" and len(sys.argv) == 4:
            result = network_enrichment_operation(sys.argv[2], sys.argv[3])
        else:
            raise ValueError(
                "usage: bookmark_helper.py import FILE STORE | clipboard STORE | "
                "clipboard-enrich STORE SETTINGS | copy URL | "
                "enrich-url SETTINGS < URL | "
                "store-load STORE | store-save STORE | browsers | backup STORE | "
                "network-enrichment {status|enable|disable} SETTINGS | "
                "menu-entry {status|install|remove|dismiss} "
                "FILE SETTINGS | menu-entry cleanup FILE"
            )
    except (IndexError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        result = {"ok": False, "error": str(error) or "Bookmark operation failed"}
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
