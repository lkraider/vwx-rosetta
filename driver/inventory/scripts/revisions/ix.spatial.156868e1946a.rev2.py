# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# The base calls rosetta_checkpoint("factor-mid"). The revision drops
# that call, because make-sources.py records no checkpoint and the call adds nothing to the document.
# case_id: ix.spatial.156868e1946a
# family_id: solid.primitive
# recipe_revision: 2
# recipe_path: recipes/revisions/ix.spatial.156868e1946a.rev2.json
# recipe_sha256: 3a478d8dfc46ca715def5b7c617bf488ab1539dcf4f907d7e8f8397e612467fe
# base: driver/inventory/scripts/ix.spatial.156868e1946a.py
# native_verification: executed: driver/ui/make-sources.py batch 7, commit 2527225, wrote sources/ix.spatial.156868e1946a.vwx
#   sha256 ce71ed754f729728231cacae0564da77c28fe8633d6ca887173620ec300e4b82. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_save_reopen() before running this file.
import vs
vs.SetWorkingPlaneN((120.5, -40.25, 15), (0, 0.6, 0.8), (1, 0, 0))
h_flay = vs.ActLayer()
vs.SetLayerElevation(h_flay, 640.75, 95.5)
h_cone = vs.CreateCone((8.5, -3.25, 1.75), (15, 6.5, 38.25), 9.75)
vs.SetName(h_cone, "cone-a")
vs.HScale3D(h_cone, 8.5, -3.25, 1.75, 1.5, 0.75, 1.25)
vs.NameClass("Rosetta-F3-Hidden")
vs.SetClass(h_cone, "Rosetta-F3-Hidden")
vs.NameClass("Rosetta-F3-Visible")
vs.BeginXtrd(0, 20)
vs.Rect((40, 12), (55, 0))
vs.EndXtrd()
h_box = vs.LNewObj()
vs.SetName(h_box, "box-visible")
vs.SetClass(h_box, "Rosetta-F3-Visible")
vs.HScale3D(h_box, 8.5, -3.25, 1.75, 1.5, 0.75, 1.25)
vs.NameClass("None")
vs.HideClass("Rosetta-F3-Hidden")
rosetta_save_reopen()
