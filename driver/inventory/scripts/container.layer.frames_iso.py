# Rosetta fixture recipe for question F1 of a .vwx reader's questions (FRAMES.md section 3).
# case_id: container.layer.frames_iso
# family_id: container.layer
# recipe_revision: 1
# recipe_path: recipes/container.layer.frames_iso.json
# recipe_sha256: cb647770914145eb57045f811d3c6fcecba1f8b4e93e55c91375458982a328e8
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_l1 = vs.CreateLayer("L1", 1)
vs.SetName(h_l1, "L1")
vs.Layer("L1")
vs.SetPref(94, False)
vs.BeginXtrd(0, 500)
vs.Rect((1000, 2500), (1500, 2000))
vs.EndXtrd()
h_bx = vs.LNewObj()
vs.SetName(h_bx, "frames-box")
vs.BeginSym("Rosetta-Frames-Sym")
vs.BeginXtrd(0, 300)
vs.Rect((0, 300), (300, 0))
vs.EndXtrd()
vs.EndSym()
vs.Symbol("Rosetta-Frames-Sym", (3000, 0), 0)
h_si = vs.LNewObj()
vs.SetName(h_si, "frames-sym")
vs.ClosePoly()
vs.BeginPoly()
vs.AddPoint((-1000, -4000))
vs.AddPoint((1000, -4000))
vs.AddPoint((1000, -2000))
vs.AddPoint((-1000, -2000))
vs.EndPoly()
h_pa = vs.LNewObj()
h_se = vs.CreateCustomObjectPath("Section-Elevation Marker", h_pa, None)
vs.SetName(h_se, "frames-section")
h_sl = vs.CreateLayer("Rosetta-Sheet", 2)
vs.SetName(h_sl, "Rosetta-Sheet")
vs.Layer("L1")
vs.DoMenuTextByName("Standard Views", 8)
rosetta_save_reopen()
