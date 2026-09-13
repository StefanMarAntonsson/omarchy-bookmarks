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


if __name__ == "__main__":
    unittest.main()
