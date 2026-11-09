# How Rosetta is designed

README.md describes the files as they are. WHY.md gives the reasons for this design and what changed while we
built it.

## What completeness can mean

Rosetta claims complete accounting of the agreed inventory and measured results for its fixed cases. It does not
claim universal format coverage; that would need another authority, such as a complete specification and
conformance suite from the vendor. The claim rests on these distinctions:

- Catalog accounting covers every entry of a fixed inventory of object families. Each entry has a generated case
  or a recorded reason why it has none.
- Acquisition coverage counts the cases that have a valid native source and their required references. Reserved,
  unavailable and unsupported entries keep their own dispositions.
- Reader coverage counts the cases that a reader under test decodes, places and exports correctly. Exact,
  approximate and missing results stay separate.
- Compatibility is a vector: geometry, topology, world placement, visibility, appearance, resource links, metadata
  and document behaviour. A successful DXF export establishes only the properties DXF keeps.
- Editable round-trip compatibility (keeping native constraints, parametric behaviour and history) is a different
  goal from reading the file faithfully.
- A finite corpus cannot establish compatibility with every valid .vwx byte sequence, every parameter value,
  every future release or arbitrary third-party plug-ins.

## Fixture families

- Planar primitives: lines, loci, rectangles, rounded rectangles, ovals, arcs, polygons and polyline segment
  constructions.
- Annotation: dimensions and their standards, text, Unicode, linked text, leaders, callouts, markers and
  worksheets.
- Spatial primitives: 3D loci and polygons, extrudes, multiple extrudes, sweeps, meshes, NURBS curves and surfaces.
- Solid construction: Boolean trees, generic solids, fillets, chamfers, shells, lofts, trimmed surfaces, holes,
  disconnected components.
- Containers and occurrences: groups, symbol definitions, repeated and nested instances, hybrid symbols, plug-in
  instances.
- Building: walls, curtain walls, slabs, roofs, openings, doors, windows, stairs, spaces.
- Landscape and civil: site models, contours, hardscape, plants.
- Entertainment: lighting devices, truss, rigging and staging objects.
- Appearance and resources: classes, layers, colours, line types, hatches, tiles, gradients, image fills,
  textures, materials, text styles.
- Document behaviour: design and sheet layers, viewports, crops and annotations, saved views, units, origins,
  stories, references.
- Non-geometric content: record formats and attachments, worksheets, associations, embedded images.

Case names follow these families: `family.object.variant`, for example `annotation.dimension.angular`. Third-party
plug-ins are outside the inventory, because their code does not form a closed format.

## Coverage basis and combinations

Rosetta has one minimal case for each reachable family and each distinct construction or stored-representation
branch. Operations that give the same visible shape through different histories (an extrude, a Boolean solid, a
converted generic solid) get separate files.

The geometry is deliberately asymmetric. Distinct coordinates, edge lengths, heights and orientations expose
swapped axes, mirrored frames and wrong origins. Repeated same-shaped objects with distinct identities test
associations independently of geometric similarity.

The variants cover:
- geometry: open and closed topology, holes, disconnected pieces, planar and non-planar cases, rational weights,
  periodicity, seams, degree and knot patterns, reversed sense, documented degenerate boundaries;
- placement: translation, rotation, permitted scale and reflection, layer elevation, working planes, user
  origins, nested transforms;
- state: object, class, layer and ancestor visibility, grey state, inheritance, explicit overrides, clipping,
  saved views and viewports;
- document: metric and imperial units, writer versions, resource sharing, embedded and linked dependencies, name
  collisions, Unicode;
- plug-ins: documented branches that change child topology, components, clipping, 2D/3D content or parameter
  storage. Continuous dimensions use boundary and representative values.

