# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.fill.image_applied
# family_id: option.fill
# recipe_revision: 2
# recipe_path: recipes/option.fill.image_applied.json
# recipe_sha256: 52b7e0e73d5c9c9ffb78d2befc89bc5b52ee000d455c69ca56ced39437f99611
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
# The capture adapter defines rosetta_dependency(id). It returns the full path of the verified dependency file.
# dependency: bitmap.asym-png fixtures/bitmap-asym.png sha256 05e3c1edef9f6ecb99652505e6320b2568adbccd6a5d2c5d11bb389d7a78fe00
h_pt = vs.ImportImageFile(rosetta_dependency("bitmap.asym-png"), (-40, 10))
vs.SetName(h_pt, "bitmap-source")
h_im = vs.CreateImageFromPaint(h_pt, "Rosetta-Image")
vs.SetName(h_im, "Rosetta-Image")
ii = vs.Name2Index("Rosetta-Image")
vs.Rect((2.5, 21.25), (33.75, 4.5))
h_ra = vs.LNewObj()
vs.SetName(h_ra, "rect-image-ov")
vs.SetObjectVariableLongInt(h_ra, 695, -ii)
rosetta_save_reopen()
