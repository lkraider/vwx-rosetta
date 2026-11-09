# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.markers
# family_id: option.markers
# recipe_revision: 1
# recipe_path: recipes/option.markers.json
# recipe_sha256: 576654987f60ce4659a86a5d14dcc7cce4df9a40cbdb20deb2652b21fc211152
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.MoveTo((4.5, 6.25))
vs.LineTo((52.75, 23.5))
h_ln = vs.LNewObj()
vs.SetName(h_ln, "line-markers")
vs.SetObjBeginningMarker(h_ln, 1, 15, 0.125, 0.0625, 0, 0.05, True)
vs.SetObjEndMarker(h_ln, 2, 30, 0.1875, 0.125, 0, 0.05, True)
vs.ArcByCenter(33.5, 41.25, 11.75, 17.5, 143.25)
h_ar = vs.LNewObj()
vs.SetName(h_ar, "arc-markers")
vs.SetObjBeginningMarker(h_ar, 1, 15, 0.125, 0.0625, 0, 0.05, True)
vs.SetObjEndMarker(h_ar, 1, 15, 0.125, 0.0625, 0, 0.05, True)
rosetta_save_reopen()
