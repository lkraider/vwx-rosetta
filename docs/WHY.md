
# Why Rosetta Is Built This Way

## 1. Why a synthetic, SDK-mapped corpus exists

Real project drawings alone are not enough to test an independent reader or exporter for a proprietary CAD format:

1. **Real drawings are entangled and non-redistributable.** A production file combines dozens of object types, layer scales, class overrides, symbol nestings and legacy version migrations in a single document. Its license rarely allows public redistribution. When an exporter disagrees with a reference export on a complex building file, the error can sit in the primitive, the container transform, the layer elevation or the export dialog setting, and it is hard to tell which.
2. **A test suite written by the decoder author is circular.** When the same codebase defines the expected geometry and decodes the binary file, any misunderstanding of the file format is built into both sides. Ground truth must come from the reference application itself.
3. **Silent omissions look like passing tests.** An inventory that lists only the object types that are easy to construct drops unsupported or edition-gated object types from the denominator.

Rosetta therefore follows three rules:

- **Crosswalk-driven denominator.** We enumerated the object catalog from the reference application's SDK type codes and scripting API declarations before drawing any fixture. Every slot in the type system—planar primitives, spatial objects, NURBS curves and surfaces, Boolean and parametric solids, containers, annotations, resources, plug-in objects, and internal/reserved nodes—has an explicit disposition (`acquired`, `negative`, or out-of-scope structural bookkeeping).
- **One script, one sealed `.vwx`, many exports.** Every case starts from a deterministic Python recipe (`vs.*` calls) run in a blank document in Vectorworks 2027 (`32.1.0`, build `885363`). We seal the saved `.vwx` file by SHA-256 and then export it to the target formats and profiles.
- **Explicit negatives and inert measurements.** Rosetta records each outcome where the reference application refuses to create an object, blocks an export route with an alert, or writes a valid file header containing zero geometry.

## 2. Why these families and cases

### Single-mechanism baseline cases (`1:1` cases)

Most cases isolate a single object type or container mechanism in a clean document, so a disagreement with a reference export points at one mechanism. `docs/DESIGN.md` lists the families.

### Deliberate asymmetry in every recipe

Every baseline recipe uses **non-zero, non-integer, asymmetric coordinates, radii, heights, and angles**—for example, a rectangle from `(4.25, 11.5)` to `(37.75, 2.25)`, an extrude height of `31.25`, or a rotation of `27.5` degrees around an off-origin pivot. A reader that swaps X and Y, drops a Z elevation, misapplies a local-to-world matrix or confuses start and end angles gets shifted coordinates in the export.

Symmetric fixtures would hide these bugs. A cube centered at `(0, 0, 0)` with side length `10` has the same bounding box under axis swaps, sign flips, transpose errors and degree/radian mix-ups.

### Combined multi-object fixtures (`plugin.combined.*`)

In a combined fixture (`plugin.combined.01` through `plugin.combined.14`, with `.05a` and `.05ba`), each script places up to a dozen related objects in a single document. Each object gets its own named class and non-overlapping coordinates, so a downstream parser can still isolate every entity by layer/class name and bounding box. When a combined document caused an export failure, we bisected the batch until we isolated the offending object.

Combined fixtures cover the remaining SDK object types and the parametric plug-in objects. One document per object type for every format would have meant driving an interactive CAD application through hundreds of file opens and modal dialogs, which takes hours.

We also planned omnibus documents (multi-layer master documents with each case on its own design layer) and combined fixtures for the other families. The licence ended before we exported them, so no file in Rosetta comes from them.

## 3. Why pairwise interaction rows (`ix.*`)

A decoder that passes every single-object test can still fail when two features interact. Examples are a rotated polygon on an elevated layer in a document set to imperial units, or a hybrid 2D/3D symbol whose 3D component sits in a hidden class.

The `ix.*` cases are **strength-2 pairwise covering arrays** plus **curated higher-order mechanism cases**. They keep the interaction suite to 26 cases, where the full Cartesian product of document and container factors is too large to test:

- For planar geometry, six factors (`layer_type`, `elevation`, `class`, `transform`, `attributes`, `units`) with 2 to 4 levels each produce $2 \times 2 \times 3 \times 4 \times 2 \times 2 = 192$ combinations for a single polygon.
- For spatial geometry, five factors (`working_plane`, `elevation`, `transform`, `class`, `checkpoint`) produce $2 \times 2 \times 4 \times 3 \times 2 = 96$ combinations for a single cone.

