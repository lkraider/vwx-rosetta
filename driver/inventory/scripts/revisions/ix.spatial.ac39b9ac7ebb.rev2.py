# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# The base calls rosetta_checkpoint("factor-mid"). The revision drops
# that call, because make-sources.py records no checkpoint and the call adds nothing to the document.
# case_id: ix.spatial.ac39b9ac7ebb
# family_id: solid.primitive
# recipe_revision: 2
# recipe_path: recipes/revisions/ix.spatial.ac39b9ac7ebb.rev2.json
# recipe_sha256: f7d7cc4a167e6e6f6cea101f6a22e9d992ba720cf10fb8a56688f118f091cbd5
# base: driver/inventory/scripts/ix.spatial.ac39b9ac7ebb.py
# native_verification: executed: driver/ui/make-sources.py batch 7, commit 2527225, wrote sources/ix.spatial.ac39b9ac7ebb.vwx
#   sha256 9123671cdaf86ddbb26376d4aa1a99f9a23737e22173f15f47ee5e65c04e6c06. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_save_reopen() before running this file.
import vs
h_flay = vs.ActLayer()
vs.SetLayerElevation(h_flay, 640.75, 95.5)
h_cone = vs.CreateCone((8.5, -3.25, 1.75), (15, 6.5, 38.25), 9.75)
vs.SetName(h_cone, "cone-a")
vs.Set3DRot(h_cone, 15, 0, 32.5, 1, 2, 3)
vs.NameClass("Rosetta-F3-Hidden")
vs.SetClass(h_cone, "Rosetta-F3-Hidden")
vs.NameClass("Rosetta-F3-Visible")
vs.BeginXtrd(0, 20)
vs.Rect((40, 12), (55, 0))
vs.EndXtrd()
h_box = vs.LNewObj()
vs.SetName(h_box, "box-visible")
vs.SetClass(h_box, "Rosetta-F3-Visible")
vs.Set3DRot(h_box, 15, 0, 32.5, 1, 2, 3)
vs.NameClass("None")
vs.HideClass("Rosetta-F3-Hidden")
rosetta_save_reopen()
