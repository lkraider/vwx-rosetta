# How a reader or converter uses Rosetta

Any tool that reads or writes `.vwx` can check itself against Rosetta: each reference is what Vectorworks itself
wrote. A tool reads Rosetta in place and needs only the files below.

- **Where.** A tool takes Rosetta by path, for example from an environment variable such as `ROSETTA_DIR`.
- **What.** `ledger/manifest.json` (schema `rosetta-manifest/1`) is the contract: for each pair, the source
  (`source_path`, `source_sha256`), the reference (`artifact_path`, `artifact_bytes`, `artifact_sha256`), the
  `format` and the `profile`. `ledger/intent.json` says what each case targets. Every path is relative to Rosetta's
  root.
- **Which version.** A tool records which Rosetta it was scored against: a version of this repository (a commit or
  tag) plus the sha256 of `ledger/manifest.json`. Against a different version, it scores again; scores from
  different Rosetta versions are never compared silently.
- **Its own additions** stay in the tool's repository: extra pairs for cases not yet in the manifest, its
  scoreboards and its list of accepted open rows.

`driver/MANIFEST.md` documents every field of the two ledger files.
