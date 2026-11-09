# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: resource.class.attributes
# family_id: resource.class
# recipe_revision: 1
# recipe_path: recipes/resource.class.attributes.json
# recipe_sha256: caeb501ac289484c4c48f3bc8a282f43243620cb9bc538b6e30d03625ff83358
# native_verification: executed: driver/ui/make-sources.py batch g3, commit 09f2dbe, wrote sources/resource.class.attributes.vwx
#   sha256 63020c2945aced5c3ae21bbb5ae359258d67f66f991494125b0c3d2902d1722b. Run 20261018T094714-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.SetDashStyleN("Rosetta-Dash", False, 4, 0.1, 0.05, 0.02, 0.05)
lt = vs.Name2Index("Rosetta-Dash")
vs.NameClass("Rosetta-Red")
vs.SetClPenFore("Rosetta-Red", (65535, 0, 0))
vs.SetClLW("Rosetta-Red", 50)
vs.SetClLSN("Rosetta-Red", 2)
vs.NameClass("Rosetta-Blue")
vs.SetClPenFore("Rosetta-Blue", (0, 0, 65535))
vs.SetClLW("Rosetta-Blue", 10)
vs.SetClLSN("Rosetta-Blue", -lt)
vs.NameClass("None")
vs.Rect((0, 20), (30, 0))
h_rr = vs.LNewObj()
vs.SetName(h_rr, "rect-red")
vs.SetClass(h_rr, "Rosetta-Red")
vs.SetPenColorByClass(h_rr)
vs.SetLWByClass(h_rr)
vs.SetLSByClass(h_rr)
vs.Rect((40, 20), (70, 0))
h_rb = vs.LNewObj()
vs.SetName(h_rb, "rect-blue")
vs.SetClass(h_rb, "Rosetta-Blue")
vs.SetPenColorByClass(h_rb)
vs.SetLWByClass(h_rb)
vs.SetLSByClass(h_rb)
rosetta_save_reopen()
