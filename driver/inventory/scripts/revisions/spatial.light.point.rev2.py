# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: spatial.light.point
# family_id: spatial.light
# recipe_revision: 2
# base: driver/inventory/scripts/spatial.light.point.py
# native_verification: executed: driver/ui/make-sources.py batch 1, commit 73a2296, wrote sources/spatial.light.point.vwx
#   sha256 53f044c90666cc40b505623c3698e0999859298941ed18a0319b4c5be2cb0cb4. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_li = vs.CreateLight(14.5, -22.25, 31, 2, True, False)
vs.SetName(h_li, "light-a")
vs.BeginXtrd(0, 3.5)
vs.Rect((10, -18), (21.75, -27.5))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'mesh-a')
rosetta_save_reopen()