The three groups:

1. **`ix.planar.*` (11 cases):** Built from `planar.polygon.asym`. Every pair of factor levels across layer type (design vs. sheet), layer elevation, class state (default, named visible, named hidden), 2D transform (none, move, rotate, mirror), graphic attributes, and units (metric vs. imperial) appears together in at least one case.
2. **`ix.spatial.*` (10 cases):** Built from `solid.cone.asym`. Every pair of factor levels across working plane (world vs. tilted), layer elevation, 3D transform (none, move, rotate, scale), class visibility, and save/reopen checkpointing appears together in at least one case.
3. **`ix.mech.*` (5 cases):** Hand-picked 3-way to 5-way combinations, which a pairwise (strength-2) array does not guarantee to include:
   - `ix.mech.nested-reflected-elevated-hidden`: a symbol inside a symbol, reflected across an axis, placed on an elevated design layer, with class overrides.
   - `ix.mech.hybrid-2d-3d-class-override`: a hybrid symbol with a 2D rectangle in a visible class and a 3D extrude in a hidden class. It tests whether 2D and 3D export routes filter components by view or by class.
   - `ix.mech.viewport-crop-annotation-visibility`: a sheet viewport with a crop, an annotation, a layer link source and a saved view.
   - `ix.mech.repeated-shared-distinct-metadata`: three instances of the same symbol definition carrying distinct attached record values and transforms.
   - `ix.mech.rational-surface-trim-hole-units`: a rational NURBS surface trimmed by a curve in non-default units.

The interaction cases also surfaced several subtle application behaviors, which `ledger/intent.json` records. For example, `vs.CreateCone` ignores a tilted working plane because it takes world coordinates; `vs.HScale3D` on a parametric cone is a no-op; and calling `vs.NameClass` before `vs.HideClass` leaves the hidden class active, and therefore visible, until another class becomes active.

## 4. Why these export formats and profiles

Cases are paired with profiles (`ledger/required-pairs.tsv`) by **what each format can distinguish**:

### CAD drawing formats (DXF and DWG)

DXF and DWG are the primary structural targets. They preserve layers, classes, block definitions, inserts, paper-space layouts, viewports, line weights, colors, hatches/fills, and embedded ACIS solids (`3DSOLID`).

Vectorworks organizes a drawing on two axes (Design Layers and Classes); DXF has a single-axis `LAYER` table. The export dialog decides which axis names the DXF layers, so Rosetta keeps profiles for both:

- With the dialog's default **Classes** mapping (`dxf.all-content`, `dwg.all-content`), Vectorworks names each DXF layer after the object's **class** (`None`, `Rosetta-Class`, etc.). It sets DXF flag `70 = 1` (frozen) on layers from hidden classes when "Export invisible classes" is enabled, and drops hidden design layers entirely.
- With the **Layers** mapping (`dxf.all-content.design-layers`), Vectorworks names each DXF layer after the **design layer** (`Design Layer-1`, `Rosetta-Layer-Elev`, etc.). In Vectorworks 2027, selecting the Layers radio button disables the "Export invisible classes" popup in the dialog. Hidden classes are therefore omitted, although the profile ID keeps the historical `all-content` prefix.
- With `dxf.top-plan`, the exporter switches the active view to Top/Plan and exports only visible design layers as flattened 2D plan graphics. Hybrid symbols and plug-in objects become `(2D)` blocks instead of `3DSOLID` entities.
- With `dxf.visible-only` and `dwg.visible-only`, invisible classes are set to "Not exported".

Single-option exports isolate the effect of individual checkboxes in the DXF/DWG export dialog without multiplying the whole corpus. They are extra files under `files/`, named `<case>.opt.<option>.dxf`; `ledger/manifest.json` does not list them as pairs. They exist for `plugin.combined.10`, `ix.mech.hybrid-2d-3d-class-override` and `annotation.viewport.sheet`, with the options `default`, `decompose-3d`, `decompose-plugins`, `fills-off`, `flattened-2d`, `groups-anon-blocks`, `hatches-off`, `indexed-colors` and `viewports-2d-model`. For example, toggling `groups-anon-blocks` renames `Group-*` blocks to anonymous `*U*` blocks with flag `70 = 1`, and toggling `fills-off` removes solid `HATCH` and `WIPEOUT` entities. Turning ACIS solids off is a manifest profile of its own, `dxf.all-content.acis-off`. It replaces `3DSOLID` entities with tessellated `POLYLINE`/`VERTEX` meshes.

