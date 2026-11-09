# ledger/manifest.json

This page was written for the working repository that built the corpus. The builder scripts it names
(`driver/build-index.py`, `driver/reader-audit.py`, `driver/recipe_intent.py`, `driver/acis-types.py`,
`driver/store_path.py`, `driver/source-map.tsv`) are not part of this repository. The fields and rules below hold
for the ledger files here.

`ledger/manifest.json` gives a consumer every required pair in one file. `python3 driver/build-index.py`
writes it from the ledger tables. `python3 driver/build-index.py --check` exits 1 when the file differs
from what the tables give. Every path in it is relative to the repository root. The same tables give the
same bytes.

## Top level

| field | value |
|---|---|
| `schema` | `rosetta-manifest/1` |
| `pairs` | one entry per row of `ledger/required-pairs.tsv`, in that order |
| `unlinked_companions` | companion files that no primary file names, each with a `case` field and the companion fields below |

## Every entry

| field | value | from |
|---|---|---|
| `case`, `profile`, `format` | the pair | `ledger/required-pairs.tsv` |
| `state` | `artifact` or `negative` | `ledger/coverage.tsv` |
| `source_path` | the source document under `sources/` | `driver/source-map.tsv`, found by digest with `driver/store_path.py` |
| `source_sha256` | the SHA-256 of that document | `driver/source-map.tsv` |
| `intent_path` | `ledger/intent.json` | |
| `intent_sha256` | the SHA-256 of the case record in `ledger/intent.json` | the record, written as compact JSON with sorted keys and UTF-8 text |

`profile` names a file in `driver/inventory/pack-skeleton/profiles/`. The ID
`dxf.all-content.design-layers` keeps "all-content" from before its output was measured. Its files hold
only visible classes, because Export invisible classes is disabled under the layers mapping. The ledger
lines and a .vwx reader's scoreboard use the ID, so it stays.

`source_path` and `source_sha256` are null for a case with no source document. Those cases are negatives
with the reason `no source document`.

## An artifact entry

| field | value | from |
|---|---|---|
| `artifact_path` | the exported file under `files/` | `ledger/coverage.tsv` |
| `artifact_bytes`, `artifact_sha256` | the size and SHA-256 of that file | the file, checked against `ledger/corpus-audit.json` |
| `inert` | `yes` when the file carries no geometry of the kind its format holds, `no` when it carries some, `unknown` when the format has no geometry measure | `ledger/inert-pairs.tsv` |
| `inert_measure` | the measured counts, for example `v=56 f=40 objects=1 total_face_area=5095254.596230423` for `building.door.free` | `ledger/inert-pairs.tsv` |
| `inert_rule` | the measure that decides `inert`, for example `the face count and the total face area` | `ledger/inert-pairs.tsv` |
| `companions` | the files the artifact names, an empty list when it names none | `ledger/companions.tsv` |
| `working_copy` | the change made to the open document before the export, or null | `ledger/corpus-ledger.jsonl` |
| `reader` | for a DXF, DWG, PDF or SAT artifact, the result of a reader outside Vectorworks, otherwise null | `ledger/reader-audit.tsv` |

An inert artifact stays an artifact. Its file is what the application wrote for the pair.

Each companion holds `path`, `bytes`, `sha256`, `kind` and `linked_by`. `kind` is `mtl`, `texture` or `buffer`. A `buffer` is the `.bin` file a glTF names in `buffers[].uri`.
`linked_by` quotes the line of the primary file that names the companion, or reads `unreferenced`.

`reader` holds `name`, `result` and `detail`. For DXF the reader is `ezdxf.readfile` followed by
`doc.audit()`, and `detail` gives the DXF version and the audit error and fix counts. For DWG the
reader is LibreDWG `dwgread -O JSON`, the route a .vwx reader's DWG reference check takes, and `detail`
gives the object count and the entity counts of its output. For PDF the reader is `qpdf --check`
followed by `qpdf --json=2`, and `detail` gives the PDF version, the page, object and image counts
and the `/MediaBox` of each page. For SAT the reader is `ezdxf.acis.sat.parse_sat`, and `detail`
gives the ACIS version, the body count and the surface and curve types that `driver/acis-types.py`
counts. `result` is `parsed` when the reader returns a document and `rejected` when it fails. A PDF
reads `warnings` when `qpdf --check` exits 3. `driver/reader-audit.py --write` writes the table.
`build-index.py` stops when a DXF, DWG, PDF or SAT artifact has no row at its digest.

### working_copy

Some exports came from a changed copy of the source document. Before the export, a program ran in the
open document and saved nothing. The file under `sources/` is the document that was opened. The artifact
holds the changed content. `working_copy` names the change:

| field | value |
|---|---|
| `source_sha256` | the SHA-256 of the document that was opened, equal to the entry `source_sha256` |
| `change` | one sentence that says what the program did to the document |
| `program_path` | the program under `runs/<run_id>/pre/` |
| `program_sha256` | the SHA-256 of that program |

A consumer that compares the artifact with its own read of the source finds the change in the
artifact only. The `change` sentences live in `PRE_EXPORT_CHANGE` in `driver/build-index.py`. The script
stops when a ledger line names a pre-export program for a case without a sentence.

## A negative entry

| field | value | from |
|---|---|---|
| `reason` | why no file exists, for example `no source document` | the `status` column of `ledger/negatives.tsv` |
| `evidence` | the measurement that shows it, as prose | the `evidence` column of `ledger/negatives.tsv` |

`evidence` is copied text. It can name absolute paths of the machine that measured it. A consumer reads it
and resolves none of its paths.

# ledger/intent.json

