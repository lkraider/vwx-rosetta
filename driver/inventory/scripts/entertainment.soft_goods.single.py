# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: entertainment.soft_goods.single
# family_id: entertainment.soft_goods
# recipe_revision: 1
# recipe_path: recipes/entertainment.soft_goods.single.json
# recipe_sha256: b909792cfd1cd4fcaad475274b55104ecf6d83e491ad267b0008c9fa3d40989b
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.OpenPoly()
vs.BeginPoly()
vs.AddPoint((0, 0))
vs.AddPoint((6000, 0))
vs.EndPoly()
h_pa = vs.LNewObj()
h_sg = vs.CreateCustomObjectPath("Soft Goods", h_pa, None)
vs.SetName(h_sg, "soft-goods-a")
rosetta_save_reopen()