### Solid B-rep formats (Parasolid `.x_t`, ACIS `.sat`, STEP `.step`, IGES `.igs`)

Parasolid (`parasolid.solids`) and ACIS (`sat.solids`) exports carry exact analytic surfaces (planes, cylinders, cones, spheres, tori, and B-splines) without mesh tessellation. They give an independent cross-check on solid geometry and unit scaling. Vectorworks uses the Parasolid kernel internally. STEP and IGES exports exist only as extra files under `files/`; the manifest lists no STEP or IGES pairs.

### Tessellated 3D mesh formats (OBJ, STL, 3DS, FBX, glTF)

Mesh formats (`obj.mesh`, `stl.binary.high-all`, `3ds.mesh`, `3ds.mesh.all-layers`, `fbx.mesh`, `gltf.mesh`) test how the application triangulates 3D surfaces, assigns material/texture companions (`.mtl`, `.png`, `.jpg`, `.bin`), and traverses symbol definitions and groups. OBJ, FBX and 3DS differ on the same container fixtures. 3DS tessellates 2D planar symbols and exports 3D loci as single-vertex records. OBJ and FBX ignore 2D planar geometry entirely; in the FBX dialog, the `Planar Objects` checkbox is permanently disabled.

### Visual, BIM, tabular, and downward-version formats (PDF, PNG, SVG, IFC, CSV, XLSX, VWX 2022-2026)

- **PDF (`pdf.vector`) and PNG (`png.top-plan`):** provide visual ground truth for 2D plan rendering, text layout, dimension arrows, and viewport cropping. `svg.vector` is in the manifest too, as 38 negative pairs (section 6.4). The `.jpg` files under `files/` are texture companions, not a profile.
- **IFC (`ifc.semantic`):** tests BIM semantic mapping (`IfcWall`, `IfcSlab`, `IfcDoor`, `IfcWindow`, `IfcCovering`, `IfcGeographicElement`) on architectural and site objects.
- **CSV (`csv.worksheet`) and XLSX (`xlsx.worksheet`):** meant to test worksheet export. Both pairs are negative, because no worksheet window existed to export from (`ledger/negatives.tsv`).
- **VWX 2022 to 2026 (`vwx.2022` ... `vwx.2026`):** the 2027 source document saved in an earlier file version (139 cases in 2023, 4 in each other year), so a reader can compare node layouts across format versions on identical geometry. These saves carry `VectorWorks <n>` in their header instead of `VW` tokens.

## 5. Why this capture method was used

### Why the scripting API alone could not drive Rosetta

A macOS Accessibility (`AXUIElement`) driver clicks through `File > Export` menus and modal dialogs. It is the only working route for 14 of the 16 formats. The SDK's Python binding file (`vs.py`, not included; `driver/sdk/README.md`) has working `vs.*` export functions for **only 2 of the 16 corpus formats**:

- `vs.ExportSTL(path, binary, exportAll)` for STL.
- `vs.ExportSAT(path,selectedOnly)` for SAT.

Twelve other formats (`DXF`, `DWG`, `OBJ`, `3DS`, `FBX`, `glTF`, `PDF`, `PNG`, `JPG`, `STEP`, `IGES`, and `CSV`) have no `vs.Export*` function in the scripting API. For two of the formats, the functions in `vs.py` fail or open UI dialogs:

- `vs.ExportPDFPages(baseName)` returns `False` on every design-layer and sheet-layer document unless a Publish set is configured.
- `vs.IFC_ExportWithUI(flag)` and `vs.IFC_ExportNoUI(name)` still open the native `Export IFC Project` dialog window.

### How scripts reach Vectorworks: the scripting AppleEvent, with Run Script as the fallback

Vectorworks accepts Python source from other processes through its scripting AppleEvent. The runner sends each case script that way (`native-script-send`, called by `run_script` in `driver/ui/make-sources.py`). It falls back to the menu command `Tools > Plug-ins > Run Script...` only when the send fails or is refused before it is sent. Two calls crashed Vectorworks when they ran inside an AppleEvent, both with a null pointer in the view-update path: `vs.ReDrawAll()`, and `vs.Layer()`, which switches the active layer. The case scripts avoid them, and the driver changes views and layers through the user interface instead (docs/GENERATING.md).

### How the save panel was made fast and background-safe

