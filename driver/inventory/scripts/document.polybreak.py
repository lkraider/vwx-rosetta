# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: document.polybreak
# family_id: document
# recipe_revision: 1
# recipe_path: recipes/document.polybreak.json
# recipe_sha256: 728018371eeef1f1b46ac5dddb2d6cd312a49cce4d7b92b307a73636c7b93694
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginPoly()
vs.AddPoint((0, 0))
vs.AddPoint((40, 0))
vs.AddPoint((40, 30))
vs.AddPoint((0, 30))
vs.ClosePoly()
vs.EndPoly()
h_pg = vs.LNewObj()
vs.SetName(h_pg, "poly-hidden-edge")
vs.SetVertexVisibility(h_pg, 1, False)
rosetta_save_reopen()
