# Rosetta fixture recipe revision written in this repository for ROADMAP G4. It places an object that uses the style.
# case_id: resource.wall_style.named
# family_id: resource.wall_style
# recipe_revision: 2
# recipe_path: recipes/revisions/resource.wall_style.named.rev2.json
# recipe_sha256: 04a2cbb20412227be8fca39229cb0fb75fc8d6192dda75237141776da161e383
# native_verification: executed: driver/ui/make-sources.py batch g4, commit 97fcf71, wrote sources/resource.wall_style.named.vwx
#   sha256 d1a1130a38cb7752bb5e297cc9357aae4b8da009ffb93686bc6dfc3ec81f35c9. Run 20261018T104155-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_wst = vs.CreateWallStyle("Rosetta-WallStyle")
vs.SetName(h_wst, "Rosetta-WallStyle")
vs.SetComponentWidth(h_wst, 1, 60)
vs.InsertNewComponentN(h_wst, 2, 140, 3, 0, 2, 2, 2, 2)
vs.Wall((0, 0), (300, 0))
h_w = vs.LNewObj()
vs.SetName(h_w, "wall-styled")
vs.SetWallStyle(h_w, "Rosetta-WallStyle", 0, 0)
rosetta_save_reopen()
