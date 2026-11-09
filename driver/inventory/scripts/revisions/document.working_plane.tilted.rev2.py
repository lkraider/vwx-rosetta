# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: document.working_plane.tilted
# family_id: document.working_plane
# recipe_revision: 2
# base: driver/inventory/scripts/document.working_plane.tilted.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/document.working_plane.tilted.vwx
#   sha256 5ac760332b81850071d37bcda34daa50fc0e438b578ae6cfd2cc499c3b034993. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.SetWorkingPlaneN((120.5, -40.25, 15), (0, 0.6, 0.8), (1, 0, 0))
vs.Locus3D((3.5, 7.25, 0))
h_l3 = vs.LNewObj()
vs.SetName(h_l3, "locus-wp")
vs.BeginXtrd(0, 3.5)
vs.Rect((6, 15.5), (18.75, 9))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'mesh-wp')
rosetta_save_reopen()
