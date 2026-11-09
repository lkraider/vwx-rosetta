# Rosetta fixture recipe revision written in this repository for ROADMAP G4. It places an object that uses the style.
# case_id: resource.slab_style.named
# family_id: resource.slab_style
# recipe_revision: 2
# recipe_path: recipes/revisions/resource.slab_style.named.rev2.json
# recipe_sha256: dc008686ae9a5dbfd993868b4b3ee52aedc234cf66bc058bb859dde3f5229477
# native_verification: executed: driver/ui/make-sources.py batch g4, commit 97fcf71, wrote sources/resource.slab_style.named.vwx
#   sha256 35505bb181230b30fc90e3953e6b39ea02e649eab0c7dc8e76af82ee82ac99d4. Run 20261018T104031-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_sst = vs.CreateSlabStyle("Rosetta-SlabStyle")
vs.SetName(h_sst, "Rosetta-SlabStyle")
vs.SetComponentWidth(h_sst, 1, 250)
ssi = vs.Name2Index("Rosetta-SlabStyle")
vs.SetSlabPreferencesStyle(ssi)
vs.BeginPoly()
vs.AddPoint((0, 100))
vs.AddPoint((200, 100))
vs.AddPoint((200, 300))
vs.AddPoint((0, 300))
vs.ClosePoly()
vs.EndPoly()
h_pr = vs.LNewObj()
vs.SetName(h_pr, "slab-profile")
h_sb = vs.CreateSlab(h_pr)
vs.SetName(h_sb, "slab-styled")
vs.ResetObject(h_sb)
rosetta_save_reopen()
