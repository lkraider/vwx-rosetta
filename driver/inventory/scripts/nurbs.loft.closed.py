# Rosetta fixture recipe written in this repository for a .vwx reader, a solid of spline faces and planes.
# case_id: nurbs.loft.closed
# family_id: nurbs.loft
# recipe_revision: 1
# recipe_path: recipes/nurbs.loft.closed.json
# recipe_sha256: e87240494bf1740e94f47eab8d8d71a39c99e2b02c55e54f84bbabf5e9af2922
# native_verification: executed: driver/ui/make-sources.py batch g3-spline, commit ee268d5, wrote sources/nurbs.loft.closed.vwx
#   sha256 16e8325b5e722d86aa93acf2c0a87c53ae958bf82582c5baa2f9a7a0d84ce1a6. Run 20261018T133806-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginGroup()
h_pa = vs.CreateNurbsCurve((0, 0, 0), False, 3)
vs.SetName(h_pa, "profile-bottom")
vs.AddVertex3D(h_pa, (1000, -200, 0))
vs.AddVertex3D(h_pa, (1600, 400, 0))
vs.AddVertex3D(h_pa, (900, 1100, 0))
vs.AddVertex3D(h_pa, (100, 800, 0))
vs.AddVertex3D(h_pa, (0, 0, 0))
h_pb = vs.CreateNurbsCurve((200, 100, 1500), False, 3)
vs.SetName(h_pb, "profile-top")
vs.AddVertex3D(h_pb, (900, 0, 1500))
vs.AddVertex3D(h_pb, (1300, 500, 1500))
vs.AddVertex3D(h_pb, (800, 900, 1500))
vs.AddVertex3D(h_pb, (300, 700, 1500))
vs.AddVertex3D(h_pb, (200, 100, 1500))
vs.EndGroup()
h_g = vs.LNewObj()
h_lf = vs.CreateLoftSurfaces(h_g, False, False, True)
vs.SetName(h_lf, "loft-a")
vs.DelObject(h_g)
rosetta_save_reopen()
