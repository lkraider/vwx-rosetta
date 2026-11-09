# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: annotation.bitmap.rotated_cropped
# family_id: annotation.bitmap
# recipe_revision: 1
# recipe_path: recipes/annotation.bitmap.rotated_cropped.json
# recipe_sha256: 890f20b5f5fc4963d4f111f4bc3476679c92accff0101c8926078cb927d58ec0
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
# The capture adapter defines rosetta_dependency(id). It returns the full path of the verified dependency file.
# dependency: bitmap.asym-png fixtures/bitmap-asym.png sha256 05e3c1edef9f6ecb99652505e6320b2568adbccd6a5d2c5d11bb389d7a78fe00
h_img = vs.ImportImageFile(rosetta_dependency("bitmap.asym-png"), (12.5, -7.25))
vs.SetName(h_img, "bitmap-rotated-cropped")
vs.ArcByCenter(12.5, -7.25, 2.75, 0, 360)
h_cr = vs.LNewObj()
vs.SetImageCropObject(h_img, h_cr)
vs.SetImageCropVisible(h_img, True)
vs.HRotate(h_img, (12.5, -7.25), 30)
rosetta_save_reopen()
