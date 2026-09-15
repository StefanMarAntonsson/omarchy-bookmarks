import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ID = ROOT / "scripts" / "worker-source-id.sh"
PLUGIN_VERSION = json.loads((ROOT / "manifest.json").read_text())["version"]


def pin_values():
    values = {}
    for line in (ROOT / "worker-release.pin").read_text().splitlines():
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            values[key] = value
    return values


class PluginCopy:
    """A copy of the files the launcher needs, so tests can change source."""

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.plugin = base / "plugin"
        self.data = base / "data"
        for relative in ["Cargo.toml", "Cargo.lock", "worker-launcher.sh", "scripts/worker-source-id.sh"]:
            destination = self.plugin / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        shutil.copytree(ROOT / "src", self.plugin / "src")
        self.bin = self.data / "stefanmara.bookmarks" / "bin"
        self.binary = self.bin / "omarchy-bookmarks-worker"
        self.record = self.bin / "omarchy-bookmarks-worker.record"

    def source_id(self):
        return subprocess.run([SOURCE_ID, str(self.plugin)], check=True, capture_output=True, text=True).stdout.strip()

    def install_fake_worker(self):
        self.bin.mkdir(parents=True)
        self.binary.write_text("#!/bin/sh\necho started-worker\n")
        self.binary.chmod(stat.S_IRWXU)
        digest = subprocess.run(["sha256sum", str(self.binary)], check=True, capture_output=True, text=True).stdout.split()[0]
        self.record.write_text(
            f"origin=source\nversion={PLUGIN_VERSION}\n"
            f"source={self.source_id()}\nsha256={digest}\n"
        )

    def launch(self):
        environment = dict(os.environ, XDG_DATA_HOME=str(self.data), HOME=self.temp.name)
        return subprocess.run([str(self.plugin / "worker-launcher.sh")], capture_output=True, text=True, env=environment, timeout=10)

    def close(self):
        self.temp.cleanup()


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.copy = PluginCopy()

    def tearDown(self):
        self.copy.close()

    def assertSetupRequired(self, result):
        self.assertEqual(result.returncode, 78)
        message = json.loads(result.stdout)
        self.assertEqual(message["code"], "worker_setup_required")
        self.assertEqual(message["id"], 0)
        self.assertFalse(message["ok"])

    def test_missing_worker_requires_setup(self):
        self.assertSetupRequired(self.copy.launch())

    def test_verified_worker_starts(self):
        self.copy.install_fake_worker()
        result = self.copy.launch()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "started-worker")

    def test_modified_worker_is_not_run(self):
        self.copy.install_fake_worker()
        with self.copy.binary.open("a") as binary:
            binary.write("echo tampered\n")
        result = self.copy.launch()
        self.assertSetupRequired(result)
        self.assertNotIn("started-worker", result.stdout)

    def test_changed_source_requires_setup(self):
        self.copy.install_fake_worker()
        with (self.copy.plugin / "src" / "lib.rs").open("a") as source:
            source.write("\n// changed\n")
        self.assertSetupRequired(self.copy.launch())

    def test_new_source_file_changes_the_source_id(self):
        before = self.copy.source_id()
        (self.copy.plugin / "src" / "import").mkdir()
        (self.copy.plugin / "src" / "import" / "html.rs").write_text("")
        self.assertNotEqual(before, self.copy.source_id())

    def test_symlinked_worker_is_not_run(self):
        self.copy.install_fake_worker()
        real = self.copy.bin / "real-worker"
        self.copy.binary.rename(real)
        self.copy.binary.symlink_to(real)
        self.assertSetupRequired(self.copy.launch())


class ReleaseContractTests(unittest.TestCase):
    def test_source_id_is_stable(self):
        first = subprocess.run([SOURCE_ID], check=True, capture_output=True, text=True).stdout.strip()
        second = subprocess.run([SOURCE_ID, str(ROOT)], check=True, capture_output=True, text=True).stdout.strip()
        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertEqual(first, second)

    def test_pin_matches_plugin_version_and_format(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        cargo = re.search(r'^version = "([^"]+)"$', (ROOT / "Cargo.toml").read_text(), re.M).group(1)
        cargo_manifest = (ROOT / "Cargo.toml").read_text()
        values = pin_values()
        self.assertEqual(set(values), {"version", "source", "x86_64", "aarch64"})
        self.assertEqual(cargo, manifest["version"])
        self.assertEqual(values["version"], manifest["version"])
        self.assertIn('rust-version = "1.96"', cargo_manifest)
        self.assertIn("publish = false", cargo_manifest)
        hashes = [values["source"], values["x86_64"], values["aarch64"]]
        self.assertTrue(all(value == "" for value in hashes) or all(re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes))

    def test_workflow_actions_are_pinned_to_commits(self):
        workflows = [
            path
            for path in (ROOT / ".github" / "workflows").iterdir()
            if path.suffix in {".yml", ".yaml"}
        ]
        self.assertTrue(workflows)
        for workflow_path in workflows:
            workflow = workflow_path.read_text()
            uses = re.findall(r"uses:\s*(\S+)", workflow)
            self.assertTrue(uses)
            for action in uses:
                with self.subTest(workflow=workflow_path.name, action=action):
                    self.assertRegex(action, r"@[0-9a-f]{40}$")
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text()
        self.assertIn("permissions: {}", release)
        self.assertIn('- "release/**"', release)
        tag_only = "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"
        self.assertEqual(release.count(tag_only), 3)
        self.assertIn("needs: validate", release)

    def test_no_unverified_install_paths(self):
        checked = [ROOT / "README.md", ROOT / "worker-launcher.sh", *(ROOT / "scripts").glob("*.sh")]
        for path in checked:
            text = path.read_text()
            with self.subTest(path=path.name):
                self.assertNotIn("releases/latest", text)
                self.assertNotRegex(text, r"curl[^\n|]*\|\s*(ba)?sh")
                self.assertNotRegex(text, r"curl[^\n|]*\|\s*tar")

    def test_installer_repairs_private_directory_permissions(self):
        installer = (ROOT / "scripts" / "install-worker.sh").read_text()
        self.assertIn('chmod 700 -- "$directory"', installer)

    def test_launcher_only_runs_the_private_verified_worker(self):
        launcher = (ROOT / "worker-launcher.sh").read_text()
        self.assertNotIn("target/release", launcher)
        self.assertIn("worker_setup_required", launcher)
        self.assertIn("exec \"$binary\"", launcher)

    def test_overlay_offers_setup_in_a_terminal(self):
        ui = (ROOT / "Bookmarks.qml").read_text()
        client = (ROOT / "WorkerClient.qml").read_text()
        self.assertIn('root.setupRequired = parsed.code === "worker_setup_required"', client)
        self.assertIn('"omarchy-launch-tui", "--app-id=TUI.float"', ui)
        self.assertIn("root.workerInstaller, \"--pause\"", ui)
        self.assertIn("id: workerSetupPrompt", ui)
        self.assertIn("close the terminal to return to it", (ROOT / "scripts" / "install-worker.sh").read_text())


if __name__ == "__main__":
    unittest.main()
