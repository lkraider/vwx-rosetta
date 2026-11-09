# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: resource.class.visibility
# family_id: resource.class
# recipe_revision: 4
# recipe_path: recipes/revisions/resource.class.visibility.rev4.json
# recipe_sha256: bce4be52010b89abea6e39ea635a094d41c65137c7651686b70be85abe8da9fa
# base: driver/inventory/scripts/revisions/resource.class.visibility.rev3.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 2527225, wrote sources/resource.class.visibility.vwx
#   sha256 7741a3d5b0fef38ca4066beb78ef9b16a96d967e625f9da13da49c9ceebc5fd7. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Class-\u00c41")
vs.Rect((11.5, 26), (44.75, 9.25))
h_r = vs.LNewObj()
vs.SetName(h_r, "rect-classed")
vs.SetClass(h_r, "Rosetta-Class-\u00c41")
vs.NameClass("Rosetta-Class-B2")
vs.Oval((55, 26), (80, 9.25))
h_o = vs.LNewObj()
vs.SetName(h_o, "oval-visible")
vs.SetClass(h_o, "Rosetta-Class-B2")
vs.NameClass("None")
vs.HideClass("Rosetta-Class-\u00c41")
rosetta_save_reopen()
