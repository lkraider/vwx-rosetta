# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.units.cm
# family_id: document.units
# recipe_revision: 1
# recipe_path: recipes/document.units.cm.json
# recipe_sha256: 912cd6a430aea57cbcf55f4fa06a5ea2e51b1033cc73e59ff5d1c942fa1ec69a
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.units.cm.vwx
#   sha256 d0fae028f165603bbf7deed34435d0764889eb4ce8bffb835c4629753455f850. Run 20261018T112600-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(1000, 1, 0, 2.54, "cm", " sq cm")
rosetta_save_reopen()
