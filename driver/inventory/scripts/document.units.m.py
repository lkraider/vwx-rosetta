# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.units.m
# family_id: document.units
# recipe_revision: 1
# recipe_path: recipes/document.units.m.json
# recipe_sha256: e77352285b46f7aa32916691a7e861b38d235f30ae333e3da8163bf596b17780
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.units.m.vwx
#   sha256 5234215c733442afcc4210b4de134c2f0e04f4b42428e56cb4b3f14cbb25e593. Run 20261018T112654-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(1000, 1, 0, 0.0254, "m", " sq m")
rosetta_save_reopen()
