# driver/sdk/vs.py

`vs.py` is the Vectorworks SDK2026 Python binding file. Nemetschek holds its copyright, so git leaves it
out. `driver/recipe-profile-audit.py` reads it to check that every recipe call has a definition and a
category. Without it, the audit writes the same table and skips that check.

The file comes from the Vectorworks SDK examples repository, `VectorworksDeveloper/SDKExamples` on
GitHub, commit `0b3ec438558c264d54b190879ff86049b0e697de`, path
`VectorworksSDK/SDK2026/SDKLib/Include/vs.py`. Its SHA-256 is
`b06e9265415eb79f47e73fb11abdd6794ddbde726265496bf3fafd3a478b58a9`, 1605804 bytes.

Fetch it from the repository root:

```sh
curl -fL -o driver/sdk/vs.py \
  https://raw.githubusercontent.com/VectorworksDeveloper/SDKExamples/0b3ec438558c264d54b190879ff86049b0e697de/VectorworksSDK/SDK2026/SDKLib/Include/vs.py
shasum -a 256 driver/sdk/vs.py
```

`VWX_BINDINGS` names another copy.
