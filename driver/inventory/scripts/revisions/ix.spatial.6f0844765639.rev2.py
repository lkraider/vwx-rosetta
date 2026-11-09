# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.spatial.6f0844765639
# family_id: solid.primitive
# recipe_revision: 2
# recipe_path: recipes/revisions/ix.spatial.6f0844765639.rev2.json
# recipe_sha256: 9f153bef009b7574c419d960a58ba3a5520dd34af8b2595ae2b89a58240e0e7f
# base: driver/inventory/scripts/ix.spatial.6f0844765639.py
# native_verification: executed: driver/ui/make-sources.py batch 6, commit 2527225, wrote sources/ix.spatial.6f0844765639.vwx
#   sha256 48641dfb49c9bc33d9640e40bdf424c6e4c847a6db4e7ce1bbdd1484b89fc530. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.SetWorkingPlaneN((120.5, -40.25, 15), (0, 0.6, 0.8), (1, 0, 0))
h_flay = vs.ActLayer()
vs.SetLayerElevation(h_flay, 640.75, 95.5)
h_cone = vs.CreateCone((8.5, -3.25, 1.75), (15, 6.5, 38.25), 9.75)
vs.SetName(h_cone, "cone-a")
vs.NameClass("Rosetta-F3-Hidden")
vs.SetClass(h_cone, "Rosetta-F3-Hidden")
vs.NameClass("Rosetta-F3-Visible")
vs.BeginXtrd(0, 20)
vs.Rect((40, 12), (55, 0))
vs.EndXtrd()
h_box = vs.LNewObj()
vs.SetName(h_box, "box-visible")
vs.SetClass(h_box, "Rosetta-F3-Visible")
vs.NameClass("None")
vs.HideClass("Rosetta-F3-Hidden")
rosetta_save_reopen()
