# Reproducing Rosetta

With a Vectorworks licence, the driver regenerates or extends Rosetta, and it shows where each file came from.

**We have not run any of this since the licence it used ended.** It generated Rosetta with Vectorworks 2027
(32.1.0, build 885363) on macOS. We believe it still works, but we have not re-validated it.

## What it needs

- A licensed Vectorworks 2027, the release that wrote every file here (32.1.0, build 885363; docs/DESIGN.md, "On
  later Vectorworks releases"). A standard installation is enough.
- macOS, with Accessibility and Automation permission for the terminal that runs the driver. Menus, dialogs and
  export panels are driven through the macOS Accessibility interface and System Events; scripts reach Vectorworks
  through its scripting AppleEvent.
- An en_US locale for Vectorworks: it stops at start under a locale with a decimal comma (`driver/ui/vw-launch.sh`
  sets it).
- Zig 0.16 to build the driver's CLI, Python 3 for the rest.
- Optional: the Vectorworks SDK2026 `vs.py` binding file, for one audit. It is not included;
  `driver/sdk/README.md` says where it comes from.

## How a case becomes files

```
driver/batch/*.tsv            the batch lists: per step, a driver, a format, a profile and the cases
  -> driver/batch.py          runs one batch: locks, pauses, run records, an optional summary notification
       -> driver/ui/vw-launch.sh      starts Vectorworks
       -> driver/ui/make-sources.py   per case: open the template, send the case's script
                                      (driver/inventory/scripts/<case>.py), save, reopen -> sources/<case>.vwx
       -> driver/ui/sweep-ui.py       per case and profile: File > Export with the profile's settings
                                      -> files/<case>/<case>.<profile>.<ext>  (save-pdf-panel.sh for PDF)
       -> driver/scripted/            the routes exported by script rather than by menu
     support: driver/pause.py, focus.py, vw_lock.py, vw_memory.py (restarts Vectorworks when its memory
              grows), run_provenance.py (what each run started from), store_path.py, profile_names.py,
              export-settings.py
  the driver's CLI (VWX_CLI, SCRIPT_CLI): driver/native/ (Zig source; build with driver/native/build.sh).
              Commands: info, ui-dialog, ui-menu, ui-export-control, native-script-send.
  then the ledger: driver/ui/coverage.py, verify-artifacts.py, audit-corpus.py, inert-pairs.py, mesh-topology.py,
              pdf-ink.py, source-census.py, export-queue.{py,sh} -> ledger/*.tsv;
              driver/build-index.py (+ recipe_intent.py, build-source-map.py, reader-audit.py, acis-types.py)
              -> ledger/manifest.json and ledger/intent.json
  driver/ui/run-all.sh runs the whole chain; driver/ui/validate-store.sh checks the result.
```

## Settings (environment)

| variable | what it sets | default |
| --- | --- | --- |
| `VW_APP` | the Vectorworks application | `/Applications/Vectorworks 2027/Vectorworks 2027.app` |
| `ROSETTA_VOLUME`, `ROSETTA_TMP`, `ROSETTA_BASE` | where scratch data and the store live | `/Volumes/volxxxx` and below it |
| `VWX_CLI`, `SCRIPT_CLI` | the driver's CLI | `driver/bin/vwx` |
| `ROSETTA_LOCK*`, `ROSETTA_PAUSE`, `ROSETTA_KEEP_VW`, `VW_*_MB` | locks, a pause file, keeping Vectorworks open, memory limits | see each script |
| `ROSETTA_NOTIFY`, `ROSETTA_NOTIFY_SOURCE` | where `batch.py` sends a batch summary, if anywhere | none |

## What needs more than this repository

- `driver/build-index.py` rebuilt the manifest and intent files from the working ledger. That ledger also held
  process tables that are not published (run records, a source map, census and audit tables), so here the script
  stops at the first missing table. The published `INDEX.md` is written by `tools/index.py`.
- Of the driver's Python unit tests (`driver/tests/`), run on Linux in a copy without `files/` and `sources/`, 44
  fail; 33 of them also fail in our working repository in the same setup. The 11 that fail only here read
  the working store's process tables (its run ledger, census files, shared digests), which are not included; a
  fresh run of the chain writes them again.
- `driver/native` builds with Zig 0.16 on Linux too, but its tests need macOS (they link the system C library).
- We left out two kinds of file: batch lists whose work never ran, and studies that read external documents.
