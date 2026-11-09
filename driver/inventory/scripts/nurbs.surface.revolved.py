# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: nurbs.surface.revolved
# family_id: nurbs.surface
# recipe_revision: 1
# recipe_path: recipes/nurbs.surface.revolved.json
# recipe_sha256: ca1f530c5ae08dd4b554275c79ed941b16aa89c775362548eaa5e296a676bd44
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSweep(0, 360, 7.5, 0)
vs.BeginPoly()
vs.AddPoint((6.25, 0))
vs.AddPoint((11.5, 4.75))
vs.AddPoint((8.25, 13.5))
vs.AddPoint((9.75, 19.25))
vs.OpenPoly()
vs.EndPoly()
vs.EndSweep()
h_sw = vs.LNewObj()
h_ns = vs.ConvertToNURBS(h_sw, False)
vs.SetName(h_ns, "nurbs-revolved")
rosetta_save_reopen()
