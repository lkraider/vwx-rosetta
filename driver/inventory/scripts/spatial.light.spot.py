# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: spatial.light.spot
# family_id: spatial.light
# recipe_revision: 1
# recipe_path: recipes/spatial.light.spot.json
# recipe_sha256: 77f35ab59e8354d9c1eaaaff2320f30d5f87fbec5461983e5110489bd3e65cf5
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_l0 = vs.CreateLight(4.5, -12.25, 41, 0, True, False)
vs.SetName(h_l0, "light-type-0")
vs.SetLightDirection(h_l0, 35, -50)
h_l1 = vs.CreateLight(24.75, -9.5, 33.5, 1, True, False)
vs.SetName(h_l1, "light-type-1")
vs.SetLightDirection(h_l1, 35, -50)
h_l2 = vs.CreateLight(47.25, -15.75, 29, 2, True, True)
vs.SetName(h_l2, "light-type-2")
vs.SetLightDirection(h_l2, 120, -65)
vs.SetLightFalloff(h_l2, 1, 2)
rosetta_save_reopen()
