#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("export_settings", ROOT / "driver/export-settings.py")
export_settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export_settings)

LAYERS_MAPPING = '("radio/label/Export layers as DXF/DWG layers", "1", "classes_as_layers"),'


class ProfileLiteral(unittest.TestCase):
    def test_every_profile_is_in_the_profiles_literal(self):
        spec = importlib.util.spec_from_file_location("sweep_ui", export_settings.DRIVER)
        sweep_ui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sweep_ui)
        literal, _nodes = export_settings.assigned_formats(export_settings.DRIVER.read_text(encoding="utf-8"),
                                                           "PROFILES")
        self.assertEqual(literal, sweep_ui.PROFILES)


class DisabledControls(unittest.TestCase):
    def setUp(self):
        self.source = export_settings.DRIVER.read_text(encoding="utf-8")

    def test_disabled_control_is_recorded(self):
        rows = export_settings.build_table(self.source)
        disabled = {(row[0], row[3]) for row in rows if row[5] == "disabled by the layers mapping"}
        self.assertIn(("dxf.all-content.design-layers", "checkbox/label/Export invisible classes"), disabled)
        self.assertIn(("dxf.top-plan", "checkbox/label/Export invisible classes"), disabled)

    def test_state_override_is_recorded_with_its_reason(self):
        rows = export_settings.build_table(self.source)
        values = {row[5] for row in rows
                  if row[0] == "dxf.all-content.design-layers" and row[3] == "hidden_content"}
        self.assertEqual(values, {"as_saved: Export invisible classes is disabled under the layers mapping"})

    def test_profile_that_sets_a_disabled_control_fails(self):
        self.assertIn(LAYERS_MAPPING, self.source)
        source = self.source.replace(
            LAYERS_MAPPING,
            LAYERS_MAPPING + '\n        ("checkbox/label/Export invisible classes", "1", "hidden_content"),',
            1,
        )
        with self.assertRaisesRegex(ValueError, "Export invisible classes"):
            export_settings.build_table(source)


class CarriedState(unittest.TestCase):
    def test_all_content_clears_the_viewports_checkbox_before_the_classes_pane(self):
        literal, _nodes = export_settings.assigned_formats(export_settings.DRIVER.read_text(encoding="utf-8"),
                                                           "PROFILES")
        controls = [step[0] for step in literal["dxf.all-content"]["setup"]]
        viewports = controls.index("checkbox/label/Export viewports as 2D graphics in the model space")
        self.assertEqual(literal["dxf.all-content"]["setup"][viewports][1], "0")
        self.assertLess(viewports, controls.index("checkbox/label/Export invisible classes"))


if __name__ == "__main__":
    unittest.main()
