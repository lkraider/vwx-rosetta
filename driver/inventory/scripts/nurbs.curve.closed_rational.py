# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: nurbs.curve.closed_rational
# family_id: nurbs.curve
# recipe_revision: 1
# recipe_path: recipes/nurbs.curve.closed_rational.json
# recipe_sha256: bb49c3c7a7e92baef9e626cb60383802ead18734e58889b206b07405f3bd41f3
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_nc = vs.CreateNurbsCurve((3.25, 1.5, 0), True, 2)
vs.SetName(h_nc, "nurbs-closed-weighted")
vs.AddVertex3D(h_nc, (27.5, 2.75, 0))
vs.AddVertex3D(h_nc, (31.25, 19.5, 0))
vs.AddVertex3D(h_nc, (14.75, 26.25, 0))
vs.AddVertex3D(h_nc, (1.5, 17.75, 0))
vs.AddVertex3D(h_nc, (3.25, 1.5, 0))
vs.NurbsSetWeight(h_nc, 0, 1, 0.7071)
vs.NurbsSetWeight(h_nc, 0, 3, 1.75)
vs.ArcByCenter(52.5, 14.25, 9.75, 0, 360)
h_ci = vs.LNewObj()
h_cn = vs.ConvertToNURBS(h_ci, False)
vs.SetName(h_cn, "nurbs-from-circle")
rosetta_save_reopen()
