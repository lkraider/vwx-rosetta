# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: spatial.tapered_extrude.single
# family_id: spatial.tapered_extrude
# recipe_revision: 1
# recipe_path: recipes/spatial.tapered_extrude.single.json
# recipe_sha256: 423c62c541ad42895205c7aa66ac56be396cc01da2a44a63d880941f6985cc0d
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((0, 600), (1000, 0))
h_pr = vs.LNewObj()
vs.SetName(h_pr, "profile-a")
h_tx = vs.CreateTaperedExtrude(h_pr, 5, 2000)
vs.SetName(h_tx, "tapered-a")
rosetta_save_reopen()