The `ix.*` cases come from a constrained pairwise covering array over the applicable factors
(`ledger/covering/`). Pairwise coverage is an interaction strategy, and higher-order failures can remain. Explicit
higher-order cases cover known mechanisms, for example a nested instance with a reflected transform, a
layer elevation and a hidden ancestor, or a viewport crop with a sheet annotation and saved visibility.

## Controlled fixtures

- Each file tests one declared object family, representation or behaviour, with only the dependencies a valid
  document needs. Rosetta also keeps a
  blank-template control.
- A case maps explicitly to its primary object, its native measurements and the exported entities. One object
  can need many serialized records.
- Multiple-object cases exist only where they test interaction, occurrence identity, nesting or inheritance.
- Parameters, units and resource settings are explicit. Cases come from deterministic recipes
  (`driver/inventory/recipes/`, `driver/inventory/scripts/`), not from objects taken out of large documents.

## What was captured for each case

Each case has a permanent id and an explicit list of the references that apply to it, with the reason for each
one skipped. `ledger/intent.json` records the recipe and script (path and sha256), the objects and the parameters.

- The release and build (Vectorworks 2027, 32.1.0 build 885363), units and document settings.
- The `.vwx` source after save, close and reopen; we exported the references from the reopened state, so they
  correspond to the saved bytes.
- DWG and DXF exports, with model geometry and drawing or view-dependent output as different profiles.
- A second geometry representation where Vectorworks offers one: Parasolid and SAT for solids and surfaces, OBJ,
  STL, FBX, glTF and 3DS for meshes. A triangulated format is not a native solid reference.
- Fixed top/plan images (PNG), and PDF or SVG for planar drawing and annotation cases.
- IFC, and worksheet exports (CSV, XLSX), where they apply.
- The `.vwx` saved back to earlier file versions (2022 to 2026, and 2023 for most cases).

A world-space comparison must keep the object's translation and orientation. A centred-shape comparison cannot
validate placement. The references come from Vectorworks exports only. A reader under test may inspect a case but
must not produce the expected values for its own test.

## Export profiles

- Each profile has a stable id (for example `dxf.all-content`, `dxf.visible-only`, `dxf.top-plan`,
  `dxf.all-content.design-layers`, `dwg.all-content`, `png.top-plan`, `obj.mesh`), its option values, its
  document-state overrides and an applicability rule. `driver/EXPORT-VARIANCE.md` lists the fields that change
  between two exports of one source.
- An all-content profile records the original hidden state before it shows everything. A visible-only export and
  an all-content export are different reference channels.
- Profile-dependent changes ran on scratch copies. Every export is tied to its exact source, state and profile
  through hashes in `ledger/manifest.json`.
- Rosetta keeps raw exports even where no independent reader exists for their format yet.

Two exports of one source differ in the export dates, the GUIDs and the ACIS save time, and keep the same handles
(`driver/EXPORT-VARIANCE.md`). Byte inequality alone is not a geometry failure. A comparison normalizes only
non-semantic differences.

## On later Vectorworks releases

- Case ids, parameter values, construction histories and expected relationships live in versioned recipes, so a
  later release can regenerate Rosetta.
- Each new release gets fresh native files and references generated on it. Reopening and upgrading old files is a
  separate conversion test and does not replace them.
- Earlier corpora stay unchanged. Common cases are compared across releases. We report added, retired, renamed and
  changed families separately, and a changing denominator must not hide a regression.

## Assurance

- Every catalog entry has a disposition, and every case obligation has a reference or a recorded limitation.
- Hashes and recorded settings check source, state and export identity.
- Comparisons treat geometry and topology separately from metadata, placement, hidden state and appearance, with
  tolerances set before the comparison.
- Rosetta tracks remaining unknown record types and inaccessible families explicitly, and reports catalog
  accounting and acquisition separately from a reader's fidelity.

Rosetta stays useful without a Vectorworks licence. A missing native measurement stays an acquisition gap. A
metadata-only case cannot establish geometry agreement, and a mesh export cannot establish editable parametric
compatibility.
