"""In-app scripted export harness. Scripting APIs only: no UI automation, no document save.

Run inside Vectorworks (see README.md) or outside it with --dry-run, which prints
the vs.* calls the module would make against a recording stub.

Every API name and signature below was read from the shipped binding
(sdk/vs.py, SDK2026 stubs). Nothing here has run against Vectorworks 2027.
"""
import csv
import json
import os
import re
import sys

# Calls this module must never make. Ctx.call refuses them even if a route is edited.
FORBIDDEN = frozenset(["SaveActiveDocument", "DoMenuText", "SaveSheet"])

# Routes. 'direct' writes a file from one call. 'modal' opens a modal that only
# a human can answer; it runs only with allow_modal. 'unsupported' has no
# scripted route in the binding.
UNSUPPORTED = {
    "obj": "no ExportOBJ in the binding (only ImportOBJ); menu item exists but its internal DoMenuTextByName name is unrecorded and it opens a dialog",
    "3ds": "no Export3DS in the binding (only Import3DSFile); menu item opens a dialog and its internal name is unrecorded",
    "fbx": "no ExportFBX in the binding; menu item opens a dialog and its internal name is unrecorded",
    "parasolid": "no ExportParasolid in the binding (only ImportParasolidXT); menu item opens a dialog and its internal name is unrecorded",
    "gltf": "no glTF function in the binding and no glTF item in the 35 observed File > Export items",
    "svg": "no SVG function in the binding and no SVG item in the 35 observed File > Export items",
}
FRAMED = ("dwg", "dxf", "pdf", "png", "svg")
ALL_FORMATS = ("dwg", "dxf", "png", "obj", "gltf", "fbx", "3ds", "pdf", "svg",
               "stl", "sat", "parasolid", "ifc", "xlsx", "csv")
MM_PER_INCH = 25.4


class ForbiddenCall(Exception):
    pass


class Dry(object):
    """Recording stand-in for the vs module. Returns plausible values, writes nothing."""

    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        def rec(*args):
            self.calls.append((name, args))
            print("DRY vs.%s%r" % (name, args))
            return self._ret(name)
        return rec

    @staticmethod
    def _ret(name):
        canned = {
            "GetUnits": (0, 0, 0, 25.4, "mm", "mm2"),  # upi 25.4: document in mm
            "GetLScale": 1.0, "GetZoom": 100.0, "GetVCenter": (0.0, 0.0),
            "GetDrawingSizeRect": ((0.0, 297.0), (420.0, 0.0)),
            "ActLayer": "H_LAYER", "FLayer": "H_LAYER", "NextObj": None,
            "FInLayer": None, "GetLName": "Design Layer-1",
            "IFC_GetIFCScheme": (True, 0), "GetObject": "H_WS",
            "GetWSRowColumnCount": (2, 2), "GetWSCellStringN": "c",
            "EXL_GetSheetIndex": (True, 1),
        }
        if name in canned:
            return canned[name]
        if name.startswith(("Export", "IFC_Export", "EXL_", "OpenPDF", "Acquire")):
            return True
        return None


def _vs(dry):
    if dry:
        return Dry()
    import vs  # only exists inside Vectorworks
    return vs


class Ctx(object):
    def __init__(self, vs, case_id, out_dir, dry, allow_modal, opts):
        self.vs, self.case_id, self.out_dir = vs, case_id, out_dir
        self.dry, self.allow_modal, self.opts = dry, allow_modal, opts
        self.calls = []

    def call(self, name, *args):
        if name in FORBIDDEN:
            raise ForbiddenCall(name)
        self.calls.append("vs.%s%r" % (name, args))
        return getattr(self.vs, name)(*args)

    def path(self, ext, suffix=""):
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", self.case_id)
        return os.path.join(self.out_dir, "%s%s.%s" % (safe, suffix, ext))


# ---- framing -------------------------------------------------------------

def _upi(ctx):
    """Document units per inch, from vs.GetUnits() -> (fraction, display, format, upi, lenMk, areaMk)."""
    return float(ctx.call("GetUnits")[3])


