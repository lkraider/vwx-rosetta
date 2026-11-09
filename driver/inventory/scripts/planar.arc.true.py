# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: planar.arc.true
# family_id: planar.arc
# recipe_revision: 1
# recipe_path: recipes/planar.arc.true.json
# recipe_sha256: 4d3cb69db2bd9a9e10605fb5d44167324457fac901d0d47ee0a088b66c31ccd4
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.ArcByCenter(31.25, 18.5, 12.75, 17.5, 233.25)
h_arc = vs.LNewObj()
vs.SetName(h_arc, "arc-true")
rosetta_save_reopen()
