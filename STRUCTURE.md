# Structure

How Rosetta's cases group, which node types each brings, and which node types real documents use.
`tools/structure.py` writes this page from `ledger/intent.json`, `ledger/nodetypes.tsv` and
`ledger/prevalence.tsv`.

A node is one record of a `.vwx` document's decoded stream, and its node type is a small number. A case's
node types are those of its source document, as a `.vwx` decoder reports them (`ledger/nodetypes.tsv`).
"Added" means over the blank control `control.blank.mm`, the empty document, which holds 31 node
types of its own.

## Reading layers

We propose this order for reading Rosetta; it is our reading and not yet confirmed. Each layer shows what its
cases add.

| layer | families | cases | node types its cases add, most cases first |
|---|---|---:|---|
| 1 document and containers | document, container, control | 30 | 76, 0, 3, 11, 24, 42, 2, 10 |
| 2 basic geometry | planar, solid, nurbs, spatial, extrude | 44 | 76, 114, 0, 42, 3, 24, 84, 113 |
| 3 annotation and resources | annotation, resource, option | 45 | 76, 3, 0, 11, 2, 10, 125, 63 |
| 4 parametric objects | building, landscape, entertainment | 25 | 76, 0, 11, 47, 48, 5, 21, 2 |
| 5 plug-ins | plugin | 16 | 0, 2, 5, 11, 42, 47, 48, 76 |
| pairwise interactions | ix | 26 | 76, 94, 0, 5, 85, 95, 3, 24 |

## Node types

Ranked by how many of 14 real Vectorworks documents (private; only these totals are published) hold the
type. The share of nodes is shown beside it and does not affect the rank, because one large object can hold most
of a document's nodes. "Comes with" is derived from the cases: among the native cases that create one kind of
object and add the type, the most common kind, with its ratio.

