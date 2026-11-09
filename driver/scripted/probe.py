import json
import vs
d = {"name": vs.GetFName(), "path": vs.GetFPathName(),
     "layer": vs.GetLName(vs.ActLayer()), "units": str(vs.GetUnits())}
import os
VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
with open(VOLUME + "/Caches/tmp/rosetta-corpus/scripted-out/doc-probe.json", "w") as f:
    json.dump(d, f)