The driver exports without bringing Vectorworks to the front on every export and without writing temporary files into `~/Documents`:

1. **Dedicated scratch export folder via `Recent Places`:** The save panel's `Where:` popup points at a single pre-seeded scratch directory in `Recent Places`. This skips the `Go to Folder` sheet (`Cmd+Shift+G` in macOS `NSavePanel` sheets) on every pair and keeps all intermediate writes out of `~/Documents`.
2. **Direct Accessibility actions and PID-targeted events:** Reading only the targeted dialog fields (`--read-field`, `--read-enabled`, `--read-popup`) and dispatching `AXPress` actions reduced per-export UI overhead and minimized focus stealing.
3. **Memory-bounded restarts:** Repeated exports (especially PDF, IFC, and complex 3D solids) grow the application's resident memory until macOS or the process stalls. The driver monitors RSS between batches and restarts the application, which prevented mid-batch hangs. The restarts run under a single-process lock (`vw_lock.py`).

## 6. What failed and was changed during construction

Each change below explains a property of Rosetta as published. `ledger/manifest.json` and `ledger/negatives.tsv` record every course correction; the working repository's other provenance tables are not included.

### 1. Backfilled ledger lines and cached source paths

We sealed all source `.vwx` files, superseded revisions included, inside `sources/` of the working repository. Rosetta publishes the current revision of each. Every stored path in the ledger and manifest is relative to the repository root. `tools/install-artifact.py` is the sole writer to `files/`, `runs/` and `ledger/`, and it requires a run's `records.jsonl` to exist before any artifact is installed.

**Why:** In the earliest export batches, we reconstructed lines in the working repository's run ledger from run logs after the files were already on disk. This made `verify-artifacts.py` circular on those rows: it checked a file's SHA-256 against a ledger entry copied from the file itself. It also left the source map pointing at temporary scratch directories outside the repository.

### 2. Three empty source documents (`building.door.free`, `landscape.plant.single`, `entertainment.lighting_device.single`)

We re-recorded these three cases with revised recipes, because an object census found **zero objects** in their first source documents (`vs.Count('ALL') == 0.0`, walking every layer of the sealed `.vwx` sources inside Vectorworks):

- **`building.door.free`:** In a fresh document, `vs.CreateCustomObject('Door', ...)` opens a modal `Door Preferences` dialog. If that dialog is dismissed with `Cancel` (or times out), Vectorworks creates the `Door` record format (type 47) but returns a null object handle (`0`). Re-running the recipe and pressing `OK` on `Door Preferences` produced the type 86 Door plug-in object.
- **`landscape.plant.single`:** The universal plug-in name `'Plant'` is absent in Vectorworks Architect (`vs.GetLocalizedPluginName('Plant')` returns `(False, '')`). Probing the installed plug-in resources identified `'Foliage'` (`ExtFoliage`) as the working landscape plug-in. It generates a type 86 object.
- **`entertainment.lighting_device.single`:** The Spotlight plug-in `'Lighting Device'` is also absent in the Architect edition. The revised recipe calls `vs.CreateLight(14.25, 66.5, 18.0, 1, True, True)` (creating a type 81 Light object) and adds a 3D reference cone, so both light-aware and mesh-only routes have content to verify.

### 3. Mesh routes (`OBJ`, `FBX`, `3DS`, `glTF`) on 2D-only and point/curve fixtures

Every case on a mesh export profile (`obj.mesh`, `fbx.mesh`, `3ds.mesh`, `gltf.mesh`) contains explicit 3D surface geometry, so Rosetta has no empty mesh files. We first assigned cases to these profiles because their family carried a `3d` tag in the catalog. When `audit-corpus.py` and `inert-pairs.py` measured the resulting files, 10 of those cases had 0 vertices and 0 faces in OBJ and FBX. Their recipes drew only 2D planar primitives (`Rect`, `Oval`, `Locus`), a 3D locus, a NURBS curve, or a zero-slope roof.

**What changed:** We revised the 10 fixtures (their earlier revisions stayed in the working repository) and re-exported all affected pairs. The revisions add a 3D reference cone, extrude the 2D container shapes in the working copy, or set a non-zero roof pitch (`building.roof.two_edges`).

### 4. Unreachable `glTF` menu command and absent `SVG` exporter

