# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.spatial.6a273393b8fa
# family_id: solid.primitive
# recipe_revision: 2
# recipe_path: recipes/revisions/ix.spatial.6a273393b8fa.rev2.json
# recipe_sha256: 2e3e0b15739ae1ed5c130398bd0365bdb9744b55ddfe718a4436b06b4d0f560c
# base: driver/inventory/scripts/ix.spatial.6a273393b8fa.py
# native_verification: executed: driver/ui/make-sources.py batch 6, commit 2527225, wrote sources/ix.spatial.6a273393b8fa.vwx
#   sha256 552cf633ec9be1309113870e32178dbe59ddd74ba7ff66edac0168ad9f741b5a. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_cone = vs.CreateCone((8.5, -3.25, 1.75), (15, 6.5, 38.25), 9.75)
vs.SetName(h_cone, "cone-a")
vs.Move3DObj(h_cone, 40.5, -12.25, 7.75)
vs.NameClass("Rosetta-F3-Hidden")
vs.SetClass(h_cone, "Rosetta-F3-Hidden")
vs.NameClass("Rosetta-F3-Visible")
vs.BeginXtrd(0, 20)
vs.Rect((40, 12), (55, 0))
vs.EndXtrd()
h_box = vs.LNewObj()
vs.SetName(h_box, "box-visible")
vs.SetClass(h_box, "Rosetta-F3-Visible")
vs.Move3DObj(h_box, 40.5, -12.25, 7.75)
vs.NameClass("None")
vs.HideClass("Rosetta-F3-Hidden")
rosetta_save_reopen()
