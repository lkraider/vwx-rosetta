# extras

This directory holds export files that are the artifact of no required pair.
The required pairs are the rows of `/Volumes/volxxxx/Caches/tmp/rosetta-corpus/required-pairs.tsv`.
`driver/ui/coverage.py` reads `files/` only, so a file here counts toward no pair.

List the files from the store root with this command.

    find extras -type f ! -name README.md | sort

The command printed 13 lines on 2026-10-19.

| path | bytes | sha256 | why it belongs to no required pair |
|---|---|---|---|
| `extras/_unattributed/rosetta-raw-3ds-b170794d-9303-456f-bca7-d06dc683af92.3ds` | 1125 | `d54ceb9befdc50ea6d8302cc59844433476149f2a803cd952d15d05ac72f1d97` | An early run wrote this file with a name that carries no case id. |
| `extras/_unattributed/rosetta-raw-fbx-3887aa76-081c-4392-bdf0-5c4353225a27.fbx` | 44048 | `caa3684787b918841c1a5ee287bc9d8cc094a7481094e35416a1e277580a48f0` | An early run wrote this file with a name that carries no case id. |
| `extras/_unattributed/rosetta-raw-image-36b03121-c481-4e50-bee6-3e8ce92a43b2.jpg` | 2890 | `a9b217f9ebaf4ced6862629816320b7998d9aae0b790aee4eeaa29ec8f331905` | An early run wrote this file with a name that carries no case id. |
| `extras/_unattributed/unattributed-e43b6bfc.mtl` | 32 | `b5ee7af9ff08ab71dcbb981756412edbe4749678dd59556350e6b2c3c7a6cc30` | An early run wrote this file with a name that carries no case id. |
| `extras/_unattributed/unattributed-e43b6bfc.obj` | 2462 | `4101e3fd6c6e268f38071d44d89906e177b676e2a7afab9ee599b8dd15b44e03` | An early run wrote this file with a name that carries no case id. |
| `extras/empty-3ds/ix.mech.rational-surface-trim-hole-units.3ds` | 62 | `5bf0d50db504fcd7182e6b534bd21284c97d5774125476c38f70509efbe492f2` | `ledger/negatives.tsv` records the pair `ix.mech.rational-surface-trim-hole-units 3ds.mesh` as a negative with the reason `no tessellatable geometry`. |
| `extras/empty-3ds/spatial.light.point.3ds` | 300 | `490b9609f210eb62552eeaeb404a4b7aea22c21252b32b2eeeff4d475c329c2f` | The earlier export of `spatial.light.point 3ds.mesh`, with 0 vertices. The pair is an artifact: `files/spatial.light.point/spatial.light.point.3ds` holds the W17 surface. |
| `extras/empty-sat/solid.sweep.circle.sat` | 146 | `e9e1023538034b4555a42b08ab063a0037c6a6d22f0bf375a0864540e6d4c89c` | File > Export SAT wrote it in run 20261019T002417-ui-sat. `ledger/negatives.tsv` records the pair `solid.sweep.circle sat.solids` as a negative with the reason `no valid objects for export`. |
| `extras/empty-sat/solid.sweep.circle.scripted.sat` | 146 | `2d9efd7b47fd0963aa539f912fd613c9d50e083ee98aa8fa3dc62e7292956e2c` | vs.ExportSAT wrote it in run 20261019T003152-scripted and returned True. The same negative row cites it. |
| `extras/extrude.asym/extrude.asym.iges` | 18532 | `ed4670de9488efb5efb2e77b6bf3a0acf0071f5b31548d2261616cc78f6e78c8` | The case id `extrude.asym` has 0 rows in `required-pairs.tsv`. |
| `extras/extrude.asym/extrude.asym.sat` | 20264 | `2d15a8c4d2d690c87599125776198d7a07f8bb276ee323d59cb7cb1f17304098` | The case id `extrude.asym` has 0 rows in `required-pairs.tsv`. |
| `extras/extrude.asym/extrude.asym.step` | 16119 | `b7c3f9088c3dd97b41813787d1f897a74743f045cc937616bf141e23ee68e365` | The case id `extrude.asym` has 0 rows in `required-pairs.tsv`. |
| `extras/extrude.asym/extrude.asym.stl` | 1084 | `60787d40275a5df08f1118bdf7f0ab804708d556a490c963cd3da27d39adf952` | The case id `extrude.asym` has 0 rows in `required-pairs.tsv`. |
