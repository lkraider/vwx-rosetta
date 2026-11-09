# driver/native

Zig 0.16.0 source of `driver/bin/vwx`, the CLI that the drivers call as `VWX_CLI` and `SCRIPT_CLI`.

    sh driver/native/build.sh           build, run the tests, install driver/bin/vwx when the digest matches
    sh driver/native/build.sh --record  build, run the tests, write the digest into BUILD.tsv, install

The Zig caches go under `$ROSETTA_TMP/zig`. `driver/ui/run-all.sh --status` compares `driver/bin/vwx` with
`driver/bin/BUILD.tsv`.

## Commands

| Command | Caller |
|---|---|
| `info` | `driver/ui/make-sources.py` reads the format version |
| `ui-dialog` | `driver/ui/sweep-ui.py`, `driver/ui/save-pdf-panel.sh` (`--read-field`, `--read-enabled`, `--read-popup`) |
| `ui-menu` | `driver/ui/sweep-ui.py` |
| `ui-export-control` | `driver/ui/sweep-ui.py` |
| `native-script-send` | `driver/ui/sweep-ui.py`, `driver/scripted/` |

