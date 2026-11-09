# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.opacity
# family_id: option.opacity
# recipe_revision: 1
# recipe_path: recipes/option.opacity.json
# recipe_sha256: ed3bc3949fbcd369ea491935fde71becb4669bee46b29c8662695db27138ce51
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((2.5, 21.25), (70.5, 4.5))
h_rb = vs.LNewObj()
vs.SetName(h_rb, "rect-under")
vs.SetFillBack(h_rb, (8738, 17476, 52428))
vs.Rect((10.25, 27.75), (31.5, 1.25))
h_ro = vs.LNewObj()
vs.SetName(h_ro, "rect-object-opacity")
vs.SetFillBack(h_ro, (61166, 13107, 4369))
vs.SetOpacityN(h_ro, 80, 40)
vs.NameClass("Rosetta-Half")
vs.SetCLOpacityN("Rosetta-Half", 30, 70)
vs.NameClass("None")
vs.Rect((44.75, 27.75), (63.25, 1.25))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-class-opacity")
vs.SetFillBack(h_rc, (61166, 13107, 4369))
vs.SetClass(h_rc, "Rosetta-Half")
vs.SetOpacityByClassN(h_rc, True, True)
rosetta_save_reopen()
