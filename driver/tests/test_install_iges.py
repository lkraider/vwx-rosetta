import ast
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ast.parse((ROOT / "tools/install-artifact.py").read_text())
NAMES = {"IGES_SURFACES_AND_SOLIDS", "iges_types", "measure_iges"}
module = ast.Module(body=[n for n in SOURCE.body if getattr(n, "name", None) in NAMES or
                          (isinstance(n, ast.Assign) and n.targets[0].id in NAMES)], type_ignores=[])
SPACE = {}
exec(compile(module, "install-artifact.py", "exec"), SPACE)


def directory_line(text):
    return text.ljust(72)[:72] + "D" + "1".rjust(7) + "\n"


class MeasureIges(unittest.TestCase):
    def igs(self, *types):
        lines = ["start".ljust(72) + "S      1\n"]
        for kind in types:
            lines += [directory_line(str(kind).rjust(8)), directory_line(str(kind).rjust(8))]
        tmp = tempfile.NamedTemporaryFile("w", suffix=".igs", delete=False)
        tmp.writelines(lines)
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        return tmp.name

    def test_nurbs_surfaces_count_without_faces(self):
        count, fact = SPACE["measure_iges"](self.igs(128, 144, 128, 110))
        self.assertEqual(count, 3)
        self.assertIn("faces=0", fact)

    def test_brep_counts_solid_and_faces(self):
        self.assertEqual(SPACE["measure_iges"](self.igs(186, 510, 510, 502))[0], 3)

    def test_line_with_no_type_number_is_skipped(self):
        path = self.igs(128)
        with open(path, "a") as f:
            f.writelines([directory_line("garbage"), directory_line("garbage")])
        self.assertEqual(SPACE["iges_types"](path), [128])


if __name__ == "__main__":
    unittest.main()
