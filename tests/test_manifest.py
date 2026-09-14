import json
from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def test_manifest_contract(self):
        manifest = json.loads((PROJECT_ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "stefanmara.bookmarks")
        self.assertNotEqual(manifest["id"].split(".", 1)[0], "omarchy")
        self.assertIn("overlay", manifest["kinds"])
        entry_point = manifest["entryPoints"]["overlay"]
        self.assertFalse(Path(entry_point).is_absolute())
        self.assertNotIn("..", Path(entry_point).parts)
        self.assertTrue((PROJECT_ROOT / entry_point).is_file())

    def test_readme_covers_installation_first_open_and_access(self):
        manifest = json.loads((PROJECT_ROOT / "manifest.json").read_text())
        plugin_id = manifest["id"]
        readme = (PROJECT_ROOT / "README.md").read_text()
        self.assertIn(
            "omarchy plugin add https://github.com/StefanMarAntonsson/omarchy-bookmarks.git --enable",
            readme,
        )
        self.assertIn(f"omarchy-shell shell summon {plugin_id} '{{}}'", readme)
        self.assertIn(f"omarchy plugin update {plugin_id}", readme)
        self.assertIn("~/.config/omarchy/extensions/omarchy-menu.jsonc", readme)
        self.assertIn("~/.config/hypr/bindings.lua", readme)
        self.assertIn("Do not use v1 to make changes after v2 has migrated", readme)
        self.assertTrue((PROJECT_ROOT / "preview.png").is_file())


if __name__ == "__main__":
    unittest.main()
