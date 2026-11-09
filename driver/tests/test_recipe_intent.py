#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "driver"))
import recipe_intent  # noqa: E402


class FloorAndRoof(unittest.TestCase):
    def only_object(self, case):
        objects = recipe_intent.run(recipe_intent.script_for(str(ROOT), case)).objects
        self.assertEqual(len(objects), 1)
        return objects[0]

    def test_floor_keeps_its_rect_as_profile(self):
        floor = self.only_object("spatial.floor.legacy")
        self.assertEqual((floor["type"], floor["name"], floor["args"]), ("floor", "floor-a", [200]))
        self.assertEqual([p["type"] for p in floor["profile"]], ["rectangle"])

    def test_roof_face_keeps_its_rect_as_profile(self):
        roof = self.only_object("building.roof_face.single")
        self.assertEqual((roof["type"], roof["name"]), ("roof face", "roof-face-a"))
        self.assertEqual([p["type"] for p in roof["profile"]], ["rectangle"])


if __name__ == "__main__":
    unittest.main()
