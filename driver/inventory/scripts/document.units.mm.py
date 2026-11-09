# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.units.mm
# family_id: document.units
# recipe_revision: 1
# recipe_path: recipes/document.units.mm.json
# recipe_sha256: 7174f4a02e7036ab909e80d3971391c1101c5f9b0ee2e1c28ffc6ad2a31164ff
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.units.mm.vwx
#   sha256 35ff6f7744ac3613996294b5eb99a6e68ccc127cd6309b2c595b7cfef0bd1b84. Run 20261018T112456-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(1000, 1, 0, 25.4, "mm", " sq mm")
rosetta_save_reopen()
