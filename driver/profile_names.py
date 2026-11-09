"""File names and view steps that follow from a profile id.

A profile that exports a subset or a variant of the document adds a suffix to the
artifact name, so two profiles of one format write different files. Every other
profile writes `<case>.<ext>`.
"""

SUFFIXES = {
    "dwg.visible-only": ".visible-only",
    "dxf.visible-only": ".visible-only",
    "dxf.all-content.design-layers": ".design-layers",
    "dxf.all-content.design-layers.classes": ".design-layers.classes",
    "dxf.all-content.design-layers.top-plan": ".design-layers.top-plan",
    "dxf.top-plan": ".top-plan",
    "dxf.all-content.acis-off": ".acis-off",
    "dxf.opt.clip-objects": ".opt.clip-objects",
    "dxf.opt.data-vis": ".opt.data-vis",
    "dxf.opt.decompose-3d": ".opt.decompose-3d",
    "dxf.opt.decompose-plugins": ".opt.decompose-plugins",
    "dxf.opt.default": ".opt.default",
    "dxf.opt.dlvp-separate-off": ".opt.dlvp-separate-off",
    "dxf.opt.external-images-off": ".opt.external-images-off",
    "dxf.opt.fills-off": ".opt.fills-off",
    "dxf.opt.first-vp-scale-off": ".opt.first-vp-scale-off",
    "dxf.opt.flattened-2d": ".opt.flattened-2d",
    "dxf.opt.georeferenced": ".opt.georeferenced",
    "dxf.opt.groups-anon-blocks": ".opt.groups-anon-blocks",
    "dxf.opt.hatch-files-off": ".opt.hatch-files-off",
    "dxf.opt.hatch-fill-layers": ".opt.hatch-fill-layers",
    "dxf.opt.hatches-off": ".opt.hatches-off",
    "dxf.opt.image-fills-off": ".opt.image-fills-off",
    "dxf.opt.images-off": ".opt.images-off",
    "dxf.opt.indexed-colors": ".opt.indexed-colors",
    "dxf.opt.layers-separate": ".opt.layers-separate",
    "dxf.opt.linetype-blocks-off": ".opt.linetype-blocks-off",
    "dxf.opt.linked-texts": ".opt.linked-texts",
    "dxf.opt.mapped-font": ".opt.mapped-font",
    "dxf.opt.recalc-ws-off": ".opt.recalc-ws-off",
    "dxf.opt.records-off": ".opt.records-off",
    "dxf.opt.rescale-layers": ".opt.rescale-layers",
    "dxf.opt.reset-plugins-off": ".opt.reset-plugins-off",
    "dxf.opt.sia-off": ".opt.sia-off",
    "dxf.opt.sia-text-off": ".opt.sia-text-off",
    "dxf.opt.single-layer-classes": ".opt.single-layer-classes",
    "dxf.opt.spline-arcs": ".opt.spline-arcs",
    "dxf.opt.tile-fills-off": ".opt.tile-fills-off",
    "dxf.opt.triangulate-off": ".opt.triangulate-off",
    "dxf.opt.update-vp-off": ".opt.update-vp-off",
    "dxf.opt.viewports-2d-model": ".opt.viewports-2d-model",
    "dxf.opt.vp-custom-vis": ".opt.vp-custom-vis",
    "dxf.opt.weights-to-colors": ".opt.weights-to-colors",
    "3ds.mesh.all-layers": ".all-layers",
    "vwx.2022": ".v2022",
    "vwx.2023": ".v2023",
    "vwx.2024": ".v2024",
    "vwx.2025": ".v2025",
    "vwx.2026": ".v2026",
}


def artifact_suffix(profile):
    return SUFFIXES.get(profile, "")


def shows_hidden(profile):
    """True for a profile that presses Show Others for classes and layers before the export."""
    return "all-content" in profile.split(".")
