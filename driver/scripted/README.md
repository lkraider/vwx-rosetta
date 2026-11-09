# Scripted export harness

Replaces the UI sweep runner (`../sweep.sh`) for export. One Python module runs inside Vectorworks, calls `vs.*` only, never clicks and never saves the document. Nothing here has run against the app. The binding read is SDK2026 stubs (`.../m3d-case-alias-review.U3MlbN/sdk/vs.py`); the installed app is 32.1.0 (2027). The wiki clone at `/Volumes/volxxxx/Caches/tmp/rosetta-inventory/research/src/developer-scripting` supplied the preference and menu appendices.

| File | Content |
|---|---|
| `routes.tsv` | One row per format: mechanism, exact signature, preference keys, missing evidence. |
| `exporter.py` | `export_case(case_id, out_dir, formats, ...)` returns one result dict per format. Includes framing. |
| `request.example.json` | Request for the in-app entry. |

## Routes by mechanism

- **Direct API, no dialog:** stl `ExportSTL`, sat `ExportSAT` (selection), ifc `IFC_ExportNoUI`, plus step `ExportSTEP` and iges `ExportIGES`.
- **Direct API, content read from worksheets:** xlsx (`EXL_*`), csv (Python `csv`, a reconstruction, not Vectorworks' writer). Needs worksheet names in the request.
- **Opens a modal, no documented keys to answer it:** dwg and dxf (`ExportDXFDWG()`, no arguments), pdf (`AcquireExportPDFSettingsAndLocation` is the first step of the lifecycle and asks the user), png (menu `Export Image File`). Without `allow_modal` the exporter reports `unsupported`. With it the exporter opens the modal and a human answers it. That is not automation and is not the default.
- **Unavailable:** obj, 3ds, fbx, parasolid (no export function; menu items exist with dialogs and unrecorded internal names), gltf and svg.

Correction to the premise: `ExportPDFPages` is not dialog-free. Its mandatory first call, `AcquireExportPDFSettingsAndLocation`, "asks the user for the Export PDF settings and the PDF file name".

gltf and svg: Vectorworks is not shown to write either. No function in the binding, no item among the 35 observed File > Export items. The binding is 2026 and the app is 2027, so the binding alone cannot exclude a 2027 addition. The observed 2027 menu does not list one.

## Framing (the dot-on-a-page fix)

The binding has no page-size setter, no print-area getter and no zoom-to-fit function. Levers that exist, and what `frame_drawing` calls:

| Purpose | Function | Unit |
|---|---|---|
| Extent | `vs.GetBBox(h)` per object (union), or `bbox_mm` from the request | document units; request is mm, converted with `vs.GetUnits()[3]` (units per inch) |
| Page extent | `vs.SetDrawingRect(paperWidth, paperHeight)` | document units |
| Scale | `vs.SetLScale(layer, 1.0)` on `vs.ActLayer()` | 1:1 so page units equal model units |
| View | `vs.SetVCenter(point)`, `vs.SetZoom(percent)`, `vs.DoMenuTextByName('Fit to Window', 0)` | document units, percent |

The rect is the case box plus 5 % of its longest side per edge, so a 100 mm object gets a 110 mm page, not A0. `vs.DrwSize(rows, columns)` (page count) is not called. The origin is not moved by default, because export coordinates would shift. Prior layer scale, rect size, zoom and view centre are restored after the run. The document is still modified in memory: close it without saving.

Unknowns in framing: (1) whether `SetDrawingRect` changes the PDF or DWG page, or only the drawing rect, since the paper size comes from Page Setup and no binding call sets it; (2) the rect position is not settable, so the exporter reads back `GetDrawingSizeRect`, records `bbox_inside_rect` and `verified`, and moves the origin only with `move_origin`; (3) `GetDrawingSizeRect` is described two ways (object area in the binding, printable page of the active layer in the wiki), so it is used only for read-back; (4) `'Fit to Window'` is a legacy selector from Appendix H, unverified on 2027, and `DoMenuTextByName` returns nothing; (5) `GetBBox` is a screen-plane projection, so it is a plan extent. Framing runs only when a framed format (dwg, dxf, pdf, png) is actually attempted.

## Command

Dry run, outside Vectorworks, prints the calls without writing anything:

```
python3 exporter.py --dry-run --case control.blank.mm --out /tmp/x --bbox-mm 0,0,100,100 \
  --formats stl,sat,ifc,obj,gltf,svg,dwg,pdf,csv --allow-modal
```

Live, the owner edits `request.example.json`, then runs this inside the app:

```python
import sys, importlib
sys.path.insert(0, '<abs path to>/corpus/scripted')
import exporter; importlib.reload(exporter)
exporter.run_request('<abs path to>/request.json')
```

Paste it into the Vectorworks Python script editor and run it (the exact menu path on 2027.1 is unverified here; the repo records none). Results are returned and written to `<out_dir>/results.json`.

Each result has `format`, `case_id`, `status` (`ok`, `failed`, `error`, `unsupported`, `skipped`, `dialog_shown`, `dry_run`), `route`, `path`, `bytes`, `api_return`, `detail`, `framing` and `calls`. `ok` needs a true return and a non-empty file. `dialog_shown` means the call has no return value, so the file must be checked by hand.

## Remaining unknowns

All of the "evidence still missing" column of `routes.tsv`, plus: the in-app launch path; whether Python file writes work in the app (csv, results.json); whether `GetBBox` and layer scale behave as assumed; and whether any run of this module has the intended effect, since none has run. Validation here was a read-through only, see the commit message.
