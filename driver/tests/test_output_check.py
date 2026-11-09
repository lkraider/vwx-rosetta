import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("output_check", ROOT / "driver/output-check.py")
output_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(output_check)


class OutputCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def file(self, name, text):
        path = os.path.join(self.tmp.name, "case.x", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        return path

    def check(self, path, record=None):
        return output_check.check(path, record, {}, self.tmp.name)

    def test_absent_and_empty_files_fail(self):
        self.assertEqual(self.check(os.path.join(self.tmp.name, "none.obj"))["detail"], "absent")
        self.assertEqual(self.check(self.file("e.obj", ""))["detail"], "empty")

    def test_obj_with_geometry_passes(self):
        row = self.check(self.file("a.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"))
        self.assertEqual((row["objects"], row["verdict"]), ("1/1", "pass"))

    def test_obj_without_geometry_fails(self):
        self.assertEqual(self.check(self.file("b.obj", "# nothing\n"))["verdict"], "fail")

    def test_format_with_no_reader_is_unread(self):
        self.assertEqual(self.check(self.file("c.png", "x"))["verdict"], "unread")

    def test_vwx_passes_on_the_header_of_its_profile_year(self):
        head = "\0\0\x09\xe0" + "\0" * 8 + "\0 VectorWorks 217\0\0\0ENXU"
        record = self.file("v.json", '{"case": "case.x", "profile": "vwx.2023"}')
        row = self.check(self.file("v.v2023.vwx", head), record)
        self.assertEqual((row["reader"], row["objects"], row["verdict"]), ("header", "", "pass"))
        self.assertEqual(self.check(self.file("w.v2024.vwx", head))["verdict"], "fail")
        self.assertEqual(self.check(self.file("x.vwx", head))["verdict"], "fail")

    def test_reader_exception_is_a_fail_row(self):
        audit = type("Audit", (), {"read_dxf": staticmethod(lambda path: next(iter(())))})
        real = output_check.load
        output_check.load = lambda name, file: audit if name == "reader_audit" else real(name, file)
        self.addCleanup(setattr, output_check, "load", real)
        row = self.check(self.file("t.dxf", "  0\nSECTION\n"))
        self.assertEqual((row["reader"], row["verdict"]), ("exception", "fail"))
        self.assertIn("StopIteration", row["detail"])

    def test_settings_come_from_the_record(self):
        record = self.file("r.json", '{"case": "case.x", "profile": "obj.mesh", "setup": [{"ok": true}],'
                                     ' "dialogs": [{"text": "a"}]}')
        row = self.check(self.file("d.obj", "v 0 0 0\n"), record)
        self.assertEqual((row["profile"], row["settings"], row["alerts"]), ("obj.mesh", "recorded", "1"))
        self.assertEqual(self.check(self.file("f.obj", "v 0 0 0\n"))["settings"], "unknown")

    def test_x_t_sphere_without_points_passes_on_its_centre(self):
        head = "**ABCDEFGHIJKLMNOPQRSTUVWXYZ\n**END_OF_HEADER*****\n"
        sphere = "T51 : TRANSMIT FILE 70 11 53 255 5 6 0 8 0 0 0 +.0315 .01275 -.004 .00625 0 -1 0 1 0 0 19 9\n"
        row = self.check(self.file("s.x_t", head + sphere))
        self.assertEqual((row["objects"], row["verdict"], row["detail"]), ("1/1", "pass", "1 points"))

    def test_x_t_integer_run_is_no_centre(self):
        head = "**ABCDEFGHIJKLMNOPQRSTUVWXYZ\n**END_OF_HEADER*****\n"
        run = "T51 : TRANSMIT FILE 53 255 5 6 0 8 0 0 0 +262 0 0 1 2 3 4 5 6 7 19 9\n"
        self.assertEqual(self.check(self.file("r.x_t", head + run))["verdict"], "fail")

    def test_x_t_point_marked_with_a_question_mark_is_read(self):
        head = "**ABCDEFGHIJKLMNOPQRSTUVWXYZ\n**END_OF_HEADER*****\n"
        point = "T51 : TRANSMIT FILE ?29 255 7 73 0 22 0 0 .001 .002 .003 19 9\n"
        row = self.check(self.file("p.x_t", head + point))
        self.assertEqual((row["verdict"], row["detail"]), ("pass", "1 points"))

    def test_dwg_paper_space_entity_counts_with_model_space(self):
        objects = [{"object": "LAYER", "handle": [0, 1], "name": "Plan"},
                   {"entity": "LWPOLYLINE", "entmode": 1, "layer": [0, 1]},
                   {"entity": "LINE", "entmode": 2, "layer": [0, 1]}]

        def dwgread(argv, **kwargs):
            with open(argv[argv.index("-o") + 1], "w") as f:
                json.dump({"OBJECTS": objects}, f)

        presence = output_check.presence
        with mock.patch.object(presence.shutil, "which", return_value="dwgread"), \
                mock.patch.object(presence.subprocess, "run", side_effect=dwgread):
            self.assertEqual(presence.layers_dwg("p.dwg"), {"Plan": 2})

    def test_x_t_point_chain_ending_on_another_node_is_read(self):
        head = "**ABCDEFGHIJKLMNOPQRSTUVWXYZ\n**END_OF_HEADER*****\n"
        chain = ("T51 : TRANSMIT FILE 29 255 7 42 0 20 21 0 .0193 .01325 .00586 19 "
                 "29 21 45 0 45 39 7 .0128 .01664 .003 18 "
                 "29 39 25 0 41 26 21 .018 .0025 0 18 "
                 "29 26 23 0 10 36 39 .0199 .0025 .0085 29 "
                 "29 36 21 0 29 37 26 .0104 .0059 .0044 30 37 9\n")
        row = self.check(self.file("c.x_t", head + chain))
        self.assertEqual((row["verdict"], row["detail"]), ("pass", "5 points"))
    def test_x_t_false_points_that_name_each_other_are_dropped(self):
        head = "**ABCDEFGHIJKLMNOPQRSTUVWXYZ\n**END_OF_HEADER*****\n"
        pair = "T51 : TRANSMIT FILE 29 100 5 0 4 101 900 1 2 0 7 29 101 6 0 4 901 100 3 4 0 7\n"
        self.assertEqual(self.check(self.file("f.x_t", head + pair))["verdict"], "fail")

if __name__ == "__main__":
    unittest.main()
