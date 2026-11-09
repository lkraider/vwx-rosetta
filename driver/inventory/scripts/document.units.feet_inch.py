# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.units.feet_inch
# family_id: document.units
# recipe_revision: 1
# recipe_path: recipes/document.units.feet_inch.json
# recipe_sha256: aca3d9a74b2bb67cefe369dfa52fa6afe97907c5a2507fa4a974ea7ed4f769fa
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.units.feet_inch.vwx
#   sha256 f251e8b5beefe4a9313e4135843584083b2956e624daa52fea716831c6000856. Run 20261018T112818-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(4096, 64, 3, 1.0, "\"", "sq ft")
rosetta_save_reopen()