| node type | comes with | cases that add it | real documents holding it, of 14 | share of real nodes |
|---:|---|---:|---:|---:|
| 76 | shared (25 kinds) | 178 | 14 | 8.44% |
| 0 | shared (11 kinds) | 120 | 14 | 2.09% |
| 94 | polygon (4 of 6) | 47 | 14 | 0.01% |
| 47 | wall (4 of 8) | 43 | 14 | 0.02% |
| 48 | wall (4 of 8) | 43 | 14 | 0.20% |
| 119 | wall (2 of 3) | 40 | 14 | 0.10% |
| 31 | polygon (3 of 3) | 31 | 14 | 0.00% |
| 44 | polygon (3 of 3) | 27 | 14 | 0.00% |
| 124 | polygon (3 of 4) | 15 | 14 | 0.04% |
| 112 | polygon (3 of 4) | 14 | 14 | 0.00% |
| 69 | wall (3 of 5) | 13 | 14 | 0.01% |
| 107 | - | 1 | 14 | 0.00% |
| 127 | wall (1 of 1) | 1 | 14 | 0.00% |
| 33 | - | 0 | 14 | 0.00% |
| 54 | - | 0 | 14 | 0.00% |
| 55 | - | 0 | 14 | 0.00% |
| 57 | - | 0 | 14 | 0.00% |
| 74 | - | 0 | 14 | 0.00% |
| 78 | - | 0 | 14 | 0.00% |
| 79 | - | 0 | 14 | 0.00% |
| 80 | - | 0 | 14 | 0.00% |
| 88 | - | 0 | 14 | 0.00% |
| 6 | wall (1 of 1) | 23 | 13 | 0.04% |
| 77 | - | 0 | 13 | 0.00% |
| 102 | - | 0 | 12 | 0.00% |
| 2 | wall (4 of 8) | 55 | 11 | 0.54% |
| 21 | shared (5 kinds) | 39 | 11 | 0.27% |
| 26 | - | 2 | 11 | 0.00% |
| 27 | - | 2 | 11 | 0.00% |
| 28 | - | 2 | 11 | 0.00% |
| 43 | rectangle (1 of 1) | 2 | 11 | 0.00% |
| 70 | - | 2 | 11 | 0.00% |
| 65 | - | 0 | 11 | 0.00% |
| 3 | rectangle (5 of 8) | 93 | 8 | 0.08% |
| 11 | wall (4 of 8) | 79 | 8 | 0.26% |
| 10 | text (2 of 4) | 34 | 8 | 0.12% |
| 96 | shared (3 kinds) | 26 | 8 | 0.00% |
| 42 | shared (5 kinds) | 66 | 7 | 0.13% |
| 114 | shared (10 kinds) | 66 | 7 | 0.51% |
| 24 | extrude (2 of 4) | 61 | 7 | 0.11% |
| 5 | polygon (9 of 17) | 56 | 7 | 0.22% |
| 125 | dimension (1 of 1) | 39 | 7 | 0.08% |
| 86 | site model (1 of 2) | 32 | 7 | 0.03% |
| 17 | shared (4 kinds) | 30 | 7 | 0.04% |
| 91 | roof (2 of 3) | 26 | 7 | 0.07% |
| 16 | - | 19 | 7 | 0.02% |
| 97 | wall (1 of 1) | 7 | 7 | 0.01% |
| 92 | - | 1 | 7 | 0.00% |
| 93 | - | 0 | 7 | 0.01% |
| 66 | rectangle (1 of 1) | 3 | 6 | 0.00% |
| 30 | - | 0 | 6 | 0.00% |
| 84 | wall (4 of 7) | 36 | 5 | 0.09% |
| 15 | - | 17 | 5 | 0.17% |
| 25 | 3D polygon (1 of 1) | 7 | 5 | 0.18% |
| 101 | - | 4 | 5 | 0.10% |
| 19 | extrude (1 of 1) | 1 | 5 | 0.00% |
| 4 | shared (3 kinds) | 29 | 4 | 0.00% |
| 9 | site model (1 of 1) | 16 | 4 | 0.03% |
| 113 | NURBS surface (1 of 1) | 14 | 4 | 0.06% |
| 68 | wall (4 of 4) | 7 | 4 | 0.00% |
| 13 | rounded rectangle (1 of 1) | 5 | 4 | 0.00% |
| 40 | site model (1 of 2) | 4 | 4 | 1.56% |
| 41 | site model (1 of 2) | 4 | 4 | 83.86% |
| 14 | image (1 of 1) | 3 | 4 | 0.01% |
| 110 | - | 2 | 4 | 0.01% |
| 108 | - | 1 | 4 | 0.00% |
| 109 | text (1 of 1) | 1 | 4 | 0.00% |
| 123 | - | 0 | 4 | 0.00% |
| 63 | dimension (1 of 1) | 18 | 3 | 0.00% |
| 34 | sweep (2 of 2) | 16 | 3 | 0.00% |
| 111 | - | 11 | 3 | 0.08% |
| 121 | rectangle (1 of 1) | 6 | 3 | 0.32% |
| 122 | - | 5 | 3 | 0.00% |
| 71 | roof (2 of 2) | 4 | 3 | 0.00% |
| 49 | rectangle (1 of 1) | 2 | 3 | 0.00% |
| 51 | rectangle (1 of 1) | 2 | 3 | 0.00% |
| 100 | - | 2 | 3 | 0.01% |
| 103 | wall (1 of 1) | 1 | 3 | 0.01% |
| 104 | wall (1 of 1) | 1 | 3 | 0.00% |
| 105 | wall (1 of 1) | 1 | 3 | 0.00% |
| 116 | - | 1 | 3 | 0.00% |
| 81 | - | 3 | 2 | 0.00% |
| 18 | worksheet image (1 of 1) | 2 | 2 | 0.00% |
| 56 | worksheet image (1 of 1) | 2 | 2 | 0.00% |
| 62 | worksheet image (1 of 1) | 2 | 2 | 0.00% |
| 120 | - | 2 | 2 | 0.00% |
| 60 | - | 1 | 2 | 0.00% |
| 61 | - | 1 | 2 | 0.00% |
| 36 | - | 0 | 2 | 0.00% |
| 115 | - | 0 | 2 | 0.00% |
| 85 | cone (7 of 9) | 19 | 1 | 0.00% |
| 95 | cone (7 of 9) | 19 | 1 | 0.00% |
| 39 | - | 0 | 1 | 0.00% |
| 73 | - | 0 | 1 | 0.00% |
| 38 | multiple extrude (1 of 1) | 5 | 0 | - |
| 29 | - | 2 | 0 | - |
| 82 | roof (2 of 2) | 2 | 0 | - |
| 83 | roof (2 of 2) | 2 | 0 | - |
| 87 | roof (1 of 1) | 1 | 0 | - |

Node types in real documents and in no source here: 93 (7 of 14), 30 (6 of 14), 36 (2 of 14), 115 (2 of 14), 39 (1 of 14), 73 (1 of 14).
Node types in sources here and in no real document: 29, 38, 82, 83, 87.

## Cases

