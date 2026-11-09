#!/usr/bin/env python3
import importlib.util
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mesh_topology", ROOT / "driver/ui/mesh-topology.py")
mesh_topology = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mesh_topology)


def row(path, faces):
    return ["c", "3ds", path, "0" * 64, "1", "3", faces, faces, "0.5", "3"]


class Failures(unittest.TestCase):
    def test_zero_faces_fail(self):
        table = [row("files/c/a.3ds", "0"), row("files/c/b.3ds", "1")]
        self.assertEqual(mesh_topology.failures(table), ["files/c/a.3ds: 0 faces"])

    def test_reason_must_match_an_empty_file(self):
        table = [row("files/c/a.3ds", "0"), row("files/c/b.3ds", "1")]
        reasons = {"files/c/a.3ds": "r", "files/c/b.3ds": "r", "files/c/gone.3ds": "r"}
        with unittest.mock.patch.dict(mesh_topology.ZERO_FACES, reasons):
            self.assertEqual([f.split(":")[0] for f in mesh_topology.failures(table)],
                             ["files/c/b.3ds", "files/c/gone.3ds"])


def mesh(case, fmt, name, faces, area):
    return [case, fmt, "files/%s/%s" % (case, name), "0" * 64, "1", "3", faces, faces, area, "3"]


class AgainstFbx(unittest.TestCase):
    def test_area_below_the_fbx_reads_partial(self):
        table = mesh_topology.against_fbx([
            mesh("c", "fbx", "c.fbx", "144", "100.0"),
            mesh("c", "3ds", "c.3ds", "40", "99.3"),
            mesh("c", "3ds", "c.all-layers.3ds", "12", "50.0"),
            mesh("c", "obj", "c.obj", "80", "198.6"),
            mesh("c", "gltf", "c.gltf", "144", "0.1"),
        ])
        self.assertEqual([r[-2:] for r in table],
                         [["-", "-"], ["0.993", "full"], ["0.500", "partial"], ["0.993", "full"], ["-", "-"]])
        self.assertEqual(table[1][-4:-2], ["144", "100.0"])
        self.assertEqual(len(mesh_topology.partials(table)), 1)

    def test_case_with_no_fbx_has_no_verdict(self):
        table = mesh_topology.against_fbx([mesh("c", "3ds", "c.3ds", "40", "1.0")])
        self.assertEqual(table[0][-4:], ["-", "-", "-", "-"])


if __name__ == "__main__":
    unittest.main()
