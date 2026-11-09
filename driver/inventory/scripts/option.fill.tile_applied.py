# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.fill.tile_applied
# family_id: option.fill
# recipe_revision: 2
# recipe_path: recipes/option.fill.tile_applied.json
# recipe_sha256: f9e68e58abb594fd3ef2e64e4294d1f512cf78aea2f83c72923f2f4ba66f8634
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_tl = vs.CreateTile("Rosetta-Tile")
vs.SetName(h_tl, "Rosetta-Tile")
vs.Rect((0.5, 3.25), (4.75, 1))
h_tg = vs.LNewObj()
vs.SetName(h_tg, "tile-rect")
vs.AddTileGeometryObject(h_tl, h_tg)
ti = vs.Name2Index("Rosetta-Tile")
vs.Rect((2.5, 21.25), (33.75, 4.5))
h_ra = vs.LNewObj()
vs.SetName(h_ra, "rect-tile-ov")
vs.SetObjectVariableLongInt(h_ra, 695, -ti)
rosetta_save_reopen()
