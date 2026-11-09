# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: entertainment.lighting_pipe.straight
# family_id: entertainment.lighting_pipe
# recipe_revision: 1
# recipe_path: recipes/entertainment.lighting_pipe.straight.json
# recipe_sha256: b1943de83055685eff339f5b5ff59496444029bd17b60665584a72d0669dac12
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_tr = vs.CreateCustomObject("Straight Truss", (0, 0), 0)
vs.SetName(h_tr, "truss-a")
rosetta_save_reopen()
