# Rosetta fixture recipe written in this repository for ROADMAP G3, BIM objects.
# case_id: building.curtain_wall.straight
# family_id: building.curtain_wall
# recipe_revision: 1
# recipe_path: recipes/building.curtain_wall.straight.json
# recipe_sha256: 399aa526fc066ace18a69ac90ea03d819ef142c38dd956545163d609486258e4
# native_verification: executed: driver/ui/make-sources.py batch g3-bim, commit db6e0bf, wrote sources/building.curtain_wall.straight.vwx
#   sha256 7a91620bc957279f195b32824fefa41f9a08547f4cd53579d906e5464ac14e1b. Run 20261018T124746-script-stl exported that source.
# The capture adapter defines rosetta_checkpoint(id), rosetta_menu(*path) and rosetta_save_reopen() before running this file.
import vs
vs.Wall((0, 0), (4000, 0))
h_w = vs.LNewObj()
vs.SetName(h_w, "curtain-wall-a")
vs.SetIsCurtainWall(h_w, True)
vs.ResetObject(h_w)
rosetta_save_reopen()
