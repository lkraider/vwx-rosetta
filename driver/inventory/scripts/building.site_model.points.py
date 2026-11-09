# Rosetta fixture recipe written in this repository for ROADMAP G3, BIM objects.
# case_id: building.site_model.points
# family_id: building.site_model
# recipe_revision: 1
# recipe_path: recipes/building.site_model.points.json
# recipe_sha256: 6bd5155f5cfa4a8004045e6b5c0ba9372e6f34c3b61aba28b04d8f2e88825ca7
# native_verification: executed: driver/ui/make-sources.py batch g3-bim, commit db6e0bf, wrote sources/building.site_model.points.vwx
#   sha256 a53c8fce9535e80ef1c7542db00b09ff3a8971a22f7bb018cac665ef15bc5836. Run 20261018T124746-script-stl exported that source.
# The capture adapter defines rosetta_checkpoint(id), rosetta_menu(*path) and rosetta_save_reopen() before running this file.
import vs
vs.Locus3D((0, 0, 0))
h_p1 = vs.LNewObj()
vs.SetName(h_p1, "point-1")
vs.SetSelect(h_p1)
vs.Locus3D((10000, 0, 500))
h_p2 = vs.LNewObj()
vs.SetName(h_p2, "point-2")
vs.SetSelect(h_p2)
vs.Locus3D((10000, 8000, 1200))
h_p3 = vs.LNewObj()
vs.SetName(h_p3, "point-3")
vs.SetSelect(h_p3)
vs.Locus3D((0, 8000, 800))
h_p4 = vs.LNewObj()
vs.SetName(h_p4, "point-4")
vs.SetSelect(h_p4)
vs.Locus3D((5000, 4000, 2000))
h_p5 = vs.LNewObj()
vs.SetName(h_p5, "point-5")
vs.SetSelect(h_p5)
vs.Locus3D((2500, 6000, 1000))
h_p6 = vs.LNewObj()
vs.SetName(h_p6, "point-6")
vs.SetSelect(h_p6)
rosetta_menu("AEC", "Terrain", "Site Model from Source Data...")
rosetta_save_reopen()
