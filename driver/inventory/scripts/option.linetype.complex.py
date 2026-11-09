# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.linetype.complex
# family_id: option.linetype
# recipe_revision: 1
# recipe_path: recipes/option.linetype.complex.json
# recipe_sha256: 3c5614e4894c3f4baf311eab5910dde00a5740b983ac6ae43706ab6349798ed7
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ls = vs.BuildResourceList(96, -174, "")[0]
vs.ImportResourceToCurrentFile(h_ls, 37)
vs.ImportResourceToCurrentFile(h_ls, 15)
lw = vs.Name2Index("Sine Wave")
lh = vs.Name2Index("Hot Water")
vs.MoveTo((0, 0))
vs.LineTo((100, 0))
h_ln = vs.LNewObj()
vs.SetName(h_ln, "line-sine-wave")
vs.SetLSN(h_ln, -lw)
vs.OpenPoly()
vs.BeginPoly()
vs.AddPoint((0, 20))
vs.AddPoint((40, 50))
vs.AddPoint((100, 30))
vs.EndPoly()
h_pl = vs.LNewObj()
vs.SetName(h_pl, "polyline-hot-water")
vs.SetLSN(h_pl, -lh)
rosetta_save_reopen()
