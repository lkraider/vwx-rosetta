# Rosetta fixture recipe written by driver/inventory/combined-sources.py from the plug-in probe.
# case_id: plugin.combined.14
# family_id: plugin.combined
# recipe_revision: 1
# recipe_path: recipes/plugin.combined.14.json
# recipe_sha256: fa6ad874f76b55411b2caff26070d374e606d868bf9578be74d68df21149cf85
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Layer("pio-Simple Stair")
vs.NameClass("pio-Simple Stair")
h_o00 = vs.CreateCustomObjectN("Simple Stair", (4970.4, -4970.4), 0, False)
vs.SetName(h_o00, "obj-00")
vs.Layer("pio-Custom Stair")
vs.NameClass("pio-Custom Stair")
h_o01 = vs.CreateCustomObjectN("Custom Stair", (14911.199999999999, -4970.4), 0, False)
vs.SetName(h_o01, "obj-01")
rosetta_save_reopen()
