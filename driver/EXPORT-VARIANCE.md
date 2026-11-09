# What changes between two exports of one source

This page was written for the working repository that built the corpus. The evidence folders, run
records and scripts it names (`driver/cache-evidence/`, `runs/20261016T234812-ui-dxf/`, `driver/dxf-diff.py`) are
not part of this repository. The findings below hold for the files here.

Vectorworks 2027 writes different bytes each time it exports one source document. Three runs of the `dwg`
route for `annotation.bitmap.asym` wrote three files whose sha256 digests begin `ec8462e404c0`,
`087eb30c4045` and `c30d8f792962`. The store keeps none of those files. This page names the DXF fields that changed between two pairs of exports the store does keep.

## Measurement

The store holds two exports of `ix.mech.rational-surface-trim-hole-units` from one source document,
SHA-256 `c19a3152de52e73a7abbb6fb8b9b7d5f8f94bf7c7b0f33271077032e82241a94`, one day apart. Each export
wrote a DXF file and a DWG file. The paths are under `driver/cache-evidence/rosetta-vw-empty-repair/`.

| export | runs | DXF | DWG beside it |
|---|---|---|---|
| first | `20261015T231228-ui-dwg`, `20261015T233445-ui-dxf` | `negatives-moved/ix.mech.rational-surface-trim-hole-units/ix.mech.rational-surface-trim-hole-units.dxf`, `931034ea57ea8974` | `d71251b5fb752515` |
| second | `20261016T234745-ui-dwg`, `20261016T234812-ui-dxf` | `surface/exports/ix.mech.rational-surface-trim-hole-units.dxf`, `71d9e17cf85c1612` | `e533dd4e35c650ee` |

Before the second export, a program in `runs/20261016T234812-ui-dxf/pre/` ran `vs.ResetObject` on
`nurbs-surface-a` in the open document and saved nothing. The surface bounding box grew from 0 to 2 in x
and y to -0.5 to 27.25 in x and -1.5 to 24.75 in y, with a height of 9.5. The DWG run
`20261016T234745-ui-dwg` ran the same program.

`python3 driver/dxf-diff.py FIRST.dxf SECOND.dxf` compares the DXF files. The DWG files compare the same way
after `dwg2dxf` 0.14 from LibreDWG converts each one.

## Result

In both formats every section has the same group codes in the same order. The CLASSES, BLOCKS, ENTITIES
and THUMBNAILIMAGE sections are identical. The ENTITIES section holds no entity, because Vectorworks writes
no DXF entity for this surface. Every handle is identical, `$HANDSEED` included. `$VERSIONGUID` is
identical. These values changed:

| section | object | group codes | what it holds | cause |
|---|---|---|---|---|
| HEADER | `$TDCREATE`, `$TDUCREATE`, `$TDUPDATE`, `$TDUUPDATE` | 40 | the creation and update dates, local and UTC | the export time |
| HEADER | `$FINGERPRINTGUID` | 2 | a GUID | a new value for each export |
| HEADER | `$EXTMIN`, `$EXTMAX` | 10, 20, 30 | the drawing extents | the surface change |
| TABLES | VPORT `*Active` | 12, 22, 40, 41 | the view center, the view height and the aspect ratio | the surface change |
| OBJECTS | LAYOUT `Model` | 14, 24, 15, 25, 35 | the layout extents | the surface change |

The new extents equal the bounding box of the regenerated surface. So the extents follow every object in
the document, including an object that writes no entity. In this pair, the four date variables and
`$FINGERPRINTGUID` are the only values that changed without a change to the document.

## Unchanged document

The store and `driver/cache-evidence/rosetta-vw-variance/` hold two exports of `spatial.light.point` in each
format. Every export came from one source document, SHA-256
`53f044c90666cc40b505623c3698e0999859298941ed18a0319b4c5be2cb0cb4`, with no change between them. The
ENTITIES section holds a `3DSOLID` with handle `64` and a `VIEWPORT` with handle `65`.

| format | first export | second export |
|---|---|---|
| DXF | `first-export.dxf`, run `20261017T171746-ui-dxf`, `ed9efb179feb7406` | `files/spatial.light.point/spatial.light.point.dxf`, run `20261017T172549-ui-dxf`, `993baf0feb725df5` |
| DWG | `files/spatial.light.point/spatial.light.point.dwg`, run `20261017T171821-ui-dwg`, `53d642103a832002` | `second-export.dwg`, run `20261017T174415-ui-dwg`, `e5bf0096570b4187` |

`dxf-diff.txt` and `dwg-diff.txt` in the same folder hold the `dxf-diff.py` output. The DXF files have the
same size, 645246 bytes. The DWG files have the same size, 16805 bytes.

In both formats every section has the same group codes in the same order. Every handle is identical,
`$HANDSEED` included. `$EXTMIN`, `$EXTMAX`, the active view and the layout extents are identical. The
TABLES, BLOCKS and OBJECTS sections are identical. These values changed:

| format | section | object | group codes | what it holds |
|---|---|---|---|---|
| both | HEADER | `$TDCREATE`, `$TDUCREATE`, `$TDUPDATE`, `$TDUUPDATE` | 40 | the export time |
| both | HEADER | `$FINGERPRINTGUID` | 2 | a GUID |
| DXF | ENTITIES | `3DSOLID` handle `64` | 2 | the GUID in `AcDbModelerGeometry` |
| DXF | ACDSDATA | the ACIS data of the solid | 310 | the save time in the ACIS header |
| DWG | ENTITIES | `3DSOLID` handle `64` | 70 | the modeler version that `dwg2dxf` reads, 14 and 5 |

`dwg2dxf` writes the solid GUID as all zeros and writes no ACDSDATA section. `dwgread` reads the same object
size, 257 bits, from both DWG files. It reads a different `version` and `wireframe_data_present` from them.
This measurement does not show whether the DWG bytes of the solid differ or whether LibreDWG 0.14 decodes
them wrong.

So, between two exports of an unchanged document, the dates, the GUIDs and the ACIS save time change. The
handles, the extents and the drawn geometry stay the same.

## Limit

This case holds one solid and one viewport. The measurement does not show whether a document with many
entities keeps its handles between exports.
