# Rosetta fixture recipe written in this repository for ROADMAP G3, BIM objects.
# case_id: building.space.rect
# family_id: building.space
# recipe_revision: 1
# recipe_path: recipes/building.space.rect.json
# recipe_sha256: 04f0dab4d426206d20130df7368cc53ac3b46b4531bd85d766ea17fa2c13aeaa
# native_verification: executed: driver/ui/make-sources.py batch g3-bim, commit db6e0bf, wrote sources/building.space.rect.vwx
#   sha256 7accc0fb60315b0047de99db810fee8d097a44b6d8df1413cdf7d2b1fb6c6657. Run 20261018T124746-script-stl exported that source.
# The capture adapter defines rosetta_checkpoint(id), rosetta_menu(*path) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((0, 4000), (5000, 0))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "space-boundary")
h_sp = vs.Space_CreateSpace(h_rc, 3000.0)
vs.SetName(h_sp, "space-a")
vs.ResetObject(h_sp)
rosetta_save_reopen()
