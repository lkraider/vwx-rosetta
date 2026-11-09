# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: annotation.text.multiline_styled
# family_id: annotation.text
# recipe_revision: 1
# recipe_path: recipes/annotation.text.multiline_styled.json
# recipe_sha256: 71e640d66b63303b1270719e2b4599939e81382ee593423dc91c8672b276fe8f
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.TextOrigin((17.25, 41.5))
vs.TextSize(12)
vs.CreateText("Rosetta one\rline two bold\rline three")
h_tx = vs.LNewObj()
vs.SetName(h_tx, "text-multiline")
vs.SetTextStyle(h_tx, 21, 4, 1)
vs.SetTextSize(h_tx, 12, 4, 24)
vs.SetTextJust(h_tx, 3)
rosetta_save_reopen()
