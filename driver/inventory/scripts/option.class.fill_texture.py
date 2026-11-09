# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: option.class.fill_texture
# family_id: option.class
# recipe_revision: 1
# recipe_path: recipes/option.class.fill_texture.json
# recipe_sha256: 19c1ed106e670610ae146eb68169b7de3094322b03cc8cbfb69c739943d80229
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_tx = vs.CreateTexture()
vs.SetName(h_tx, "Rosetta-Texture")
h_ti = vs.Name2Index("Rosetta-Texture")
vs.NameClass("Rosetta-Fill")
vs.SetClFillFore("Rosetta-Fill", (0, 32768, 0))
vs.SetClFillBack("Rosetta-Fill", (0, 32768, 0))
vs.SetClFPat("Rosetta-Fill", 1)
vs.SetClTextureG("Rosetta-Fill", h_ti)
vs.SetClUseTexture("Rosetta-Fill", True)
vs.NameClass("None")
vs.Rect((0, 20), (30, 0))
h_rf = vs.LNewObj()
vs.SetName(h_rf, "rect-class-fill")
vs.SetClass(h_rf, "Rosetta-Fill")
vs.SetFillColorByClass(h_rf)
vs.SetFPatByClass(h_rf)
vs.NameClass("Rosetta-Fill")
vs.BeginXtrd(0, 12.5)
vs.Rect((40, 20), (70, 0))
vs.EndXtrd()
h_ex = vs.LNewObj()
vs.SetName(h_ex, "extrude-class-texture")
vs.NameClass("None")
rosetta_save_reopen()