| case | family | kind | objects (intent) | calls (intent) | node types added |
|---|---|---|---|---|---|
| `annotation.bitmap.asym` | annotation | native | image | vs.ImportImageFile | 14 76 |
| `annotation.bitmap.rotated_cropped` | annotation | native | - | - | 0 6 11 14 76x7 |
| `annotation.callout.single` | annotation | plug-in | plug-in object | vs.CreateCustomObjectN | 0x2 11 47 48x2 76x9 86 |
| `annotation.dimension.angular` | annotation | native | line x2, dimension | vs.AngularDim, vs.LineTo | 0x2 2x2 6x2 10 11 63 76x7 125x2 |
| `annotation.dimension.associative` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 110x4 125x2 |
| `annotation.dimension.linear` | annotation | native | dimension | vs.LinearDim | 0x2 2x3 10 11 63 76x5 125x2 |
| `annotation.dimension.radial` | annotation | native | dimension x2, oval | vs.CircularDim, vs.Oval | 0x4 2x4 4 10x2 11x2 63x2 76x11 125x2 |
| `annotation.dimension.standard` | annotation | native | - | - | 0x2 2x3 10 11 63 76x5 125x2 |
| `annotation.dimension.units_1_1.cm` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `annotation.dimension.units_1_1.feet_inch` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `annotation.dimension.units_1_1.inch` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `annotation.dimension.units_1_1.m` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `annotation.dimension.units_1_1.mm` | annotation | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `annotation.sheet.multiple` | annotation | native | viewport x2, rectangle, oval | vs.CreateVP, vs.Oval, vs.Rect | 0x4 3 4 31x4 44 76x22 112x2 122x2 124x2 |
| `annotation.text.asym` | annotation | native | text | vs.CreateText | 10 76x2 |
| `annotation.text.multiline_styled` | annotation | native | - | - | 10 76x2 |
| `annotation.title_block.single` | annotation | native | - | - | 0x5 2x6 5x2 10x10 11x3 17 31 44 47x5 48x9 76x24 86 112 124 |
| `annotation.viewport.elevation` | annotation | native | extrude x2, viewport | vs.BeginXtrd, vs.CreateVP | 0x4 3x2 24x2 31x2 42x2 44 76x24 112 114x6 122 124 |
| `annotation.viewport.hidden_line` | annotation | native | - | - | 0x6 3x2 5x2 11x2 21x2 24x2 31x2 42x2 44 76x32 112 122x2 124 |
| `annotation.viewport.sheet` | annotation | native | rectangle, viewport | vs.CreateVP, vs.Rect | 0x2 3 31x2 44 76x10 112 122 124 |
| `annotation.worksheet.database` | annotation | native | - | - | 3x2 18 56 60 61 62 76x4 112 124 |
| `annotation.worksheet.formula` | annotation | native | worksheet image | vs.CreateWSImage | 18 56 62 76x2 112 |
| `building.column.free` | building | plug-in | plug-in object | vs.CreateCustomObject | 0x7 2x2 5 11x3 24 42 47x2 48x4 76x32 84x2 86 91x3 114x2 125x3 |
| `building.curtain_wall.straight` | building | native | wall | vs.Wall | 0x82 2x4 5 11x2 17x12 21x21 47 48x2 68 76x490 84x79 103x32 104x16 105 114x83 |
| `building.door.free` | building | plug-in | plug-in object | vs.CreateCustomObject | 0x19 2x19 3x4 5x8 6 11x13 17x5 24x5 42x5 47x4 48x8 76x83 86 91x5 94x3 96 97 114x2 119x2 |
| `building.roof.hip` | building | native | roof | vs.CreateRoof | 0x13 2x4 5x4 11x4 17x8 21x8 47x2 48x7 69x5 71x4 76x95 82 83 84x4 87 91x4 114x4 |
| `building.roof.two_edges` | building | native | roof | vs.CreateRoof | 0x7 2x4 5x2 11x2 17x11 21x4 47x2 48x5 69x3 71x2 76x65 82 83 84x2 91x2 114x2 |
| `building.roof_face.single` | building | native | - | - | 0 3 5 47 48x2 69 71 76x5 |
| `building.site_model.points` | building | native | site model | menu AEC > Terrain > Site Model from Source Data... | 0x10 5x7 9x6 10x5 11x5 17 21x14 24 40x2 41x11 42 47x4 48x7 76x91 86x2 96 119x2 |
| `building.slab.profile` | building | native | polygon, slab | vs.CreateSlab, vs.EndPoly | 0x3 11 21x2 26 27 28 47x2 48x4 69 70 76x15 84 86 100x5 114 |
| `building.space.rect` | building | native | rectangle, space | vs.Rect, vs.Space_CreateSpace | 0x19 3x4 5x3 9x16 10x7 11x13 16 17x16 21x4 24x2 42x2 47x4 48x9 76x149 86x3 94x3 114x2 119x2 124x2 |
| `building.stair.custom` | building | native | - | - | - |
| `building.stair.simple` | building | plug-in | plug-in object | vs.CreateCustomObject | 0x4 2x31 5x2 11x2 24 42 47x2 48x4 76x20 86 91 96 119x2 125x33 |
| `building.wall.curved` | building | native | - | - | 0x6 2x6 6x6 11x4 21x3 47 48x2 68 69 76x47 84 114x5 |
| `building.wall.joined_l_t` | building | native | - | - | 0x18 2x30 5x6 11x12 21x3 47 48x4 68x3 69x3 76x142 84x3 110x4 114x15 116x4 |
| `building.wall.straight` | building | native | wall | vs.Wall | 0x6 2x12 5x2 11x4 21 47 48x2 68 69 76x46 84 114x5 |
| `building.wall.with_door_window` | building | plug-in | plug-in object x2, wall | vs.CreateCustomObject, vs.Wall | 0x49 2x73 3x9 5x20 6 11x33 15x2 16x2 17x14 21x5 24x10 42x12 47x5 48x10 68 69 76x261 84 86x2 91x10 94x3 96x2 97 114x16 119x10 |
| `building.wall.with_door_window_plugins` | building | native | wall | vs.Wall | 0x72 2x111 3x29 5x26 6 11x40 17x14 21x9 24x26 42x30 47x7 48x14 68 69 76x331 84x3 86x2 91x24 94x3 96 97 114x31 119x4 |
| `building.window.free` | building | plug-in | plug-in object | vs.CreateCustomObject | 0x20 2x30 3x5 5x8 11x14 17x9 21x4 24x5 42x7 47x4 48x8 76x94 86 91x5 94x3 96 97 114x3 119x2 |
| `container.group.asym` | container | native | rectangle, oval, extrude, group | vs.BeginGroup, vs.BeginXtrd, vs.Oval, vs.Rect | 0x2 3x2 4 11 24 42 76x9 |
| `container.group.hidden_class_member_visible` | container | native | - | - | 0 3 4 11 76x7 94x2 |
| `container.layer.design_elevated` | container | native | rectangle, extrude | vs.BeginXtrd, vs.Rect | 0x2 3x2 24 31 42 76x10 |
| `container.layer.frames_base` | container | native | - | - | 0x18 2x3 3x5 6x3 10x2 11x10 15 16x3 21x4 24x2 31x2 42x2 44x2 47x2 48x7 76x89 86 101x2 112 114x4 119x6 124 125x3 |
| `container.layer.frames_iso` | container | native | - | - | 0x18 2x3 3x5 6x3 10x2 11x10 15 16x3 21x4 24x2 31x2 42x2 44x2 47x2 48x7 76x91 86 101x2 112 114x6 119x6 124 125x3 |
| `container.layer.hidden_design` | container | native | - | - | 0x3 3x2 4 24 31x2 42 76x16 |
| `container.layer.sheet_hidden_class` | container | native | - | - | 0 3 5 31 44 76x6 94x2 112 124 |
| `container.layer_link.design` | container | native | extrude, layer link | vs.BeginXtrd, vs.LayerRef | 0x3 3 24 29 31x2 42 76x18 114x3 |
| `container.symbol.def_instance` | container | native | rectangle, 2D locus, extrude, symbol instance | vs.BeginXtrd, vs.Locus, vs.Rect, vs.Symbol | 0x3 3x2 11 15 16 17 24 42 76x12 |
| `container.symbol.hidden_class_2d` | container | native | - | - | 0x2 3 4 11 15 16 76x12 94x2 119x2 |
| `container.symbol.hidden_class_3d` | container | native | - | - | 0x4 3 4 11 15 16 24x2 42x2 76x18 94x2 119x2 |
| `container.symbol.hybrid_hidden_2d` | container | native | - | - | 0x3 3x2 4 11 15 16 24 42 76x16 94x2 119x2 |
| `container.symbol.mirror_3d` | container | native | extrude x2, symbol instance | vs.BeginXtrd, vs.Symbol | 0x4 3x2 11 15 16 24x2 42x2 76x15 |
| `container.symbol.nested` | container | native | rectangle x2, symbol instance x2, oval | vs.Oval, vs.Rect, vs.Symbol | 0x4 3x2 4 11x2 15x2 16x2 76x17 |
| `container.symbol.nested_3d` | container | native | symbol instance x2, extrude | vs.BeginXtrd, vs.Symbol | 0x5 3 11x2 15x2 16x2 24 42 76x20 |
| `control.blank.imperial` | control | native | - | - | - |
| `control.blank.mm` | control | native | - | - | - |
| `document.georeference.epsg` | document | native | - | - | 76 |
| `document.layer_scale.1_1` | document | native | rectangle, dimension, text | vs.CreateText, vs.LinearDim, vs.Rect | 0x2 2x3 3 10x2 11 63 76x8 125x2 |
| `document.layer_scale.1_100` | document | native | rectangle, dimension, text | vs.CreateText, vs.LinearDim, vs.Rect | 0x2 2x3 3 10x2 11 63 76x8 125x2 |
| `document.layer_scale.1_50` | document | native | rectangle, dimension, text | vs.CreateText, vs.LinearDim, vs.Rect | 0x2 2x3 3 10x2 11 63 76x8 125x2 |
| `document.origin.offset` | document | native | 2D locus | vs.Locus | 17 76x2 |
| `document.polybreak` | document | native | - | - | 21 76x2 |
| `document.saved_view.named` | document | native | rectangle | vs.Rect | 0 3 43 49 51 76x3 124 |
| `document.units.cm` | document | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `document.units.feet_inch` | document | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `document.units.inch` | document | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `document.units.m` | document | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `document.units.mm` | document | native | rectangle, dimension | vs.LinearDim, vs.Rect | 0x2 2x3 3 10 11 63 76x6 125x2 |
| `document.working_plane.tilted` | document | native | 3D locus, extrude | vs.BeginXtrd, vs.Locus3D | 0 3 9 24 42 76x5 |
| `entertainment.lighting_device.plugin` | entertainment | native | - | - | - |
| `entertainment.lighting_device.single` | entertainment | plug-in | plug-in object | vs.CreateCustomObject | 0x3 3x2 4 11 15 16 24 42 76x13 81 |
| `entertainment.lighting_pipe.straight` | entertainment | native | - | - | - |
| `entertainment.seating_section.single` | entertainment | native | - | - | 0x7 2x10 11x5 15x120 16 21 47x3 48x125 76x30 86 94 119x2 125x2 |
| `entertainment.soft_goods.single` | entertainment | native | - | - | 5 76x2 |
| `extrude.asym` | extrude | native | - | - | 0 5 24 42 76x8 114x3 |
| `ix.mech.hybrid-2d-3d-class-override` | ix | native | extrude x2, rectangle, symbol instance | vs.BeginXtrd, vs.Rect, vs.Symbol | 0x4 3x2 4 11 15 16 24x2 42x2 76x19 94x3 |
| `ix.mech.nested-reflected-elevated-hidden` | ix | native | extrude x2, symbol instance x2, rectangle, 2D locus | vs.BeginXtrd, vs.Locus, vs.Rect, vs.Symbol | 0x7 3x3 11x2 15x2 16x2 17 24x2 31 42x2 76x31 94x2 |
| `ix.mech.rational-surface-trim-hole-units` | ix | native | NURBS curve x2, NURBS surface | vs.CreateNurbsCurve, vs.CreateNurbsSurface | 76x5 111x2 113 |
| `ix.mech.repeated-shared-distinct-metadata` | ix | native | symbol instance x3, rectangle, 2D locus, extrude | vs.BeginXtrd, vs.Locus, vs.Rect, vs.Symbol | 0x3 3x2 11 15x3 16 17 24 42 47 48x4 76x14 |
| `ix.mech.viewport-crop-annotation-visibility` | ix | native | extrude, layer link, viewport, rectangle, text | vs.BeginXtrd, vs.CreateText, vs.CreateVP, vs.LayerRef, vs.Rect | 0x7 3x2 10 11x2 24 29 31x3 42 43 44 49 51 76x24 112 122 124x2 |
| `ix.planar.08a344dc9f96` | ix | native | polygon, oval | vs.EndPoly, vs.Oval | 4 5 76x5 94x2 |
| `ix.planar.18e402f11398` | ix | native | polygon | vs.EndPoly | 5 76x3 94 |
| `ix.planar.4c9fe9c05a47` | ix | native | polygon | vs.EndPoly | 5 76x2 |
| `ix.planar.7108ea3f547f` | ix | native | polygon, oval | vs.EndPoly, vs.Oval | 4 5 76x5 94x2 |
| `ix.planar.76a55dfa0e99` | ix | native | polygon | vs.EndPoly | 5 76x3 |
| `ix.planar.939badf6bd41` | ix | native | polygon | vs.EndPoly | 5 76x2 |
| `ix.planar.acdd57e27bec` | ix | native | polygon | vs.EndPoly | 0 5 31 44 76x4 112 124 |
| `ix.planar.b592862becd2` | ix | native | polygon | vs.EndPoly | 0 5 31 44 76x5 94 112 124 |
| `ix.planar.b88144920570` | ix | native | polygon | vs.EndPoly | 5 76x3 94 |
| `ix.planar.c16429abac1c` | ix | native | polygon | vs.EndPoly | 0 5 31 44 76x6 94 112 124 |
| `ix.planar.d064e8d18eb2` | ix | native | polygon, oval | vs.EndPoly, vs.Oval | 4 5 76x5 94x2 |
| `ix.spatial.156868e1946a` | ix | native | cone, extrude | vs.BeginXtrd, vs.CreateCone | 0 3 24 42 76x8 85 94x2 95 |
| `ix.spatial.162f3d3ad09e` | ix | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `ix.spatial.1a3ba3f36c82` | ix | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `ix.spatial.479efd6c5e84` | ix | native | cone | vs.CreateCone | 76x6 85 95 114x3 |
| `ix.spatial.6a273393b8fa` | ix | native | cone, extrude | vs.BeginXtrd, vs.CreateCone | 0 3 24 42 76x8 85 94x2 95 |
| `ix.spatial.6f0844765639` | ix | native | cone, extrude | vs.BeginXtrd, vs.CreateCone | 0 3 24 42 76x8 85 94x2 95 |
| `ix.spatial.7f9b5bd253be` | ix | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `ix.spatial.9f0fd0f5c94a` | ix | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `ix.spatial.ac39b9ac7ebb` | ix | native | cone, extrude | vs.BeginXtrd, vs.CreateCone | 0 3 24 42 76x8 85 94x2 95 |
| `ix.spatial.d26473bbb730` | ix | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `landscape.hardscape.single` | landscape | native | - | - | 0x6 5x3 11x3 21x2 24 40 41x8 42 47x2 48x4 69x4 76x60 86 94x5 96 119x2 121x3 |
| `landscape.plant.plugin` | landscape | native | - | - | - |
| `landscape.plant.single` | landscape | plug-in | plug-in object | vs.CreateCustomObject | 0x3 4x2 11 15 16 24 42 76x12 |
| `nurbs.curve.closed_rational` | nurbs | native | - | - | 76x2 111x2 114x2 |
| `nurbs.curve.cubic` | nurbs | native | NURBS curve, extrude | vs.BeginXtrd, vs.CreateNurbsCurve | 0 3 24 42 76x5 111 |
| `nurbs.from_conversion.extrude` | nurbs | native | extrude, NURBS | vs.BeginXtrd, vs.ConvertToNURBS | 0x2 3 11 24 42 76x46 111x6 113x6 114x27 |
| `nurbs.loft.closed` | nurbs | native | loft | vs.CreateLoftSurfaces | 0 76x6 84 114x3 |
| `nurbs.surface.rational` | nurbs | native | NURBS surface | vs.CreateNurbsSurface | 76x6 113 114x3 |
| `nurbs.surface.revolved` | nurbs | native | - | - | 0 11 76x21 111x5 113x3 114x14 |
| `option.class.fill_texture` | option | native | - | - | 0 3x2 24 42 76x10 91 94 97 114x3 119x2 |
| `option.drop_shadow` | option | native | - | - | 3 5 76x3 101x2 |
| `option.fill.gradient_applied` | option | native | - | - | 3 76 119x2 120 121 |
| `option.fill.image_applied` | option | native | - | - | 3 14 76x2 119x3 121 |
| `option.fill.texture_on_extrude` | option | native | - | - | 0x3 3x2 24x2 42x2 76x21 84 85 91x2 95 97 114x7 119x2 |
| `option.fill.tile_applied` | option | native | - | - | 0 3x2 11 76x6 108 119x2 121 |
| `option.hatch.class_fill` | option | native | - | - | 3x2 66 76x3 94 119x2 121x2 |
| `option.linetype.complex` | option | native | line, polygon | vs.EndPoly, vs.LineTo | 0x2 2x3 5 10 11x2 17 21 76x17 96x2 119x4 |
| `option.markers` | option | native | - | - | 2 6 76x2 125x2 |
| `option.opacity` | option | native | - | - | 3x3 76x4 94 |
| `option.pen_fill_colour` | option | native | - | - | 3x2 5 76x5 94 |
| `planar.arc.asym` | planar | native | arc | vs.Arc | 21 76 |
| `planar.arc.true` | planar | native | - | - | 6 76 |
| `planar.circle.asym` | planar | native | - | - | 6 76 |
| `planar.line.asym` | planar | native | line | vs.LineTo | 2 76 |
| `planar.locus.asym` | planar | native | 2D locus | vs.Locus | 17 76 |
| `planar.oval.asym` | planar | native | oval | vs.Oval | 4 76 |
| `planar.polygon.asym` | planar | native | polygon | vs.EndPoly | 5 76x2 |
| `planar.polygon.from_polyline` | planar | native | polyline, polygon | vs.ConvertToPolygon, vs.EndPoly | 5 21 76x4 |
| `planar.polyline.asym` | planar | native | polyline | vs.EndPoly | 21 76x2 |
| `planar.rect.asym` | planar | native | rectangle | vs.Rect | 3 76 |
| `planar.rrect.asym` | planar | native | rounded rectangle | vs.RRect | 13 76 |
| `plugin.combined.01` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x139 2x27 3x6 4 5x27 6x3 9x18 11x41 17x2 21x27 24x13 31x30 34x11 42x28 44 47x32 48x67 76x620 84x14 86x30 91x13 94x30 96 114x30 119x2 125x71 |
| `plugin.combined.02` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x121 2x21 3x3 5x18 6x3 9x6 11x41 17 21x24 24x10 31x30 34x2 42x16 44 47x32 48x66 76x566 84x8 86x30 91x16 94x30 96 114x30 119x2 125x55 |
| `plugin.combined.03` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x119 2x29 3x5 5x14 9x4 11x40 21x27 24x4 31x30 34x8 42x14 44 47x32 48x72 76x565 84x7 86x30 91x12 94x30 96x2 114x30 119x4 125x65 |
| `plugin.combined.04` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x126 2x47 3x4 5x29 6x5 9 11x45 17 21x11 25x6 31x30 34x8 42x9 44 47x31 48x70 76x575 84x13 86x30 91x21 94x30 96 114x32 119x2 125x87 |
| `plugin.combined.05a` | plugin | plug-in | plug-in object x15 | vs.CreateCustomObjectN | 0x67 2x20 3x10 5x18 9x2 11x24 17x2 21x10 24x2 31x15 34x6 42x11 44 47x16 48x35 76x344 84x5 86x15 91x17 94x15 96 111x2 113x8 114x36 119x2 125x48 |
| `plugin.combined.05ba` | plugin | plug-in | plug-in object x13 | vs.CreateCustomObjectN | 0x52 2x13 3 5x6 9x3 11x22 21x14 24 31x13 34x2 42x4 44 47x16 48x33 76x253 84 86x13 91x3 94x13 96 114x8 119x2 125x24 |
| `plugin.combined.06` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x131 2x60 3x9 5x24 6x6 9x2 11x49 13x2 17x10 21x47 24x3 31x30 34x12 42x16 44 47x32 48x69 76x645 84x7 86x30 91x20 94x30 96 114x44 119x2 125x121 |
| `plugin.combined.07` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x128 2x12 3x9 5x28 6x3 9x4 11x47 13 17x7 21x71 24x4 31x30 34x8 42x14 44 47x33 48x67 76x670 84x9 86x30 91x16 94x30 96x2 111x2 113x3 114x47 119x4 125x106 |
| `plugin.combined.08` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x136 2x32 3x9 4x2 5x29 6x23 9x7 11x46 17x2 21x43 24x18 31x30 34x7 38 42x30 44 47x33 48x69 76x698 84x4 86x30 91x26 94x30 96x2 114x64 119x4 125x94 |
| `plugin.combined.09` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x164 2x33 3x3 4x2 5x16 6x38 9x7 10 11x47 13 17x8 21x66 24x35 31x30 34x12 42x54 44 47x33 48x67 76x854 84x10 86x30 91x50 94x30 96x2 111x2 113x3 114x108 119x4 125x104 |
| `plugin.combined.10` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x162 2x53 3x38 4x3 5x38 6x28 10x10 11x52 17 21x32 24x38 25x20 31x30 34x4 38x7 42x52 44 47x37 48x90 76x756 84 86x30 91x66 94x30 96x5 113 114x12 119x10 125x124 |
| `plugin.combined.11` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x157 2x76 3x44 4x3 5x29 6x7 9x11 10x32 11x46 17x3 21x10 24x46 25x10 31x30 38x4 42x58 44 47x38 48x86 76x703 84 86x30 91x56 94x31 96x3 114 119x6 125x124 |
| `plugin.combined.12` | plugin | plug-in | plug-in object x30 | vs.CreateCustomObjectN | 0x247 2x71 3x96 4x20 5x186 6x10 9 10x44 11x53 13x7 17x11 21x14 24x119 25x72 31x30 34x9 38x5 42x166 44 47x41 48x86 76x1227 84 86x30 91x204 94x31 96 114x3 119x2 125x276 |
| `plugin.combined.13` | plugin | plug-in | plug-in object x20, polygon x9 | vs.CreateCustomObjectN, vs.CreateCustomObjectPath, vs.EndPoly | 0x123 2x15230 3x37 4 5x41 6x1013 10x24 11x46 15x289 16x3 17 21x19 24x33 25x8 31x20 34 42x34 44 47x27 48x61 76x1005 86x20 91x242 94x23 96x5 101x3 113x208 119x16 125x15274 |
| `plugin.combined.14` | plugin | plug-in | plug-in object x2 | vs.CreateCustomObjectN | 0x38 2x49 5x50 10 11x3 24x31 25x28 31x2 42x31 44 47x3 48x7 76x206 86x2 91x59 94x2 96 119x2 125x99 |
| `plugin.hidden_class` | plugin | plug-in | - | - | 0x94 2x53 3x84 5x14 6 11x22 17x5 21x4 24x67 42x77 47x6 48x14 76x332 84x2 86x3 91x65 94x4 96x2 97 114x16 119x6 |
| `resource.class.attributes` | resource | native | rectangle x2 | vs.Rect | 3x2 76x4 94x2 96 |
| `resource.class.visibility` | resource | native | rectangle, oval | vs.Oval, vs.Rect | 3 4 76x5 94x2 |
| `resource.folder.symbol` | resource | native | rectangle, 2D locus | vs.Locus, vs.Rect | 0x3 3 11 16 17 76x9 92 119x2 |
| `resource.gradient.three_stop` | resource | native | - | - | 120 |
| `resource.hatch.placed` | resource | native | rectangle | vs.Rect | 3 66 76 121 |
| `resource.hatch.two_layer` | resource | native | - | - | 66 |
| `resource.linetype.dashed` | resource | native | line, rectangle | vs.LineTo, vs.Rect | 2 3 76x2 96 |
| `resource.material.simple` | resource | native | extrude | vs.BeginXtrd | 0 3 19 24 42 76x4 |
| `resource.record.attached` | resource | native | rectangle | vs.Rect | 3 47 48x2 76 |
| `resource.slab_style.named` | resource | native | polygon, slab | vs.CreateSlab, vs.EndPoly | 0x3 11 21x2 26x2 27x2 28x2 47x2 48x4 69x2 70x2 76x17 84 86 100x4 107 114 119x2 |
| `resource.text_style.applied` | resource | native | text | vs.CreateText | 10 76 109 |
| `resource.wall_style.named` | resource | native | wall | vs.Wall | 0x7 2x22 5x3 11x4 21 47 48x2 68 69x2 76x69 84x2 114x10 119x2 127 |
| `solid.cone.asym` | solid | native | cone | vs.CreateCone | 76x5 85 95 114x3 |
| `solid.csg.add` | solid | native | extrude, sphere, solid addition | vs.AddSolid, vs.BeginXtrd, vs.CreateSphere | 0x2 3 24 42 76x12 84 85 95 114x4 |
| `solid.csg.intersect` | solid | native | extrude, sphere, solid intersection | vs.BeginXtrd, vs.CreateSphere, vs.IntersectSolid | 0x2 3 24 42 76x12 84 85 95 114x4 |
| `solid.csg.subtract` | solid | native | extrude, sphere, solid subtraction | vs.BeginXtrd, vs.CreateSphere, vs.SubtractSolid | 0x2 3 24 42 76x12 84 85 95 114x4 |
| `solid.cylinder.subtract_sphere` | solid | native | extrude, sphere, solid subtraction | vs.BeginXtrd, vs.CreateSphere, vs.SubtractSolid | 0x2 4 24 42 76x12 84 85 95 114x4 |
| `solid.extrude.circle` | solid | native | extrude | vs.BeginXtrd | 0 4 24 42 76x7 114x3 |
| `solid.generic.from_csg` | solid | native | extrude, sphere, solid subtraction, generic solid | vs.BeginXtrd, vs.CnvrtToGenericSolid, vs.CreateSphere, vs.SubtractSolid | 0 76x6 84 114x3 |
| `solid.hemisphere.tilted` | solid | native | hemisphere | vs.CreateHemisphere | 76x5 85 95 114x3 |
| `solid.shell.dome` | solid | native | NURBS surface, shell solid | vs.CreateNurbsSurface, vs.CreateShell | 0 76x9 84 113 114x4 |
| `solid.shell.surface` | solid | native | NURBS surface, shell solid | vs.CreateNurbsSurface, vs.CreateShell | 0 76x9 84 113 114x4 |
| `solid.sphere.offset` | solid | native | sphere | vs.CreateSphere | 76x5 85 95 114x3 |
| `solid.sphere.union_offset` | solid | native | sphere x2, solid addition | vs.AddSolid, vs.CreateSphere | 0 76x10 84 85x2 95x2 114x5 |
| `solid.sweep.circle` | solid | native | sweep | vs.BeginSweep | 0 4 34 42 76x7 114x3 |
| `solid.tapered_extrude.circle` | solid | native | oval, tapered extrude | vs.CreateTaperedExtrude, vs.Oval | 4 76x19 111x4 113x3 114x10 |
| `spatial.extrude_along_path.single` | spatial | native | - | - | 4 76x20 111x3 113x3 114x10 |
| `spatial.floor.legacy` | spatial | native | - | - | 0 3 5 47 48x2 69 71 76x5 |
| `spatial.light.point` | spatial | native | light, extrude | vs.BeginXtrd, vs.CreateLight | 0 3 24 42 76x6 81 |
| `spatial.light.spot` | spatial | native | - | - | 76x5 81x3 |
| `spatial.locus3d.asym` | spatial | native | 3D locus, extrude | vs.BeginXtrd, vs.Locus3D | 0 3 9 24 42 76x5 |
| `spatial.mesh.from_group` | spatial | native | 3D polygon x4, group, mesh | vs.BeginGroup, vs.EndPoly3D, vs.GroupToMesh | 0 40 41x4 76x4 |
| `spatial.mesh.tetra` | spatial | native | mesh | vs.BeginMesh | 0 40 41x4 76x4 |
| `spatial.mxtrd.asym` | spatial | native | multiple extrude | vs.BeginMXtrd | 0 3x2 38 42 76x7 114x3 |
| `spatial.poly3d.asym` | spatial | native | 3D polygon | vs.EndPoly3D | 25 76x2 |
| `spatial.sweep.asym` | spatial | native | sweep | vs.BeginSweep | 0 5 34 42 76x8 114x3 |
| `spatial.sweep.pitch` | spatial | native | - | - | 0 5 34 42 76x8 114x3 |
| `spatial.tapered_extrude.single` | spatial | native | - | - | 3 76x37 111x6 113x6 114x19 |

"kind" is plug-in when the family is `plugin` or the case's intent creates a plug-in object. A case with no intent
record (a later case) shows "-" for objects and calls.
