# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: option.hatch.class_fill
# family_id: option.hatch
# recipe_revision: 1
# recipe_path: recipes/option.hatch.class_fill.json
# recipe_sha256: 0d9ee018c79e670bdf9025570e0f91aa1f8e228c9b53b3aabf1cf21a838e35e9
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginVectorFillN("Rosetta-Hatch", False, False, 256)
vs.AddVectorFillLayer(0, 0, 1.5, 2.25, 0.25, -0.75, 1, 1, 257)
vs.AddVectorFillLayer(0, 0.5, -1.25, 3, 0.5, 0.125, 0.4, 2, 257)
vs.EndVectorFill()
h_hi = vs.Name2Index("Rosetta-Hatch")
vs.NameClass("Rosetta-Hatched")
vs.SetClFPat("Rosetta-Hatched", -h_hi)
vs.NameClass("None")
vs.Rect((0, 20), (30, 0))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-class-hatch")
vs.SetClass(h_rc, "Rosetta-Hatched")
vs.SetFPatByClass(h_rc)
vs.Rect((40, 20), (70, 0))
h_rh = vs.LNewObj()
vs.SetName(h_rh, "rect-hatched")
vs.SetVectorFill(h_rh, "Rosetta-Hatch")
rosetta_save_reopen()
