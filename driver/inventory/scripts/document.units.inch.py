# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.units.inch
# family_id: document.units
# recipe_revision: 1
# recipe_path: recipes/document.units.inch.json
# recipe_sha256: 5fc364a8370966e8129683f6893dfb7cefa74e7c86da7e9d50d7c304add6825d
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.units.inch.vwx
#   sha256 0db9d91355a0b57314a2ea8f6b38fb2f197bd63a7da3efec63065dc89d1dae1a. Run 20261018T112739-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(64, 2, 0, 1.0, "\"", " sq in")
rosetta_save_reopen()
