# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.shell.dome
# family_id: solid.shell
# recipe_revision: 1
# recipe_path: recipes/solid.shell.dome.json
# recipe_sha256: dcb33698a2c9d51765fbd18a776f62827cc98e4c82437f05839760277465c20e
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ns = vs.CreateNurbsSurface(3, 3, 2, 2)
vs.SetName(h_ns, "nurbs-surface-a")
vs.NurbsSetPt3D(h_ns, 0, 0, (0, 0, 0))
vs.NurbsSetPt3D(h_ns, 0, 1, (10.5, -0.75, 6.25))
vs.NurbsSetPt3D(h_ns, 0, 2, (22, 0.5, 0))
vs.NurbsSetPt3D(h_ns, 1, 0, (-0.5, 9.75, 5.5))
vs.NurbsSetPt3D(h_ns, 1, 1, (10.75, 10.25, 15.5))
vs.NurbsSetPt3D(h_ns, 1, 2, (21.25, 11, 6.75))
vs.NurbsSetPt3D(h_ns, 2, 0, (0.25, 19.5, 0))
vs.NurbsSetPt3D(h_ns, 2, 1, (11.5, 20.75, 5.75))
vs.NurbsSetPt3D(h_ns, 2, 2, (22.75, 21.25, 0))
vs.NurbsSetWeight(h_ns, 1, 1, 0.5)
rosetta_checkpoint("before-shell")
h_sh = vs.CreateShell(h_ns, 1.25)
vs.SetName(h_sh, "shell-a")
rosetta_save_reopen()
