# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: entertainment.lighting_device.plugin
# family_id: entertainment.lighting_device
# recipe_revision: 1
# recipe_path: recipes/entertainment.lighting_device.plugin.json
# recipe_sha256: c2bea02e99e2b82aa30541361b9a8f530dc05b15a9d71db3a70f6e486c7c702a
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ld = vs.CreateCustomObjectN("Lighting Device", (0, 0), 0, False)
vs.SetName(h_ld, "lighting_device-a")
rosetta_save_reopen()