def layer_bbox_doc_units(ctx, layer_names):
    """Union of vs.GetBBox over every object in the named layers (all layers if empty).

    GetBBox is the projection onto the screen plane, so this is a plan-view
    extent in document units. Returns (x0, y0, x1, y1) or None.
    """
    box = None
    h = ctx.call("FLayer")
    while h:
        if not layer_names or ctx.call("GetLName", h) in layer_names:
            o = ctx.call("FInLayer", h)
            while o:
                (ax, ay), (bx, by) = ctx.call("GetBBox", o)
                x0, x1, y0, y1 = min(ax, bx), max(ax, bx), min(ay, by), max(ay, by)
                box = (x0, y0, x1, y1) if box is None else (
                    min(box[0], x0), min(box[1], y0), max(box[2], x1), max(box[3], y1))
                o = ctx.call("NextObj", o)
        h = ctx.call("NextObj", h)
    return box


def frame_drawing(ctx, bbox_mm=None, layers=(), margin=0.05, move_origin=False):
    """Make the drawing extent equal the case bounding box plus margin, at layer scale 1:1.

    Mechanism (binding names): vs.GetUnits (units per inch), vs.GetBBox (extent),
    vs.SetDrawingRect(paperWidth, paperHeight) (extent, document units),
    vs.SetLScale(layerHandle, 1.0) (so page units equal model units),
    vs.SetVCenter(point) and vs.SetZoom(percent) (view),
    vs.DoMenuTextByName('Fit to Window', 0) (only fit-to-extent call; legacy name).
    Returns (record, restore). restore() puts back what was read before.
    Never moves the origin unless move_origin is true, because export
    coordinates would shift. The rect position is not settable in the binding,
    so the record carries a bbox_inside_rect check and a 'verified' flag.
    """
    upi = _upi(ctx)
    to_doc = lambda mm: mm * upi / MM_PER_INCH
    layer = ctx.call("ActLayer")
    before = {
        "lscale": ctx.call("GetLScale", layer),
        "rect": ctx.call("GetDrawingSizeRect"),
        "zoom": ctx.call("GetZoom"),
        "vcenter": ctx.call("GetVCenter"),
    }
    if bbox_mm:
        box = tuple(to_doc(v) for v in bbox_mm)
        source = "request.bbox_mm"
    else:
        box = layer_bbox_doc_units(ctx, set(layers))
        source = "vs.GetBBox union"
    if box is None:
        return {"status": "no_bbox", "bbox_source": source}, (lambda: None)
    w, h = box[2] - box[0], box[3] - box[1]
    if w <= 0 and h <= 0:
        return {"status": "degenerate_bbox", "bbox_doc": box}, (lambda: None)
    side = max(w, h)
    pw, ph = w + 2 * margin * side, h + 2 * margin * side
    ctx.call("SetLScale", layer, 1.0)
    ctx.call("SetDrawingRect", pw, ph)
    cx, cy = (box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0
    ctx.call("SetVCenter", (cx, cy))
    zoom_note = "fit_to_window"
    try:
        ctx.call("DoMenuTextByName", "Fit to Window", 0)
    except Exception as e:  # menu name unverified on 2027
        zoom_note = "fit_to_window_failed: %r" % (e,)
    (rx0, ry0), (rx1, ry1) = ctx.call("GetDrawingSizeRect")
    inside = (min(rx0, rx1) <= box[0] and max(rx0, rx1) >= box[2]
              and min(ry0, ry1) <= box[1] and max(ry0, ry1) >= box[3])
    moved = None
    if not inside and move_origin:
        dx, dy = cx - (rx0 + rx1) / 2.0, cy - (ry0 + ry1) / 2.0
        ctx.call("SetOrigin", dx, dy)
        moved = (dx, dy)
    record = {
        "status": "set", "unit": "document units (upi=%s); request bbox_mm in mm" % upi,
        "bbox_source": source, "bbox_doc": box, "rect_requested": (pw, ph),
        "rect_readback": ((rx0, ry0), (rx1, ry1)), "bbox_inside_rect": inside,
        "origin_moved": moved, "zoom": zoom_note, "zoom_after": ctx.call("GetZoom"),
        "before": before,
        "verified": bool(inside or moved),
    }

    def restore():
        ctx.call("SetLScale", layer, before["lscale"])
        if moved:
            ctx.call("SetOrigin", -moved[0], -moved[1])
        # Prior rect size from its corners; position was never set by us.
        (a, b), (c, d) = before["rect"]
        ctx.call("SetDrawingRect", abs(c - a), abs(b - d))
        ctx.call("SetVCenter", before["vcenter"])
        ctx.call("SetZoom", int(round(before["zoom"])))
    return record, restore


# ---- routes --------------------------------------------------------------

def _file_result(ctx, fmt, route, path, ret):
    if ctx.dry:
        return {"status": "dry_run", "route": route, "path": path, "api_return": ret}
    size = os.path.getsize(path) if os.path.exists(path) else 0
    ok = bool(ret) and size > 0
    return {"status": "ok" if ok else "failed", "route": route, "path": path,
            "api_return": ret, "bytes": size,
            "detail": None if ok else "api returned %r, file size %d" % (ret, size)}


def _direct(fmt, fn, ext, argf):
    def run(ctx):
        p = ctx.path(ext)
        ret = ctx.call(fn, *argf(p, ctx))
        return _file_result(ctx, fmt, "direct:vs.%s" % fn, p, ret)
    return run


def _sat(ctx):
    # ExportSAT exports the selection, so select first; selection is not saved state.
    ctx.call("SelectAll")
    try:
        p = ctx.path("sat")
        ret = ctx.call("ExportSAT", p, False)
    finally:
        ctx.call("DSelectAll")
    return _file_result(ctx, "sat", "direct:vs.ExportSAT", p, ret)


def _ifc(ctx):
    scheme = ctx.call("IFC_GetIFCScheme")
    p = ctx.path("ifc")
    ret = ctx.call("IFC_ExportNoUI", p)
    res = _file_result(ctx, "ifc", "direct:vs.IFC_ExportNoUI", p, ret)
    res["ifc_scheme_read"] = scheme
    return res


def _modal(fmt, route, runner):
    def run(ctx):
        if not ctx.allow_modal:
            return {"status": "unsupported", "route": route,
                    "detail": "no dialog-free route: the call opens a modal whose answers have no recorded preference keys; rerun with allow_modal to let a human answer it"}
        return runner(ctx)
    return run


def _dxfdwg(ctx):
    ctx.call("ExportDXFDWG")  # no arguments, returns nothing, path and version come from its dialog
    return {"status": "dialog_shown", "route": "modal:vs.ExportDXFDWG",
            "detail": "no return value and no path argument; verify the file by hand"}


def _png(ctx):
    ctx.call("DoMenuTextByName", "Export Image File", 0)  # legacy name, unverified on 2027
    return {"status": "dialog_shown", "route": "modal:vs.DoMenuTextByName('Export Image File', 0)",
            "detail": "returns nothing; verify the file by hand"}


def _pdf(ctx):
    p = ctx.path("pdf")
    opened = False
    try:
        if not ctx.call("AcquireExportPDFSettingsAndLocation", False):
            return {"status": "failed", "route": "modal:PDF lifecycle", "detail": "Acquire returned false (cancelled)"}
        opened = bool(ctx.call("OpenPDFDocument", p))
        pages = ctx.call("ExportPDFPages", ctx.opts.get("saved_view", "")) if opened else None
    finally:
        if opened:
            ctx.call("ClosePDFDocument")
    res = _file_result(ctx, "pdf", "modal:vs.AcquireExportPDFSettingsAndLocation+OpenPDFDocument+ExportPDFPages+ClosePDFDocument", p, opened)
    res["pages_return"] = pages
    return res


def _read_ws(ctx, name):
    h = ctx.call("GetObject", name)
    if not h:
        return None
    rows, cols = ctx.call("GetWSRowColumnCount", h)
    grid = []
    for r in range(1, rows + 1):  # 1-based is an assumption, see README
        row = []
        for c in range(1, cols + 1):
            v = ctx.call("GetWSCellStringN", h, r, c)
            row.append(v[0] if isinstance(v, tuple) else v)
        grid.append(row)
    return grid


def _worksheets(ctx, fmt):
    names = ctx.opts.get("worksheets") or []
    if not names:
        return None, {"status": "skipped", "route": "worksheet read", "detail": "no worksheet names in request; the binding has no worksheet enumerator"}
    data = {}
    for n in names:
        g = _read_ws(ctx, n)
        if g is None:
            return None, {"status": "failed", "route": "worksheet read", "detail": "vs.GetObject(%r) returned NIL" % n}
        data[n] = g
    return data, None


def _csv(ctx):
    data, err = _worksheets(ctx, "csv")
    if err:
        return err
    paths = []
    for n, grid in data.items():
        p = ctx.path("csv", "." + re.sub(r"[^A-Za-z0-9._-]", "_", n))
        if not ctx.dry:
            with open(p, "w", newline="") as f:
                csv.writer(f).writerows(grid)
        paths.append(p)
    return {"status": "dry_run" if ctx.dry else "ok", "route": "worksheet read (vs.GetWSCellStringN) + python csv", "paths": paths}


def _xlsx(ctx):
    data, err = _worksheets(ctx, "xlsx")
    if err:
        return err
    p = ctx.path("xlsx")
    if not ctx.call("EXL_NewBook", p):
        return {"status": "failed", "route": "vs.EXL_*", "detail": "EXL_NewBook returned false"}
    for n, grid in data.items():
        ctx.call("EXL_AddSheet", n)
        idx = ctx.call("EXL_GetSheetIndex", n)[1]
        for r, row in enumerate(grid, 1):
            for c, v in enumerate(row, 1):
                ctx.call("EXL_SetCellString", idx, r, c, v)
    ret = ctx.call("EXL_SaveAndCloseBook", p)
    return _file_result(ctx, "xlsx", "direct:vs.EXL_NewBook..EXL_SaveAndCloseBook (cells as display strings)", p, ret)


ROUTES = {
    "step": _direct("step", "ExportSTEP", "stp", lambda p, c: (p, False)),
    "iges": _direct("iges", "ExportIGES", "igs", lambda p, c: (p, False)),
    "stl": _direct("stl", "ExportSTL", "stl", lambda p, c: (p, True, float(c.opts.get("stl_tess", 100.0)), 2)),
    "sat": _sat,
    "ifc": _ifc,
    "dwg": _modal("dwg", "modal:vs.ExportDXFDWG", _dxfdwg),
    "dxf": _modal("dxf", "modal:vs.ExportDXFDWG", _dxfdwg),
    "png": _modal("png", "modal:DoMenuTextByName", _png),
    "pdf": _modal("pdf", "modal:PDF lifecycle", _pdf),
    "csv": _csv,
    "xlsx": _xlsx,
}


def export_case(case_id, out_dir, formats, bbox_mm=None, layers=(), dry_run=False,
                allow_modal=False, frame=True, move_origin=False, **opts):
    """Write each format; return one result dict per format, in request order."""
    vs = _vs(dry_run)
    ctx = Ctx(vs, case_id, out_dir, dry_run, allow_modal, opts)
    if not dry_run:
        os.makedirs(out_dir, exist_ok=True)
    results, restore, framing = [], (lambda: None), None
    try:
        for fmt in formats:
            fmt = fmt.lower()
            start = len(ctx.calls)
            if fmt in UNSUPPORTED:
                res = {"status": "unsupported", "route": "none", "detail": UNSUPPORTED[fmt]}
            elif fmt not in ROUTES:
                res = {"status": "unsupported", "route": "none", "detail": "unknown format"}
            else:
                if fmt in FRAMED and frame and framing is None and (allow_modal or dry_run):
                    framing, restore = frame_drawing(ctx, bbox_mm, layers, move_origin=move_origin)
                try:
                    res = ROUTES[fmt](ctx)
                except ForbiddenCall:
                    raise
                except Exception as e:
                    res = {"status": "error", "route": "exception", "detail": "%s: %s" % (type(e).__name__, e)}
                if fmt in FRAMED:
                    res["framing"] = framing
            res.update({"format": fmt, "case_id": case_id, "calls": ctx.calls[start:]})
            results.append(res)
    finally:
        restore()
    return results


def run_request(request_path):
    """In-app entry: read a JSON request, export, write results.json beside the outputs."""
    with open(request_path) as f:
        req = json.load(f)
    results = export_case(**req)
    if not req.get("dry_run"):
        with open(os.path.join(req["out_dir"], "results.json"), "w") as f:
            json.dump(results, f, indent=2, default=str)
    return results


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--case", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--formats", default=",".join(ALL_FORMATS))
    ap.add_argument("--bbox-mm", help="x0,y0,x1,y1 in millimetres")
    ap.add_argument("--worksheet", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--allow-modal", action="store_true", help="include the routes that open a modal dialog")
    a = ap.parse_args(argv)
    if not a.dry_run:
        ap.error("outside Vectorworks only --dry-run is supported")
    bbox = [float(v) for v in a.bbox_mm.split(",")] if a.bbox_mm else None
    res = export_case(a.case, a.out, a.formats.split(","), bbox_mm=bbox,
                      worksheets=a.worksheet, dry_run=True, allow_modal=a.allow_modal)
    print(json.dumps([{k: v for k, v in r.items() if k != "calls"} for r in res], indent=1, default=str))


if __name__ == "__main__":
    main(sys.argv[1:])
