import json
import unittest
from pathlib import Path

from index_references import tags_for


ROOT = Path(__file__).resolve().parents[2]


class ReferenceIndexTests(unittest.TestCase):
    def test_detected_objects_are_searchable_outside_setting_taxonomy(self):
        catalog = json.loads((ROOT / "Poser/PinterestLibrary/catalog.json").read_text())
        labels = json.loads((ROOT / "Tools/Typesense/vision_labels.json").read_text())
        cafe = next(entry for entry in catalog["references"]
                    if entry["pinID"] == "pin-1101552390110841312")
        tags = tags_for(cafe, labels[cafe["pinID"]])
        self.assertIn("chair", tags)
        self.assertIn("table", tags)
        self.assertIn("furniture", tags)
        self.assertNotIn("chair", cafe["title"].lower())


if __name__ == "__main__":
    unittest.main()
