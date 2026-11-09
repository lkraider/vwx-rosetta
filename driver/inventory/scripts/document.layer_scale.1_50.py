# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.layer_scale.1_50
# family_id: document.layer_scale
# recipe_revision: 1
# recipe_path: recipes/document.layer_scale.1_50.json
# recipe_sha256: 62295ba2bbde94762906cd2bf1aed7625833b4ced14d221f69ca0ca204203bd4
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.layer_scale.1_50.vwx
#   sha256 0d6b9e65120d74d6aa5c6d4d1bf0ae79c21d0158cfa90749c80fb141826197c3. Run 20261018T112938-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.ActLayer()
vs.SetLScale(h_ly, 50)
vs.Rect((0, 1000), (2000, 0))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((0, 0), (2000, 0), -300, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.TextOrigin((0, 1500))
vs.TextSize(10)
vs.CreateText("Rosetta 1:50")
h_tx = vs.LNewObj()
vs.SetName(h_tx, "text-a")
rosetta_save_reopen()