- **SVG:** Vectorworks 2027 ships no `Export SVG` plug-in; the application bundle's `Plug-Ins/` directory has none. All 38 `svg.vector` pairs are permanent negatives (`format unavailable in Vectorworks 2027`).
- **glTF:** The `gltf.mesh` exports (with their `.bin` companion buffers) come from a menu command hidden from the shipped workspaces, which we unlocked without modifying the application bundle. The application's binary plug-in libraries include `Assimp Library.vwlibrary`. Its embedded `VWPluginLibraryResources.json` declares the menu command `Export glTF (3D only)...` with universal name `'Export glTF'` under the internal `'Debug'` category. Workspaces (`*.vww`) are plain XML files in the user profile folder. The driver copied `Architect.vww` to a temporary workspace (`Rosetta glTF.vww`) and inserted `<MenuItem UniversalName="Export glTF"/>`.

Neither command was reachable at first: the UI driver inspected the `File > Export` menu in all seven shipped workspaces (`Architect`, `Architect-BIM`, `Designer`, `Fundamentals`, `Landmark`, `Spotlight`, `Braceworks`), and neither `Export glTF` nor `Export SVG` appeared.

### 5. Faint hairline PDFs and off-center page layouts

`pdf.vector` (and `png.top-plan`) exports come from an adjusted working copy, not from the sealed source as saved. Before exporting, the driver runs a non-destructive pre-export script (`runs/<run_id>/pre/<case>.py`) on the open working copy in memory. The script raises every pen line weight below `10` mils (`0.254 mm`) to `10` mils and centers the view on the drawing bounds. The driver then closes the document with `Don't Save`. The sealed `.vwx` file under `sources/` stays unchanged, and the `working_copy` field of `ledger/manifest.json` declares every such adjustment.

**Why:** Rendered to PNG, several pages of the first `pdf.vector` batch were nearly blank (`< 0.05%` non-white pixels by `pdf-ink.py`). Default line weights rendered as 1-pixel hairlines, and drawings placed far from the page origin sat in a corner or outside the page frame.

### 6. `.jpg` files holding PNG bytes

`verify-artifacts.py` checks the magic bytes (`FF D8 FF` for JPEG, `89 50 4E 47` for PNG) of every image artifact, and the `jpg` route in `sweep-ui.py` selects `JPEG` in `popup/sibling/Format:` before pressing `Save`.

**Why:** Top-plan JPEG exports (a route outside the published profiles) produced files ending in `.jpg` that began with the 8-byte PNG signature (`89 50 4E 47`). In Vectorworks' `Export Image File` dialog, the `Format:` popup inside the dialog sets the output format, and it defaults to `PNG`. A `.jpg` filename typed in the save panel leaves the format as it is.

### 7. Trimmed rational NURBS surface rejected by every exporter

Case `ix.mech.rational-surface-trim-hole-units` has no reference export. Rosetta keeps the sealed source document and records all 14 export pairs in `ledger/negatives.tsv` as a documented application export defect (its one file is the document saved for 2023). We did not replace the surface with an untrimmed substitute.

The case creates a rational NURBS surface (object type 113) and trims it with `vs.TrimNurbsSurface`. The object exists in the `.vwx` document and shows in the Object Info palette with an enabled `Untrim` button. Yet `vs.CalcSurfaceArea` returns `null` (`Height: 0"`), and **every export route** (DXF, DWG, Parasolid, SAT, OBJ, STL, 3DS, FBX, glTF, PDF, PNG) either displays `There are no valid objects selected for export` or writes a file with zero entities/faces.

### 8. Export non-determinism across repeated runs

Two exports of the same `.vwx` document through the same profile differ in these fields (`driver/EXPORT-VARIANCE.md` for DXF and DWG):

- **DXF and DWG** write the export time into the creation and update dates (`$TDCREATE`, `$TDUCREATE`, `$TDUPDATE`, `$TDUUPDATE`), a new `$FINGERPRINTGUID`, a new GUID in each `3DSOLID`, and the save time in the ACIS data (`ACDSDATA`, group 310). Across the two pairs we compared, every handle, `$HANDSEED` included, and `$VERSIONGUID` stayed the same.
- **SAT and Parasolid** write the export timestamp into their file header (`Date:` / `DATE`).
- **FBX** writes `CreationTimeStamp` and `FileId`.
- **OBJ, STL, 3DS, and glTF** are deterministic when re-exported from the same open state.

Because of these fields, a tool that checks itself against Rosetta compares structure and content rather than bytes (CONTRACT.md). The SHA-256 digests in `ledger/manifest.json` verify that the stored reference files themselves are unaltered.
