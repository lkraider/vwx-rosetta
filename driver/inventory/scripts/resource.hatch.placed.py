# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: resource.hatch.placed
# family_id: resource.hatch
# recipe_revision: 1
# recipe_path: recipes/resource.hatch.placed.json
# recipe_sha256: 1b51bf487e208ac93bc6450b18ca37b9dff4eed1e57d1b895ef09f06116f03af
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/resource.hatch.placed.vwx
#   sha256 1e53142a7c90293e4dbff89fcca9fec50e0d4eca8878f22f356eeb59787ee8b1. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginVectorFillN("Rosetta-Hatch", False, False, 256)
vs.AddVectorFillLayer(0, 0, 1.5, 2.25, 0.25, -0.75, 1, 1, 257)
vs.AddVectorFillLayer(0, 0.5, -1.25, 3, 0.5, 0.125, 0.4, 2, 257)
vs.EndVectorFill()
vs.Rect((0, 20), (30, 0))
h_rh = vs.LNewObj()
vs.SetName(h_rh, "rect-hatched")
vs.SetVectorFill(h_rh, "Rosetta-Hatch")
rosetta_save_reopen()
