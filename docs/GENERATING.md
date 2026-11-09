# How we generated Rosetta

We generated Rosetta with Vectorworks 2027 (32.1.0, build 885363) on macOS. A macOS user-interface driver opened
each document, ran the case's script, saved, reopened and exported it. The scripts and recipes are in
`driver/inventory/`; `ledger/intent.json` names the script and recipe of each case, with their sha256.

**We have not run the generators since they produced Rosetta.** We believe they still work, but we have not
re-validated them, nor the driver that ran them (in `driver/`). They need a licensed copy of Vectorworks.
docs/REPRODUCING.md says what the driver needs and how its parts fit; docs/WHY.md says why we captured this way.

## Exports and waits

- An export is complete when Vectorworks says so. A fixed quiet interval can accept a writer that paused, and
  the progress window of another task can end a wait early. So the driver accepted only the progress window titled
  `Exporting "<case>.vwx"` of the document it exported, and measured the file size after that window closed. For
  an exporter without a progress window, the driver waited until the size stayed the same for 1.5 s.
- Before every PDF export, a script fitted the page to the drawing and called `vs.ReDrawAll()`.
- A round trip DXF to DWG to DXF through another converter renames block names with trailing spaces; the DWG
  and DXF references here come from Vectorworks directly.
- `driver/EXPORT-VARIANCE.md` lists the fields that differ between two exports of the same source (the export
  dates, the GUIDs and the ACIS save time), and `driver/MANIFEST.md` how the exports were recorded.

## The vs.* bindings

Each case's script builds its objects through Vectorworks' Python bindings (`vs.*`). What we found:
- `vs.RGBToColorIndex(r, g, b)` returns a colour index.
- The active layer is shown at every layer visibility setting.
- A walk with `FIn3D` and a walk with `FInGroup` returned different objects.
- A volume label derived from the length unit was wrong; the unit preferences give the right one.
- Vectorworks keeps one Python interpreter between script runs. A file a script leaves open stays unflushed, and
  the application hides a script's exceptions, so scripts write their own error output.
- In one run the interpreter lost `builtins.open`, and later scripts could not write output until a restart.

## Calls that crashed Vectorworks or the Viewer

When run from a script sent from outside the application:
- `vs.ReDrawAll` and `vs.Layer` crashed Vectorworks (a read near null);
- `GetView`, `GetZoom`, `ModelPt2DToScreenPt`, `GetVPClassVisibility`, `GetVPLayerVisibility`, `Symbol` and
  `ShowClass` crashed the Vectorworks Viewer.
The driver selected saved views through the user interface instead. Crash reports (`.ips`) under
`~/Library/Logs/DiagnosticReports` hold the fault.