`ledger/intent.json` states what each case draws. It holds one record per case of
`ledger/required-pairs.tsv`. `python3 driver/build-index.py` writes it with the manifest. `--check` also
exits 1 when the `intent_sha256` of a manifest entry differs from the digest of its record. In Python the
digest is `sha256(json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode())`.

`driver/recipe_intent.py` runs the script that built the source document of the case. It records the
calls with a stand-in `vs` module, and nothing runs in Vectorworks. A case with a file
`driver/inventory/scripts/revisions/<case>.rev<N>.py` runs the largest N, which is the file
`driver/ui/make-sources.py` runs. Other cases run `driver/inventory/scripts/<case>.py`. A record holds
only what the script or the recipe JSON states. A field that neither states is absent.

The recipe JSON files under `driver/inventory/recipes/` and `driver/inventory/interaction/` are copies of
`vwx/tools/research/rosetta/inventory/recipes/` and `.../inventory/generated/interaction/` at commit
`6970c341` of the old repository. Each keeps its bytes. The `recipe_sha256` header of each script names
its digest.

## Top level

| field | value |
|---|---|
| `schema` | `rosetta-intent/1` |
| `cases` | one record per case, keyed by case id, in the order of `ledger/required-pairs.tsv` |
| `entity_kinds` | the DXF and DWG entities that one object type exported as, measured in the cases below |

## A case record

| field | value |
|---|---|
| `script` | `path`, `sha256` and `revision` of the script that ran |
| `recipe` | `path`, `sha256`, `revision` and `title` of the recipe JSON |
| `objects` | the objects the script creates, in creation order |
| `layers` | the layers the script creates, activates or changes |
| `classes` | the classes the script names, with `hidden: true` for a class it hides |
| `resources` | symbol definitions, record formats, materials, styles, worksheets and saved views |
| `document` | `units` (`vs.SetUnits`) and `view` (`vs.SetView`), each with `api` and `args` |
| `parameters` | the `parameters` of the recipe JSON, for example `nominal_bounds` |
| `expected_relationships` | the `expected_relationships` of the recipe JSON whose names all exist in `objects`, `layers`, `classes` or `resources` |

Some scripts are revisions written in this repository. Their header has a `# base:` line. When the header
also has a `# recipe_path:` line, `recipe` names that JSON. Its `title` and `expected_relationships` cover
the objects the revision adds, and its `operations` stay those of the JSON it supersedes. Otherwise
`recipe` names the JSON of the nearest base script, and `script.revision` is larger than
`recipe.revision`. Such a revision adds objects. The recipe JSON does not list them.

## An object

| field | value |
|---|---|
| `id` | the name from `vs.SetName`, or `#<n>` for the n-th object the script creates |
| `type` | the object type, for example `rectangle`, `extrude`, `symbol instance` or `NURBS surface` |
| `api`, `args` | the call that creates the object and its arguments, in document units |
| `bounds` | the box `[[min...], [max...]]` of the creation coordinates, for a rectangle, oval, rounded rectangle, line, polygon, 3D polygon or sphere. The `calls` apply after it |
| `vertices` | the points of a polygon, a polyline or a 3D polygon. A polyline vertex is the `vs.Add2DVertex` argument list |
| `closed` | the `vs.ClosePoly` or `vs.OpenPoly` mode at creation, when the script sets one |
| `faces` | the 3D polygons of a mesh |
| `profile` | the objects between `vs.BeginXtrd`, `vs.BeginMXtrd` or `vs.BeginSweep` and its end call |
| `plugin`, `definition` | the plug-in name of a plug-in object, the symbol name of a symbol instance |
| `settings` | the `vs.TextOrigin`, `vs.TextRotate` and `vs.TextSize` calls before a text object |
| `working_plane` | the `vs.SetWorkingPlaneN` call in force at creation |
| `layer` | the layer the object sits on. An object without `layer` sits on the layer that was active when the script started |
| `class` | the class from `vs.SetClass`, or the class that `vs.NameClass` made active before creation |
| `in` | `{"symbol": name}` for an object of a symbol definition, `{"object": id}` for a member of a group, of a Boolean solid, or the crop or an annotation of a viewport |
| `trims` | the id of the NURBS surface that this curve trims |
| `calls` | the later calls on the object, in order, each with `api` and `args`. Transforms such as `vs.HRotate`, `vs.Mirror` and `vs.Set3DRot` are here |
| `role` | the role the recipe JSON gives the object |
| `hidden` | in a case with a hidden class, `true` when the object's class is hidden, or when it belongs to a hidden object or to a symbol whose instances are all hidden. Vectorworks shows the active class, so a hidden class that is still active when the script ends counts as shown |

An argument that is an object, a layer or a resource reads as its id or its name.
A `layers` entry holds `name`, `type` (`design` or `sheet`), `elevation` and `thickness` when the script
states them. The layer that was active at the start has no name and holds `active_at_start: true`.

## entity_kinds

Each row comes from a case whose script draws one object with no transform, class, layer, working plane
or resource. The row holds the entities of that case's `dxf.all-content` or `dwg.all-content` artifact.

| field | value |
|---|---|
| `type`, `plugin` | the object type, and the plug-in name of a plug-in object |
| `format`, `case`, `artifact_path` | the artifact measured |
| `entities` | entity type to count in the ENTITIES section. For DWG this is the `types=` count of `ledger/inert-pairs.tsv` |
| `block_entities` | DXF only, entity type to count in the BLOCKS section |

Every DXF and DWG artifact holds a `VIEWPORT` entity, and the counts leave it out. A type with no such
case has no row. A 2D object with a fill adds a `WIPEOUT`. The `ix.planar` cases that call
`vs.SetFPat(h, 0)` hold no `WIPEOUT`. Some symbol definitions hold 2D objects and an extrude. In their DXF
artifacts the block holds the 2D objects and no `3DSOLID`.
