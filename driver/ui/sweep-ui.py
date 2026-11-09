#!/usr/bin/env python3
"""Collect reference files by driving the Vectorworks export dialogs.

Usage:
  sweep-ui.py --format dwg                     collect every required row
  sweep-ui.py --format dxf --limit 3           collect three rows
  sweep-ui.py --format dxf --only CASE         collect one case
  sweep-ui.py --format dxf --only A,B,C        collect a list of cases
  sweep-ui.py --format png --dry-run           list the rows without exporting
  sweep-ui.py --format png --probe             open the route and dump the dialog
  sweep-ui.py --format dxf --probe --only CASE --active-layer LAYER
                                               dump the dialog with LAYER active
  sweep-ui.py --format pdf --only CASE --defaults
                                               export with each control the profile does not set as
                                               the dialog opens, and keep the file out of files/

Run this as the operator, outside a sandbox. Two steps need that account. The
`open` command starts the application through LaunchServices, and the Return key
that presses the default button of a save panel comes from System Events.

Every row proves the open document title before it exports, because an earlier
route exported from whichever document happened to be open and produced files
that carry the wrong case name. Every row writes its ledger line before the next
row starts. A row that fails records the exact symptom once and moves on.

A format whose route has not been measured yet carries empty route fields. Run
`--probe` for that format, read the dump it writes, and fill the table in.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
SCRATCH = os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-corpus")
# An evidence copy of this file sets ROOT to the store, so the helper comes from ROOT.
sys.path.insert(0, os.path.join(ROOT, "driver"))
from store_path import relative, resolve  # noqa: E402
from profile_names import artifact_suffix, shows_hidden  # noqa: E402
import focus  # noqa: E402
import pause  # noqa: E402
import run_provenance  # noqa: E402
import vw_lock  # noqa: E402
import vw_memory  # noqa: E402
# The vwx ui-* commands and native-script-send come from the build that driver/bin/BUILD.tsv
# lists. run_provenance refuses any other binary.
CLI = os.environ.get("VWX_CLI", os.path.join(ROOT, "driver", "bin", "vwx"))
SCRIPT_CLI = os.environ.get("VWX_SCRIPT_CLI", os.path.join(ROOT, "driver", "bin", "vwx"))
APP = os.environ.get("VW_APP", "/Applications/Vectorworks 2027/Vectorworks 2027.app")
EXE = os.path.join(APP, "Contents/MacOS/Vectorworks")
# A sweep that switches workspace switches back to this one at its end.
HOME_WORKSPACE = "Architect"
# Every save panel goes to PANEL. The panel reaches it through Recent Places with no
# key, so PANEL keeps one path across scratch folders and is never removed. Recent
# Places names a folder by its last path part only. An exporter can write its file
# inside a folder it creates there, so the search goes two levels deep.
PANEL = os.environ.get("ROSETTA_EXPORT_PANEL", VOLUME + "/Caches/tmp/rosetta-export-panel")
SEARCH_ROOTS = ((PANEL, 2),)
# A panel that ignores Go to Folder saves where it opened. These folders are read
# once after a missing file, to name where the file went.
REFUSED_ROOTS = ((os.path.expanduser("~/Documents"), 2), (os.path.expanduser("~"), 1))
FILES = os.path.join(ROOT, "files")
LEDGER = os.path.join(ROOT, "ledger", "corpus-ledger.jsonl")
DIALOG_LOG = os.path.join(SCRATCH, "dialog-log-sweep.tsv")
# The worktree state the run started from, stored in every record of the run.
PROVENANCE = {}
# The pair being exported. dismiss_modals writes each dialog it answers to the dialog log
# under this pair and to the pair's run record.
CURRENT = {"run_id": "", "case": "", "profile": "", "dialogs": []}
SOURCE_MAP = os.path.join(ROOT, "driver", "source-map.tsv")
REQUIRED = os.path.join(ROOT, "ledger", "required-pairs.tsv")
RUNS = os.path.join(ROOT, "runs")
CONTROL_ROLES = ("AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTextField")
PAGE_FIT_DIR = os.path.join(SCRATCH, "page-fit")
ACTIVE_LAYER_DIR = os.path.join(SCRATCH, "active-layer")
# The drawing extent fills this fraction of the page rect in each direction, measured
# from the page center. The A4 printable area is 571 x 816 of 595 x 842 pt, so 0.85
# keeps the drawing inside the printable area.
PAGE_FILL = 0.85
# A sheet layer prints at 1:1, so its page comes from the Current view radio. That page
# takes the aspect ratio of the document window. The driver sets the window to this
# position and size in screen points before Fit To Objects. 1440 / 1016 is the A-series
# ratio of 1.417.
SHEET_WINDOW = {"position": (0, 25), "size": (1440, 1016)}
PDF_RADIO = {
    "design": "radio/label/Export the whole printable area as one page",
    "sheet": "radio/label/Current view",
}

# Vectorworks writes each stroke at the pen weight of its object or class, in mils. The
# fixture objects hold 1 to 2 mils, and Quick Look draws those as grey hairlines.
# 0.25 mm is 9.84 mils, so 10 mils is the smallest pen at or above 0.25 mm.
PAGE_MIN_LW_MILS = 10

# Run on the working copy before a PDF export, through native-script-send or through
# Tools > Plug-ins > Run Script.... GetObjectVariableInt(layer, 154) is 1 for a design layer
# and 2 for a sheet layer.
# Pen step: ForEachObject visits every object with the criteria below and SetLW raises each
# pen weight under MIN_LW to MIN_LW. A walk over layers, groups, symbol definitions and
# viewport groups then raises any object that ForEachObject left under MIN_LW. SetClLW raises
# each class pen weight, which plug-in objects and dimensions draw with.
# Fit step, design layers only: the bbox is the union of the objects on visible design
# layers whose class is visible. Vectorworks draws the active class while GetCVis reads -1
# for it, so an object in the active class counts as visible. GetDrawingSizeRect is the page rect in world units, and it
# can keep its old size until a redraw, so the paper size and paper centre come from the
# first reading. SetVCenter puts the view centre on the bbox centre. HMove moves the objects
# of every design layer by the offset from the bbox centre to the page centre. SetLScale on
# every design layer makes the bbox fill FILL of the page in its binding axis. Text and
# dimension extents change with the layer scale, so the move and the scale repeat until both
# settle. HMove on a mirrored symbol or a rotated rectangle moves the bbox along another
# direction than the offset asked. Two trial moves measure that 2 x 2 response, and each move
# solves it for the offset to the page centre.
PAGE_FIT_PROGRAM = '''import json
import os
import time
import vs

OUT = %(out)r
FILL = %(fill)r
MIN_LW = %(min_lw)r
CRITERIA = "(INSYMBOL & INVIEWPORT & (ALL))"


def chain(first):
    obj = first
    while obj:
        yield obj
        obj = vs.NextObj(obj)


def inner(obj):
    kind = vs.GetTypeN(obj)
    if kind in (11, 16):
        return list(chain(vs.FInGroup(obj)))
    if kind == 92:
        return list(chain(vs.FInFolder(obj)))
    if kind == 122:
        found = []
        for part in (1, 2, 3):
            try:
                group = vs.GetVPGroup(obj, part)
            except Exception:
                group = None
            if group:
                found.append(group)
        return found
    return []


def raise_lw(obj, pen):
    try:
        weight = vs.GetLW(obj)
        if weight < MIN_LW:
            vs.SetLW(obj, MIN_LW)
            pen["raised"] += 1
            kind = str(vs.GetTypeN(obj))
            pen["raised_by_type"][kind] = pen["raised_by_type"].get(kind, 0) + 1
            pen["weights_before"][str(weight)] = pen["weights_before"].get(str(weight), 0) + 1
        else:
            pen["kept"] += 1
    except Exception as exc:
        pen["errors"] += 1
        pen.setdefault("error", "%%s: %%s" %% (type(exc).__name__, exc))


def new_pen():
    return {"raised": 0, "kept": 0, "errors": 0, "raised_by_type": {}, "weights_before": {}}


def pen_step():
    t0 = time.time()
    each = new_pen()
    each["criteria"] = CRITERIA
    try:
        vs.ForEachObject(lambda h: raise_lw(h, each), CRITERIA)
    except Exception as exc:
        each["call_error"] = "%%s: %%s" %% (type(exc).__name__, exc)
    walk = new_pen()
    stack = []
    layer = vs.FLayer()
    while layer:
        stack += list(chain(vs.FInLayer(layer)))
        layer = vs.NextLayer(layer)
    sym = vs.FSymDef()
    while sym:
        stack.append(sym)
        sym = vs.NextSymDef(sym)
    viewports, plugins = [], []
    while stack:
        obj = stack.pop()
        kind = vs.GetTypeN(obj)
        if kind not in (16, 92):
            raise_lw(obj, walk)
        if kind == 122:
            viewports.append(obj)
        if kind == 86:
            plugins.append(obj)
        stack += inner(obj)
    classes = {"raised": 0, "kept": 0}
    for i in range(1, vs.ClassNum() + 1):
        name = vs.ClassList(i)
        if vs.GetClLW(name) < MIN_LW:
            vs.SetClLW(name, MIN_LW)
            classes["raised"] += 1
        else:
            classes["kept"] += 1
    for obj in plugins:
        vs.ResetObject(obj)
    return {"min_lw_mils": MIN_LW, "for_each_object": each, "walk": walk, "classes": classes,
            "plugins_reset": len(plugins), "ms": round((time.time() - t0) * 1000)}, viewports


def design_layers():
    found = []
    layer = vs.FLayer()
    while layer:
        if vs.GetObjectVariableInt(layer, 154) == 1:
            found.append(layer)
        layer = vs.NextLayer(layer)
    return found


def bbox_of(layers, skipped=None):
    box = None
    shown = vs.ActiveClass()
    for layer in layers:
        for obj in chain(vs.FInLayer(layer)):
            name = vs.GetClass(obj)
            if name != shown and vs.GetCVis(name) == -1:
                if skipped is not None:
                    skipped.append(name)
                continue
            (ax, ay), (bx, by) = vs.GetBBox(obj)
            x0, x1, y0, y1 = min(ax, bx), max(ax, bx), min(ay, by), max(ay, by)
            if box is None:
                box = [x0, y0, x1, y1]
            else:
                box = [min(box[0], x0), min(box[1], y0), max(box[2], x1), max(box[3], y1)]
    return box


def centre(box):
    return [(box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0]


def shift(layers, move):
    for h in layers:
        for obj in list(chain(vs.FInLayer(h))):
            vs.HMove(obj, move[0], move[1])


def response(layers, shown, step):
    """The 2 x 2 map from an HMove offset to the bbox centre shift, measured with two moves."""
    cols = []
    for move in ([step, 0.0], [0.0, step]):
        before = centre(bbox_of(shown))
        shift(layers, move)
        after = centre(bbox_of(shown))
        cols.append([(after[0] - before[0]) / step, (after[1] - before[1]) / step])
    matrix = [[cols[0][0], cols[1][0]], [cols[0][1], cols[1][1]]]
    if abs(matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) < 1e-6:
        return [[1.0, 0.0], [0.0, 1.0]]
    return matrix


def fit_step(active, record):
    t0 = time.time()
    layers = design_layers()
    shown = [h for h in layers if h == active or vs.GetLVis(h) != -1]
    record["layers"] = [vs.GetLName(h) for h in shown]
    skipped = []
    box = bbox_of(shown, skipped)
    record["hidden_class_objects"] = len(skipped)
    record["bbox_before"] = box
    scale0 = vs.GetLScale(active)
    record["scale_before"] = scale0
    if box is None:
        record["status"] = "no_objects"
        return
    (a, b), (c, d) = vs.GetDrawingSizeRect()
    record["rect_before"] = [[a, b], [c, d]]
    paper_w, paper_h = abs(c - a) / scale0, abs(b - d) / scale0
    paper_c = [(a + c) / 2.0 / scale0, (b + d) / 2.0 / scale0]
    record["paper"] = [paper_w, paper_h]
    record["centre_before"] = centre(box)
    try:
        vs.SetVCenter(*centre(box))
        record["set_vcenter"] = "called"
    except Exception as exc:
        record["set_vcenter"] = "%%s: %%s" %% (type(exc).__name__, exc)
    (a2, b2), (c2, d2) = vs.GetDrawingSizeRect()
    record["rect_after_set_vcenter"] = [[a2, b2], [c2, d2]]
    scale = scale0
    steps = []
    matrix = None
    for _ in range(8):
        box = bbox_of(shown)
        new = max((box[2] - box[0]) / (FILL * paper_w), (box[3] - box[1]) / (FILL * paper_h))
        if new <= 0:
            record["status"] = "degenerate_bbox"
            return
        new = float("%%.4g" %% new)
        if new != scale:
            for h in layers:
                vs.SetLScale(h, new)
        changed = abs(new / scale - 1.0) > 0.005
        scale = new
        box = bbox_of(shown)
        page_c = [paper_c[0] * scale, paper_c[1] * scale]
        here = centre(box)
        off = [page_c[0] - here[0], page_c[1] - here[1]]
        still = (abs(off[0]) <= 0.002 * FILL * paper_w * scale
                 and abs(off[1]) <= 0.002 * FILL * paper_h * scale)
        if still and not changed:
            break
        if still:
            steps.append({"scale": scale, "move": [0.0, 0.0]})
            continue
        if matrix is None:
            matrix = response(layers, shown, 0.05 * paper_w * scale)
            record["move_matrix"] = matrix
            here = centre(bbox_of(shown))
            off = [page_c[0] - here[0], page_c[1] - here[1]]
        (m00, m01), (m10, m11) = matrix
        det = m00 * m11 - m01 * m10
        move = [(m11 * off[0] - m01 * off[1]) / det, (m00 * off[1] - m10 * off[0]) / det]
        shift(layers, move)
        steps.append({"scale": scale, "move": move})
    box = bbox_of(shown)
    page_c = [paper_c[0] * scale, paper_c[1] * scale]
    record["steps"] = steps
    record["scale_after"] = vs.GetLScale(active)
    record["bbox_after"] = box
    record["centre_after"] = centre(box)
    record["page_centre"] = page_c
    record["fill"] = [(box[2] - box[0]) / (paper_w * scale), (box[3] - box[1]) / (paper_h * scale)]
    record["centre_error"] = [(centre(box)[0] - page_c[0]) / (paper_w * scale),
                              (centre(box)[1] - page_c[1]) / (paper_h * scale)]
    (a, b), (c, d) = vs.GetDrawingSizeRect()
    record["rect_after"] = [[a, b], [c, d]]
    record["status"] = "scaled"
    record["fit_ms"] = round((time.time() - t0) * 1000)


def main():
    active = vs.ActLayer()
    kind = vs.GetObjectVariableInt(active, 154)
    record = {"layer": vs.GetLName(active), "layer_type_code": kind,
              "layer_type": "sheet" if kind == 2 else "design"}
    record["pen"], viewports = pen_step()
    if kind == 2:
        record["status"] = "sheet"
    else:
        fit_step(active, record)
    for vp in viewports:
        vs.UpdateVP(vp)
    record["viewports_updated"] = len(viewports)
    vs.ReDrawAll()
    return record


try:
    result = main()
except Exception as exc:
    result = {"status": "error", "detail": "%%s: %%s" %% (type(exc).__name__, exc)}
with open(OUT + ".part", "w") as handle:
    json.dump(result, handle, indent=1)
os.rename(OUT + ".part", OUT)
'''

# vs.Layer creates a layer that does not exist, so the program calls it only for a
# design or sheet layer the document already holds. vs.GetObject returns the class when a class
# has the same name as the layer, as in plugin.combined.09, so the program walks the layers.
ACTIVE_LAYER_PROGRAM = '''import json
import os
import vs

OUT = %(out)r
NAME = %(name)r

result = {"asked": NAME, "before": vs.GetLName(vs.ActLayer())}
try:
    layer = vs.FLayer()
    while layer and not (vs.GetLName(layer) == NAME and vs.GetObjectVariableInt(layer, 154) in (1, 2)):
        layer = vs.NextLayer(layer)
    result["found"] = bool(layer)
    if result["found"]:
        result["layer_type"] = "sheet" if vs.GetObjectVariableInt(layer, 154) == 2 else "design"
        vs.Layer(NAME)
    result["got"] = vs.GetLName(vs.ActLayer())
except Exception as exc:
    result["status"] = "error"
    result["detail"] = "%%s: %%s" %% (type(exc).__name__, exc)
with open(OUT + ".part", "w") as handle:
    json.dump(result, handle, indent=1)
os.rename(OUT + ".part", OUT)
'''

# One entry per required format. `menu` is the export menu path. `options` is the
# title of the export options dialog, and an empty value means the menu item opens
# the save panel directly. `setup` lists the controls to set before the dialog is
# accepted, as (control selector, wanted value). The control can be a popup, a radio
# or a text field, because the tool's --set handles each of those kinds. The name
# `tab` moves the dialog focus to the next field and the name `type` replaces the
# value in the focused field. Those two steps reach the image Width and Height
# fields, which sit below a group node that the selector grammar cannot walk.
# `save` is the title of the save panel, and an empty value accepts any title
# change. `ext` is the file name extension. `accept` names how the options dialog
# is accepted, either the button label, which defaults to OK, or the word return
# for the Return key. `view` lists menu paths to press before the export, for a
# profile that names a view.
FORMATS = {
    "dwg": {
        "menu": ["File", "Export", "Export DXF/DWG..."],
        "options": "DXF/DWG Export Options",
        "setup": [("pane", "General"), ("popup/sibling/Format:", "DWG")],
        "save": "Export to DWG Folder",
        "ext": "dwg",
        "navigate": "parent",
    },
    "dxf": {
        "menu": ["File", "Export", "Export DXF/DWG..."],
        "options": "DXF/DWG Export Options",
        "setup": [("pane", "General"), ("popup/sibling/Format:", "DXF (Text)")],
        "save": "Export to DXF Folder",
        "ext": "dxf",
        "navigate": "parent",
    },
    "png": {
        "menu": ["File", "Export", "Export Image File..."],
        "options": "Export Image File",
        # The image dialog opens with the Resolution field focused, so the Tab key
        # reaches the pixel Width field and then the Height field. The four Export
        # Area choices render the page, the current view, or the labelled rectangle
        # of a marquee. Every render of the page area is empty, because the exported
        # geometry sits away from the page origin. All Visible Objects renders the
        # drawing itself, and the pixel dimensions give it a legible raster.
        # The Dimensions panel holds two modes. Pixel Dimensions is the one that carries
        # Width and Height in pixels, and the Print Size mode that the dialog opens with
        # leaves those fields unsettable. The route selects the mode, then reaches the two
        # fields with the Tab key, whose selector grammar cannot walk them.
        "setup": [("popup/sibling/File Type:", "PNG"),
                  ("radio/label/All Visible Objects", "1"),
                  ("radio/label/Pixel Dimensions:", "1"),
                  ("tab", ""), ("type", "1600"),
                  ("tab", ""), ("type", "1200"),
                  ("tab", "")],
        "accept": "default",
        "view": [["View", "Standard Views", "Top/Plan"]],
        "save": "Export as Image File",
        "ext": "png",
    },
    "svg": {
        "menu": ["File", "Export", "Export Image File..."],
        "options": "Export Image File",
        "setup": [],
        "save": "Export Image File",
        "ext": "svg",
    },
    "pdf": {
        "menu": ["File", "Export", "Export PDF..."],
        "options": "Export PDF",
        "setup": [("popup/sibling/Format:", "PDF")],
        # The PDF page prints each design layer at its layer scale, and the screen zoom
        # leaves the page unchanged. The fixture geometry at 1:50 prints 1 to 3 pt wide.
        # fit_page sets the layer scale from the drawing extent before the export, and
        # it picks the page radio from the active layer type.
        "page_fit": True,
        "accept": "default",
        "save": "Export as PDF Document",
        "ext": "pdf",
    },
    "obj": {
        "menu": ["File", "Export", "Export OBJ (3D only)..."],
        "options": "Export OBJ Options",
        "setup": [],
        "accept": "Export",
        "save": "",
        "ext": "obj",
    },
    "fbx": {
        "menu": ["File", "Export", "Export FBX (3D only)..."],
        "options": "Export FBX Options",
        "setup": [],
        "accept": "Export",
        "save": "",
        "ext": "fbx",
    },
    "3ds": {
        "menu": ["File", "Export", "Export 3DS (3D only)..."],
        "options": "Export 3DS Options",
        # The dialog disables its Export button when the export scope holds nothing that
        # the current settings would write. Export 3D Loci is off on open, so a document
        # whose only object is a 3D locus leaves the button disabled and the press is
        # refused. Checking the box enables the button for that document alone, so it runs
        # as a rescue and the exported set of the other documents does not change.
        "rescue": [("checkbox/label/Export 3D Loci", "1")],
        "accept": "Export",
        "save": "",
        "ext": "3ds",
    },
    "gltf": {
        "menu": ["File", "Export", "Export gLTF/glb (3D only)..."],
        "options": "",
        "setup": [],
        "save": "Export gltf",
        "ext": "gltf",
        "workspace": "Rosetta glTF",
    },
    "stl": {
        "menu": ["File", "Export", "Export STL (3D only)..."],
        "options": "",
        "refuse": "Export STL opens a save panel with no options dialog, so the driver cannot choose "
                  "binary and the file takes the last format used. Run driver/scripted/sweep-scripted.sh "
                  "--formats stl, which calls vs.ExportSTL with binary set.",
        "setup": [],
        "save": "",
        "ext": "stl",
    },
    # Each profile names its own menu item. The panel proposes <case>.v<year>.vwx, the
    # artifact name of the profile. For a case name that holds an underscore it proposes
    # <case>_v<year>.vwx.
    "vwx": {
        "menu": [],
        "options": "",
        "setup": [],
        "save": "",
        "ext": "vwx",
        "names_by_profile": True,
    },
    "parasolid": {
        "menu": ["File", "Export", "Export Parasolid X_T (3D only)..."],
        "options": "Export Parasolid X_T Options",
        "setup": [],
        "accept": "Export",
        "save": "",
        "ext": "x_t",
    },
    "iges": {
        "menu": ["File", "Export", "Export IGES (3D only)..."],
        "options": "Export Options",
        "setup": [("checkbox/label/Export Solid as Trimmed Surfaces", "0", "solid_as_trimmed_surfaces")],
        "accept": "Export",
        "save": "Export IGES File",
        "ext": "igs",
    },
    "sat": {
        "menu": ["File", "Export", "Export SAT (3D only)..."],
        "options": "",
        "setup": [],
        "save": "",
        "ext": "sat",
    },
    "ifc": {
        "menu": ["File", "Export", "Export IFC Project..."],
        "options": "Export IFC Project",
        "setup": [],
        "accept": "default",   # AXPress on the Export button through ui-dialog fails
        "layer_mapping": True,
        "save": "",
        "ext": "ifc",
    },
    "csv": {
        "menu": ["File", "Export", "Export Worksheet..."],
        "options": "",
        "setup": [],
        "save": "",
        "ext": "csv",
    },
    "xlsx": {
        "menu": ["File", "Export", "Export Worksheet..."],
        "options": "",
        "setup": [],
        "save": "",
        "ext": "xlsx",
    },
}

# The Settings list of the DXF/DWG Export Options dialog, top to bottom.
DXF_DWG_PANES = ["General", "Classes/Layers", "Graphic Attributes", "Objects",
                 "Plug-in Objects", "Update", "Export Location"]

# Each control here is disabled in the DXF/DWG Export Options dialog while the named control
# holds the named value. export-settings.py fails on a profile that sets both.
DISABLED_BY = {
    "checkbox/label/Export invisible classes": (
        "radio/label/Export layers as DXF/DWG layers", "1", "the layers mapping"),
}


# Steps that depend on the profile, run after the steps of its format. The DXF/DWG and
# 3DS dialogs open with the settings of the last export, so each profile sets every
# control that a sibling profile of its format sets. The DXF/DWG dialog also opens on
# the pane of the last export. The dxf and dwg formats select the General pane first,
# and every DXF and DWG profile sets the layer mapping, the version and the 3D controls
# itself. A profile sets the invisible classes checkbox unless DISABLED_BY disables it
# under the profile's layer mapping. A ("pane", NAME) step selects NAME in the Settings
# list on the left of the dialog. A third item names the profile option that the
# control sets.
PROFILES = {
    "vwx.2026": {
        "menu": ["File", "Export", "Export as Vectorworks 2026 File..."],
        "save": "Export Vectorworks 2026 Drawing",
    },
    "vwx.2025": {
        "menu": ["File", "Export", "Export as Vectorworks 2025 File..."],
        "save": "Export Vectorworks 2025 Drawing",
    },
    "vwx.2024": {
        "menu": ["File", "Export", "Export as Vectorworks 2024 File..."],
        "save": "Export Vectorworks 2024 Drawing",
    },
    "vwx.2023": {
        "menu": ["File", "Export", "Export as Vectorworks 2023 File..."],
        "save": "Export Vectorworks 2023 Drawing",
    },
    "vwx.2022": {
        "menu": ["File", "Export", "Export as Vectorworks 2022 File..."],
        "save": "Export Vectorworks 2022 Drawing",
    },
    "dwg.all-content": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dwg_version"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "1", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "dwg.visible-only": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dwg_version"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "0", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "dxf.all-content": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("checkbox/label/Export viewports as 2D graphics in the model space", "0"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "1", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "3ds.mesh": {
        "setup": [("radio/label/All Visible Objects in Current Layer", "1")],
    },
    "3ds.mesh.all-layers": {
        "setup": [("radio/label/All Visible Objects in All Layers", "1", "export_scope")],
    },
    "dxf.all-content.acis-off": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "1", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "0", "acis_solids"),
            ("pane", "General"),
        ],
    },
    "dxf.visible-only": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "0", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "dxf.all-content.design-layers": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("popup/sibling/Export:", "All Visible Design Layers", "layer_scope"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export layers as DXF/DWG layers", "1", "classes_as_layers"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "dxf.all-content.design-layers.top-plan": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("popup/sibling/Export:", "All Visible Design Layers", "layer_scope"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export layers as DXF/DWG layers", "1", "classes_as_layers"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
        "view": [["View", "Standard Views", "Top/Plan"]],
    },
    "dxf.all-content.design-layers.classes": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("popup/sibling/Export:", "All Visible Design Layers", "layer_scope"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export classes as DXF/DWG layers", "1", "classes_as_layers"),
            ("checkbox/label/Export invisible classes", "1", "hidden_content"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
    },
    "dxf.top-plan": {
        "setup": [
            ("popup/sibling/Version:", "2018 / 2019 / 2020 / 2021 / 2022 / 2023 / 2024 / 2025 / 2026", "dxf_version"),
            ("popup/sibling/Export:", "All Visible Design Layers", "layer_scope"),
            ("pane", "Classes/Layers"),
            ("radio/label/Export layers as DXF/DWG layers", "1", "classes_as_layers"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "0"),
            ("checkbox/label/Export solids as ACIS solids", "1", "export_3d_as"),
            ("pane", "General"),
        ],
        "view": [["View", "Standard Views", "Top/Plan"]],
    },
    # Each dxf.opt profile loads the factory values with Settings <Default>, which also
    # sets Format back to DWG. dxf.opt.default keeps the factory values. Every other
    # dxf.opt profile changes one control from its factory value.
    "dxf.opt.default": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
        ],
    },
    "dxf.opt.flattened-2d": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Export as flattened 2D graphics", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.groups-anon-blocks": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Export groups as anonymous blocks", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.decompose-3d": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Decompose 3D symbols and groups", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.decompose-plugins": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Plug-in Objects"),
            ("checkbox/label/Decompose all", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.indexed-colors": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("radio/label/Use DXF/DWG indexed colors", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.fills-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export 2D fills", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.hatches-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export hatches", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.viewports-2d-model": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("checkbox/label/Export viewports as 2D graphics in the model space", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.triangulate-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Triangulate to preserve fills", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.records-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Export record formats", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.data-vis": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Use data visualization and overridden attributes", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.vp-custom-vis": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Use viewports' custom visibility for objects", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.spline-arcs": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Approximate polylines with spline type vertices using arcs", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.mapped-font": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Preserve mapped font on export", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.sia-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Support SIA dimensions", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.sia-text-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Preserve SIA dimension text appearance", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.linked-texts": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Objects"),
            ("checkbox/label/Export only linked texts", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.tile-fills-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export tile fills", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.image-fills-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export image fills", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.images-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export images", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.external-images-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Create external image files", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.hatch-files-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export hatch pattern files", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.hatch-fill-layers": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export hatches and 2D fills into separate DXF/DWG layers", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.linetype-blocks-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Export complex line types as blocks", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.weights-to-colors": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Graphic Attributes"),
            ("checkbox/label/Map line weights to colors", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.clip-objects": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("radio/label/Clip objects to lines and text", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.first-vp-scale-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("checkbox/label/Use first viewport’s scale in the sheet layer", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.georeferenced": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("checkbox/label/Export as georeferenced file", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.layers-separate": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("checkbox/label/Export layers as separate files", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.dlvp-separate-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "General"),
            ("checkbox/label/Export design layer viewports as separate files", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.single-layer-classes": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Classes/Layers"),
            ("checkbox/label/Export single layer for classes with same name", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.rescale-layers": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Classes/Layers"),
            ("checkbox/label/Rescale Layers to:", "1"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.update-vp-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Update"),
            ("checkbox/label/Update visible out of date viewports prior to exporting", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.reset-plugins-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Update"),
            ("checkbox/label/Reset all plug-in objects that require a reset prior to exporting", "0"),
            ("pane", "General"),
        ],
    },
    "dxf.opt.recalc-ws-off": {
        "setup": [
            ("popup/sibling/Settings:", "<Default>"),
            ("popup/sibling/Format:", "DXF (Text)"),
            ("pane", "Update"),
            ("checkbox/label/Recalculate worksheets prior to exporting", "0"),
            ("pane", "General"),
        ],
    },
}



def run(cmd, timeout=60):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout


def cli(*args, timeout=60):
    return run([CLI] + list(args), timeout=timeout)


def live_pid():
    _code, out = run(["pgrep", "-f", "MacOS/Vectorworks$"])
    if not out.strip():
        raise RuntimeError("no running Vectorworks process")
    return out.split()[0]


def unescape(text):
    """Turn the escape sequences ui-dialog prints back into real characters."""
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"r": "\n", "n": "\n", "t": "\t"}.get(nxt, nxt))
            i += 2
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def dump(pid_, timeout_ms=3000, max_nodes=0):
    args = ["ui-dialog", "--pid", pid_, "--expected-executable", EXE,
            "--timeout-ms", str(timeout_ms)]
    if max_nodes:
        args += ["--max-nodes", str(max_nodes)]
    _code, out = cli(*args)
    rows = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if parts and parts[0] != "node":
            rows[parts[0]] = [unescape(p) for p in parts[1:]]
    return rows, out


def title(pid_):
    rows, _raw = dump(pid_)
    return (rows.get("window_title") or [""])[0]


def modal_state(pid_):
    rows, _raw = dump(pid_)
    return (rows.get("message") or [""])[0], (rows.get("modal") or ["false"])[0]


def press_label(pid_, expect_text, label):
    _code, out = cli("ui-dialog", "--pid", pid_, "--expected-executable", EXE,
                     "--expected-text", expect_text, "--press", label, timeout=60)
    return "pressed" in out, out


def press_menu(pid_, items):
    args = ["ui-menu", "--pid", pid_, "--expected-executable", EXE]
    for it in items:
        args += ["--item", it]
    args += ["--materialize", "--press"]
    return cli(*args, timeout=60)


# Keys go to the Vectorworks process through CGEventPostToPid, which reaches its dialogs
# while another application stays in front. The macOS open and save panels run in the
# openAndSavePanelService process and ignore these keys, so the steps on those panels use
# in_front and System Events.
_CG = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
_CG.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_CG.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_CG.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
_CG.CGEventKeyboardSetUnicodeString.argtypes = [
    ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_uint16)]
_CG.CGEventPostToPid.argtypes = [ctypes.c_int, ctypes.c_void_p]
_CF = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_CF.CFRelease.argtypes = [ctypes.c_void_p]
COMMAND = 1 << 20
SHIFT = 1 << 17
KEY_A = 0


def post_key(keycode, flags=0, text=None, pid_=None):
    pid_ = int(pid_ or live_pid())
    units = None
    if text is not None:
        raw = text.encode("utf-16-le")
        units = (ctypes.c_uint16 * (len(raw) // 2)).from_buffer_copy(raw)
    for down in (True, False):
        event = _CG.CGEventCreateKeyboardEvent(None, keycode, down)
        if flags:
            _CG.CGEventSetFlags(event, flags)
        if units is not None:
            _CG.CGEventKeyboardSetUnicodeString(event, len(units), units)
        _CG.CGEventPostToPid(pid_, event)
        _CF.CFRelease(event)
        time.sleep(0.02)


class _Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_CG.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_CG.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, _Point, ctypes.c_uint32]
_CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
MOUSE_MOVED, LEFT_DOWN, LEFT_UP = 5, 1, 2


def post_click(x, y):
    """Click the left mouse button at screen point x, y through the HID event tap.

    The click lands on whatever window is under the point, so the caller brings
    Vectorworks to the front first."""
    point = _Point(float(x), float(y))
    for kind in (MOUSE_MOVED, LEFT_DOWN, LEFT_UP):
        event = _CG.CGEventCreateMouseEvent(None, kind, point, 0)
        _CG.CGEventPost(0, event)
        _CF.CFRelease(event)
        time.sleep(0.1)


def post_click_to_pid(x, y, pid_):
    """Click at screen point x, y with mouse events posted to pid_ only, with no front change."""
    point = _Point(float(x), float(y))
    for kind in (LEFT_DOWN, LEFT_UP):
        event = _CG.CGEventCreateMouseEvent(None, kind, point, 0)
        _CG.CGEventPostToPid(int(pid_), event)
        _CF.CFRelease(event)
        time.sleep(0.1)


def press_key(keycode, flags=0):
    post_key(keycode, flags)
    return 0, ""


def type_string(text):
    for char in text:
        post_key(0, 0, char)
    time.sleep(0.2)


def front_app():
    _code, out = osa('tell application "System Events" to get name of first process '
                     'whose frontmost is true', timeout=20)
    return out.strip()


FrontLost = focus.FrontLost
FRONT = {"before": ("", "")}


def press_default(window):
    """Press the default button of window, the button the Return key activates.

    A Return posted to the pid leaves the image and PDF dialogs open. AXPress on the
    window's AXDefaultButton accepts them with another application in front."""
    return osa('tell application "System Events" to tell process "Vectorworks" to tell '
               'window "%s" to perform action "AXPress" of (value of attribute '
               '"AXDefaultButton")' % window, timeout=60)


IFC_LAYERS = ('table 1 of scroll area 1 of group 1 of group 1 of group 1 of tab group 1 '
              'of window "%s"')
IFC_ADD = 'button "Add >" of group 2 of group 1 of tab group 1 of window "%s"'


def map_ifc_layers(window):
    """Map every design layer to the story on the Layer Mapping tab of the IFC dialog.

    The IFC exporter writes no file until a layer is mapped. It answers Export with the
    empty stories notice and returns to this tab. Selecting a row through the
    Accessibility API highlights it and leaves Add > disabled. A mouse click on the row
    enables it, so the step clicks the centre of row 1, read from the row at run time,
    and then selects every row with Command-A. Returns None and a detail, or a status
    and a detail when the pair stops."""
    tell = 'tell application "System Events" to tell process "Vectorworks" to '
    table = IFC_LAYERS % window
    code, out = osa(tell + 'get {position, size} of row 1 of ' + table, timeout=60)
    box = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", out)]
    if code != 0 or len(box) != 4:
        return "ifc_mapping_row_missing", out.strip()[:200]
    x, y = box[0] + box[2] / 2, box[1] + box[3] / 2

    def add_enabled():
        _code, enabled = osa(tell + 'get enabled of ' + IFC_ADD % window, timeout=60)
        return enabled.strip() == "true"

    started = time.time()
    post_click_to_pid(x, y, live_pid())
    time.sleep(0.5)
    post_key(KEY_A, COMMAND)
    time.sleep(0.5)
    route = "pid"
    if add_enabled():
        focus.tried("ifc-layer-click", True, time.time() - started)
    else:
        focus.tried("ifc-layer-click", False, time.time() - started, "Add > disabled")
        route = "front"
        with focus.in_front("ifc-layer-click", live_pid()):
            post_click(x, y)
            time.sleep(0.5)
            post_key(KEY_A, COMMAND)
            time.sleep(0.5)
    _code, picked = osa(tell + 'count (rows of %s whose selected is true)' % table, timeout=60)
    _code, total = osa(tell + 'count rows of ' + table, timeout=60)
    detail = "clicked %d,%d by %s, %s of %s rows selected" % (x, y, route, picked.strip(), total.strip())
    if not add_enabled():
        return "ifc_mapping_add_disabled", detail
    code, out = osa(tell + 'click ' + IFC_ADD % window, timeout=60)
    if code != 0:
        return "ifc_mapping_add_refused", detail + ": " + out.strip()[:160]
    return None, detail


def press_default_labelled(pid_, window, label):
    """Press the default button of window when its title is label, and name the path that pressed.

    ui-dialog reads 200 nodes of a window. The DXF/DWG options dialog of a document with 30
    layers lists 30 rows before its OK button, so a press by label answers
    refused_button_missing. AXDefaultButton reads the button at any node count. A Return
    posted to the pid presses it when the window has no AXDefaultButton."""
    code, out = osa('tell application "System Events" to tell process "Vectorworks" to tell window "%s" '
                    'to get title of (value of attribute "AXDefaultButton")' % window, timeout=60)
    if code == 0:
        if out.strip() != label:
            return None, "AXDefaultButton has the title %r" % out.strip()
        code, out = press_default(window)
        return ("AXDefaultButton" if code == 0 else None), out.strip()
    if title(pid_) != window:
        return None, "window %r is not in front of the dialogs" % window
    post_key(36, pid_=pid_)
    return "Return key", out.strip()


def front_keys(*actions):
    """Send System Events keys, each one only while Vectorworks is the front application.

    System Events types into whatever application is in front. The person works in
    another application during a run, so the script reads the front before every key
    and stops the row at the first key Vectorworks would not receive."""
    lines = ['tell application "System Events"']
    for action in actions:
        lines += ['if frontmost of process "Vectorworks" is false then error "front lost"',
                  action]
    code, out = osa("\n".join(lines + ["end tell"]), timeout=120)
    if code != 0:
        raise FrontLost("a key was due while another application was in front: "
                        + out.strip()[:120])


def panel_key(keycode, using=""):
    front_keys("key code %s%s" % (keycode, " using " + using if using else ""))


def panel_type(text):
    front_keys(*('keystroke "%s"' % c.replace("\\", "\\\\").replace('"', '\\"')
                 for c in text))


# The save panel is not always window 1. With another application in front, the
# document window can come first.
FIND_PANEL = "\n".join([
    'tell application "System Events" to tell process "Vectorworks"',
    "set panel to missing value",
    "repeat with w in windows",
    'if exists pop up button "Where:" of w then',
    "set panel to contents of w",
    "exit repeat",
    "end if",
    "end repeat",
    'if panel is missing value then return "no panel"'])


# With Vectorworks behind another application, the Save button of the DXF panel
# stays disabled after Recent Places sets the folder, and an AXPress on it saves nothing.
PRESS_SAVE = "\n".join([
    'if not (enabled of button "Save" of panel) then return "save disabled"',
    'perform action "AXPress" of button "Save" of panel',
    'return "pressed"'])


def folder_chain(path):
    """The folder and its parents as the Where menu lists them, up to the volume name."""
    parts = os.path.realpath(path).strip("/").split("/")
    if parts[0] == "Volumes":
        parts = parts[1:]
    return list(reversed(parts))


def recent_panel_folder():
    """Send the save panel to PANEL through Recent Places and press its Save button.

    Every action is an AXPress, so another application stays in front. The panel holds
    no path attribute. The Where menu lists the current folder and its parents above its
    first separator, and Save is pressed only when that list matches PANEL. Returns
    "pressed" after Save. Any other result means nothing was pressed: "missing" when
    Recent Places holds no PANEL entry, "elsewhere" when the list differs, "save disabled"
    when the Save button is disabled."""
    where = 'pop up button "Where:" of panel'
    script = "\n".join([
        FIND_PANEL,
        "try",
        'perform action "AXPress" of %s' % where,
        "delay 1",
        "set names to name of every menu item of menu 1 of %s" % where,
        "set recent to false",
        "repeat with i from 1 to count of names",
        "set n to item i of names",
        'if recent and n is "%s" then' % os.path.basename(PANEL),
        'perform action "AXPress" of menu item i of menu 1 of %s' % where,
        "delay 1",
        'perform action "AXPress" of %s' % where,
        "delay 1",
        "set chain to {}",
        "set parents to name of every menu item of menu 1 of %s" % where,
        "repeat with j from 1 to count of parents",
        "if item j of parents is missing value then exit repeat",
        "set end of chain to item j of parents",
        "end repeat",
        'perform action "AXCancel" of menu 1 of %s' % where,
        "delay 0.5",
        "if chain does not start with {%s} then return \"elsewhere\"" % ", ".join(
            '"%s"' % part for part in folder_chain(PANEL)),
        PRESS_SAVE,
        "end if",
        'if n is "Recent Places" then set recent to true',
        "end repeat",
        'perform action "AXCancel" of menu 1 of %s' % where,
        'return "missing"',
        "on error message",
        "try",
        'perform action "AXCancel" of menu 1 of %s' % where,
        "end try",
        'return "error: " & message',
        "end try",
        "end tell"])
    _code, out = osa(script, timeout=60)
    out = out.strip()
    if out.startswith("error:"):
        close_panel_menu()
    return out


def close_panel_menu():
    """Post Escape to the save panel service.

    A Where menu that stays open after a failed script leaves the panel's popup with no
    menu child, so every later AXPress on it opens nothing that System Events can read.
    Escape closes that menu and leaves the panel open."""
    pids = subprocess.run(["pgrep", "-f", "openAndSavePanelService"],
                          capture_output=True, text=True).stdout.split()
    for pid_ in pids:
        post_key(53, pid_=pid_)


def hold_front(step):
    """Give the front back when Vectorworks took it during step. Returns True when the front moved.

    FRONT["before"] keeps the last front application that is not Vectorworks, across rows.
    A memory restart or a document open can leave Vectorworks in front before a row starts,
    and the front then goes back to the application read before that."""
    now = focus.front()
    if now[1] not in ("", "Vectorworks"):
        FRONT["before"] = now
        return False
    return focus.give_back(step, live_pid(), FRONT["before"])


def note_front(row, step):
    """Record the frontmost application after a step of the row, and give the front back
    when Vectorworks took it during the step."""
    row.setdefault("front_app", []).append([step, front_app()])
    if hold_front(step):
        row.setdefault("front_given_back", []).append(step)


def select_pane(window, name):
    """Select one row of the Settings list on the left of the DXF/DWG dialog.

    Setting AXSelected on the row highlights it and leaves the pane unchanged. The
    arrow keys change the pane, so the step focuses the list, walks to its first row
    and then down to the named row. The read-back is the selected row's text."""
    if name not in DXF_DWG_PANES:
        raise ValueError("unknown pane " + name)
    target = "table 1 of scroll area 1 of window \"%s\"" % window
    script = "\n".join(
        ['tell application "System Events" to tell process "Vectorworks"',
         "set focused of %s to true" % target,
         "end tell"])
    read = "\n".join(
        ['tell application "System Events" to tell process "Vectorworks"',
         "get value of static text 1 of (first row of %s whose selected is true)" % target,
         "end tell"])
    got = ""
    for _ in range(2):
        osa(script, timeout=60)
        time.sleep(0.3)
        for _up in DXF_DWG_PANES:
            press_key(126)
            time.sleep(0.2)
        for _down in range(DXF_DWG_PANES.index(name)):
            press_key(125)
            time.sleep(0.2)
        seen = []

        def selected():
            _code, out = osa(read, timeout=60)
            seen.append(out.strip())
            return seen[-1] == name

        # The pane redraws after the selection moves, and set_popup reads the pane next.
        if wait_state("pane " + name, selected, timeout=1.0, minimum=0.5):
            return True, name
        got = seen[-1]
        time.sleep(1.0)
    return False, got


def type_text(text):
    """Replace the focused field's content with text.

    The field keeps its focus across the dialog's Tab order, and a set through
    ui-export-control reaches only the seven roles that tool walks. An image export
    needs the Width and Height fields, which sit below a plain group, so the driver
    reaches them with the keyboard. Command-A selects the old value and the typed
    text replaces it."""
    if not text.isdigit():
        raise ValueError("type_text takes digits only: " + text)
    press_key(KEY_A, COMMAND)
    type_string(text)
    return 0, ""


def note(fields):
    try:
        with open(DIALOG_LOG, "a") as f:
            f.write("\t".join(str(x).replace("\t", " ") for x in fields) + "\n")
    except OSError:
        pass


def is_save_panel(pid_):
    """True while a save panel is up, read from the panel's own text.

    The focused-window title is not always the panel's title. The dwg folder chooser
    reports the document title while its controls hold the panel's own text, so the
    panel is identified by the Save As field that every save panel carries."""
    txt, _is_modal = modal_state(pid_)
    return "Save As:" in txt


def save_panel_title(pid_, spec, before=""):
    """Report the title of the save panel, or None while no panel asks for the file.

    An unnamed sheet is never a save panel. The IFC exporter raises one to report an
    empty story mapping, and that sheet reports an empty title. A route that names its
    save panel accepts that title alone. A route that leaves the title empty accepts any
    other named window, because the exporter names the panel after the document in that
    case."""
    if is_save_panel(pid_):
        return spec["save"] or "save panel"
    current = title(pid_)
    if not current or current == spec["options"] or current == before:
        return None
    if spec["save"]:
        return current if current == spec["save"] else None
    return current


def is_replace_prompt(pid_):
    """True while the exporter asks whether to replace a file that exists."""
    txt, _is_modal = modal_state(pid_)
    return "Do you want to replace" in txt


def destination_folder(document, spec):
    """The folder the exporter writes into.

    The DXF/DWG exporter saves <stem>-<ext>/<stem>.<ext> below the folder of the
    panel, where <stem> is the name of the open document without .vwx. A converted
    source opens as "<case> v2027.vwx", so its stem differs from the case. The
    exporter keeps that folder between exports. A file left inside it raises a
    replace prompt on the next export of the same case, and that prompt holds every
    later menu press, so the folder is emptied before the panel is submitted. Every
    other exporter writes into PANEL."""
    if spec.get("navigate") == "parent":
        return os.path.join(PANEL, os.path.splitext(document)[0] + "-" + spec["ext"])
    return PANEL


def own_loose_files(case):
    """The files directly in PANEL whose name is the case plus one extension."""
    if not os.path.isdir(PANEL):
        return []
    return [os.path.join(PANEL, n) for n in sorted(os.listdir(PANEL))
            if os.path.splitext(n)[0] == case and os.path.isfile(os.path.join(PANEL, n))]


def export_running(pid_, document):
    """True while the application shows the progress window of the export of `document`.

    The dwg exporter of a solid model shows a window titled `Exporting "<document>"`, and
    it keeps that window up until it writes the file. The window is the completion signal,
    so a slow export is not mistaken for a missing file. An aborted export leaves its
    window up, so a window that names another document belongs to another export."""
    script = ('tell application "System Events" to tell process "Vectorworks" '
              'to get name of every window')
    code, out = run(["osascript", "-e", script], timeout=20)
    if code != 0:
        return False
    return exporting(out, document)


def exporting(window_names, document):
    return 'Exporting "%s"' % document in (part.strip() for part in window_names.split(","))


def dismiss_modals(pid_, where, log, keep=("",), cancel_save=False):
    """Answer whatever is up. One press per pass, so a second alert is caught next.

    A window whose title is in `keep` is left alone. The caller passes the title of
    the route's own options dialog there, because answering the exporter's notice can
    raise that dialog again, and cancelling it would abort the export. An empty entry
    is dropped, because a route that names no save panel passes an empty title, and an
    unnamed sheet reports an empty title of its own.

    A save panel is left up unless cancel_save is set. Between rows a save panel left
    by a failed row is modal and stops every later document from opening.

    A save-changes prompt gets Don't Save. Its Cancel keeps the document open.
    """
    keep = tuple(k for k in keep if k)
    pressed = None
    for _ in range(6):
        txt, is_modal = modal_state(pid_)
        if is_modal != "true" and not is_replace_prompt(pid_):
            return
        if title(pid_) in keep:
            return
        if is_save_panel(pid_) and not cancel_save:
            return
        action = "unanswered"
        if cancel_save:
            _code, out = osa(FIND_PANEL + '\nperform action "AXPress" of button "Cancel" '
                             'of panel\nreturn "pressed"\nend tell')
            if out.strip() == "pressed":
                action = "pressed Cancel on the save panel"
        if action == "unanswered" and txt != pressed:
            for label in ("OK", "Don't Save", "Cancel"):
                ok, _out = press_label(pid_, txt, label)
                if ok:
                    action = "pressed " + label
                    break
        # The "Getting options" progress window of the DXF/DWG export stays up after
        # its Cancel button reports a press, and closes on Escape.
        if action == "unanswered":
            press_key(53)
            action = "sent Escape"
        pressed = txt if action.startswith("pressed") else None
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        log.append({"where": where, "text": txt[:300], "action": action})
        CURRENT["dialogs"].append({"ts": stamp, "where": where, "action": action, "text": txt[:300]})
        note([stamp, CURRENT["run_id"], CURRENT["case"], CURRENT["profile"], where, action, txt[:300]])
        time.sleep(1.0)


def close_extra_documents(pid_, keep_case, log, limit=6):
    """Close every open document whose title is not the case this row owns."""
    for _ in range(limit):
        current = title(pid_)
        if not current:
            return
        if keep_case is not None and current == keep_case + ".vwx":
            return
        _code, out = press_menu(pid_, ["File", "Close"])
        if "pressed" not in out:
            return
        log.append({"where": "close-extra", "text": current, "action": "closed"})
        wait_state("close " + current, lambda: modal_state(pid_)[1] == "true" or title(pid_) != current,
                   timeout=1.5)
        txt, is_modal = modal_state(pid_)
        if is_modal == "true" and txt:
            for label in ("Don't Save", "Cancel", "OK"):
                ok, _ = press_label(pid_, txt, label)
                if ok:
                    log.append({"where": "close-extra", "text": txt[:200],
                                "action": "pressed " + label})
                    break
            else:
                press_key(53)
        time.sleep(0.5)


def wait_state(label, check, timeout, interval=0.25, minimum=0.0):
    """Wait until check() returns a true value and return it, or return None after timeout seconds.

    The first check runs after minimum seconds. Each wait writes its seconds, and whether
    the state or the timeout ended it, to the dialog log."""
    started = time.time()
    if minimum:
        time.sleep(minimum)
    while True:
        value = check()
        waited = time.time() - started
        if value or waited >= timeout:
            break
        time.sleep(min(interval, timeout - waited))
    note([time.strftime("%Y-%m-%dT%H:%M:%S%z"), CURRENT["run_id"], CURRENT["case"], CURRENT["profile"],
          "wait " + label, "state" if value else "timeout", "%.2f s of %.1f s" % (waited, timeout)])
    return value or None


def wait_for(check, tries=40, interval=0.5):
    for _ in range(tries):
        value = check()
        if value:
            return value
        time.sleep(interval)
    return None


def profile_revision(profile):
    path = os.path.join(ROOT, "driver", "inventory", "pack-skeleton", "profiles", profile + ".json")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f).get("profile_revision")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def find_exact(roots, name, since):
    """The file called `name`, written after `since`, inside one search root."""
    wanted = name.casefold()
    for directory, depth in roots:
        base_depth = directory.rstrip("/").count("/")
        for base, dirs, names in os.walk(directory):
            if base.count("/") - base_depth >= depth:
                dirs[:] = []
            for candidate in names:
                if candidate.casefold() != wanted:
                    continue
                path = os.path.join(base, candidate)
                try:
                    if os.path.getmtime(path) >= since:
                        return path
                except OSError:
                    pass
    return None


def find_any(roots, names, since):
    """The first file found under any of `names`, written after `since`."""
    for name in names:
        found = find_exact(roots, name, since)
        if found:
            return found
    return None


def clear_output_folder(folder):
    """Empty one output folder so the save panel never asks to replace a file.

    Only files and links directly inside the folder are removed, then the folder
    itself once it is empty. A nested directory stops the removal."""
    if not os.path.isdir(folder):
        return
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.isdir(path) and not os.path.islink(path):
            raise RuntimeError("refusing to empty a folder that holds " + path)
        os.unlink(path)
    os.rmdir(folder)


def stale_artifacts(roots, name):
    """Every path the artifact name can occupy inside the search roots.

    A second run of one row must not meet a replace prompt, so the path the export
    would write to is cleared before the panel is accepted. The name carries the
    case name, so it names one artifact and nothing else. A path that two roots both
    reach is reported once, because the caller removes each path it reads."""
    wanted = name.casefold()
    found = []
    seen = set()
    for directory, depth in roots:
        base_depth = directory.rstrip("/").count("/")
        for base, dirs, names in os.walk(directory):
            if base.count("/") - base_depth >= depth:
                dirs[:] = []
            for candidate in names:
                if candidate.casefold() != wanted:
                    continue
                path = os.path.join(base, candidate)
                if path in seen:
                    continue
                seen.add(path)
                found.append(path)
    return found


def prior_sidecars(case, profile):
    """Every sidecar name that an earlier run recorded for this case and profile.

    The DWG and DXF exporters name the raster sidecar `Bitmap<seconds since 1904>.jpg`,
    so each run writes a new name and the earlier names stay in the case folder. The
    names come from the run records and from the ledger lines that carry `sidecars`."""
    names = set()
    runs = os.path.join(ROOT, "runs")
    record = case + "." + profile + ".json"
    for run in os.listdir(runs) if os.path.isdir(runs) else ():
        path = os.path.join(runs, run, "records", record)
        try:
            with open(path) as f:
                names.update(json.load(f).get("sidecars") or ())
        except (OSError, ValueError, AttributeError):
            pass
    try:
        with open(LEDGER) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("case") == case and entry.get("profile") == profile:
                    names.update(entry.get("sidecars") or ())
    except OSError:
        pass
    return names


def retire_sidecars(case, profile, keep, run_id):
    """Move the earlier sidecars of one artifact out of its case folder.

    The files go to SCRATCH/retired-sidecars/<run_id>/<case>/ so the evidence stays on
    disk. A name in `keep` was written by this run and stays beside the artifact."""
    dest_dir = os.path.join(FILES, case)
    retire_dir = os.path.join(SCRATCH, "retired-sidecars", run_id, case)
    retired = []
    for sidecar in sorted(prior_sidecars(case, profile) - set(keep)):
        path = os.path.join(dest_dir, sidecar)
        if os.path.basename(sidecar) != sidecar or not os.path.isfile(path):
            continue
        os.makedirs(retire_dir, exist_ok=True)
        shutil.move(path, os.path.join(retire_dir, sidecar))
        retired.append(sidecar)
    return retired


def png_size(path):
    """The pixel width and height in a PNG header, or None for other bytes.

    The header holds the two numbers in the eight bytes after the signature and the
    IHDR tag, each as a four byte big endian integer."""
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


def wait_for_file(find, running, refused, limit=240, poll=0.5):
    """The exported file that `find()` returns, or None at the limit or after a refused save.

    A closed progress window ends the wait only after the window was seen. Vectorworks can write
    the file while System Events reads no `Exporting` window. The DXF export of the whole
    358 MB sample drawing did so about 100 s after the save."""
    window_seen = False
    deadline = time.time() + limit
    while time.time() < deadline:
        found = find()
        if found:
            return found
        if running():
            window_seen = True
        elif window_seen:
            return wait_state("file after export window", find, timeout=2.0, minimum=0.5, interval=0.5)
        elif refused():
            return None
        time.sleep(poll)
    return None


def settled(path, running, quiet=1.5, limit=240):
    """Wait until the export ends and the file stops growing, so a partial write is never sealed.

    `running()` is true while the progress window of the export is up. A writer can pause
    longer than the quiet period while that window is up, so the size counts only after it
    closes. The size and the modification time must then hold still for the quiet period,
    and the file must hold at least one byte."""
    last = None
    deadline = time.time() + limit
    while time.time() < deadline:
        if running():
            last = None
            time.sleep(quiet)
            continue
        try:
            info = os.stat(path)
        except OSError:
            return False
        current = (info.st_size, info.st_mtime_ns)
        if info.st_size > 0 and last == current:
            return True
        last = current
        time.sleep(quiet)
    return False


def set_popup(pid_, window, sel, value):
    """Set one popup to a value, and leave it alone when it already holds it.

    Vectorworks remembers the format of the last export, so a row that runs second
    already holds the wanted value. The tool refuses a set whose --expect-current
    does not match, so read the control first and quote back the value it reports.
    A set needs more than one apply. The first opens the menu, a later one picks."""
    read = ["ui-export-control", "--pid", pid_, "--expected-executable", EXE,
            "--window-title", window, "--native", "--control", sel]
    current = None
    started = time.time()
    for attempt in range(3):
        if attempt:
            # A pane of the DXF/DWG dialog redraws after a change of the Export scope,
            # and a read during the redraw finds no control.
            time.sleep(1.0)
        _code, out = cli(*read, timeout=60)
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[0] == "value":
                current = unescape(line.split("\t", 1)[1])
        if current is not None:
            break
    note([time.strftime("%Y-%m-%dT%H:%M:%S%z"), CURRENT["run_id"], CURRENT["case"], CURRENT["profile"],
          "wait popup " + sel, "state" if current is not None else "timeout",
          "%.2f s, %d reads" % (time.time() - started, attempt + 1)])
    if current is None:
        reasons = [l for l in out.splitlines() if l.startswith(("refused", "control"))]
        return False, "no value in the control report: " + " | ".join(reasons)
    if current == value:
        return True, "already " + value

    plan = read + ["--set", value, "--expect-current", current]
    _code, out = cli(*plan, timeout=60)
    token = None
    for line in out.splitlines():
        if line.startswith("authorization_required") and "\t" in line:
            token = line.split("\t", 1)[1]
    if not token:
        reasons = [l for l in out.splitlines() if l.startswith(("refused", "current", "control"))]
        return False, "no authorization token in the plan: " + " | ".join(reasons)
    last = ""
    for _ in range(5):
        _code, out = cli(*(plan + ["--apply", "--authorize", token]), timeout=60)
        last = out
        if "readback_matches_request\tyes" in out:
            return True, out
        time.sleep(1.0)
    keep = ("refused", "dispatch", "menu_item", "set_readback", "readback", "result")
    return False, " | ".join(l for l in last.splitlines() if l.startswith(keep))


def read_dialog(pid_, window):
    """Every checkbox, radio, popup and text field of window, with its value and whether it is enabled.

    A popup or text field has no title, so it takes the text of the static label before it."""
    _code, tree = cli("ui-export-control", "--pid", pid_, "--expected-executable", EXE,
                      "--window-title", window, "--native", "--native-tree", timeout=120)
    controls, label = [], ""
    for line in tree.splitlines():
        cells = [unescape(c) for c in line.split("\t")]
        if len(cells) < 8 or cells[0] != "node":
            continue
        role, name, value, enabled = cells[2], cells[4], cells[5], cells[7]
        if role == "AXStaticText":
            label = value
        elif role in CONTROL_ROLES:
            controls.append({"role": role, "label": name or label, "value": value, "enabled": enabled})
    return controls, tree


def keeping(case, run_id, defaults):
    """Where the exported file goes, and whether the row writes a ledger line, retires the sidecars of
    the stored pair and may run a rescue step. A --defaults file stays in its run folder."""
    if defaults:
        return {"dest_dir": os.path.join(RUNS, run_id, "defaults", case), "ledger": False,
                "retire_sidecars": False, "rescue": False}
    return {"dest_dir": os.path.join(FILES, case), "ledger": True, "retire_sidecars": True, "rescue": True}


def artifact_name(case, profile, spec):
    return case + artifact_suffix(profile) + "." + spec["ext"]


def prepare_document(pid_, case, src, log):
    """Copy the source, open the copy, and prove the document identity.

    The copy keeps a sealed source read-only. The title check refuses to export
    from a document that is not the case, which is how an earlier route produced
    files carrying the wrong case name."""
    work = os.path.join(SCRATCH, "work-sources", case + ".vwx")
    os.makedirs(os.path.dirname(work), exist_ok=True)
    if os.path.exists(work):
        os.remove(work)
    subprocess.run(["cp", src, work], check=True)
    os.chmod(work, 0o644)
    run(["open", "-g", "-a", APP, work], timeout=90)
    got = wait_for(lambda: document_up(pid_, case, log), tries=40)
    dismiss_modals(pid_, "after-open", log)
    return work, got


# A file of an older version raises the conversion alert in a window titled "Vectorworks", and the
# document then opens as "<case> v2027.vwx". The "Opening File" progress window has the same title.
CONVERSION_TEXT = "This file was created with an older version of Vectorworks."


def document_up(pid_, case, log):
    """The window title once the document of case is in front, else None."""
    current = title(pid_)
    if current in (case + ".vwx", case + " v2027.vwx"):
        return current
    if current == "Vectorworks":
        txt, is_modal = modal_state(pid_)
        if is_modal == "true" and txt.startswith(CONVERSION_TEXT):
            ok, _out = press_label(pid_, txt, "OK")
            log.append({"where": "open", "text": txt[:300], "action": "pressed OK" if ok else "unanswered"})
    return None


def frame_document(pid_, profile, row):
    """Show every object, then fit the view. Both results are recorded."""
    view = {}
    _code, out = press_menu(pid_, ["View", "Zoom", "Fit To Objects"])
    view["fit"] = "pressed" if "pressed" in out else "refused"
    if shows_hidden(profile):
        for step in ("Class", "Layer"):
            _code, out = press_menu(pid_, ["View", step + " Options", "Show Others"])
            view[step.lower()] = "pressed" if "pressed" in out else "refused"
    row["view_steps"] = view


def osa(script, timeout=30):
    return run(["osascript", "-e", script], timeout=timeout)


def run_script(pid_, program, log):
    """Press Tools > Plug-ins > Run Script... and pick the program in the Go to field.

    make-sources.py runs its recipes through the same menu item. The direct route
    `vwx native-script-send --program` returns `transport failed` from a sandboxed
    shell."""
    code, out = osa('tell application "System Events" to tell process "Vectorworks" '
                    'to click menu item "Run Script..." of menu 1 of menu item "Plug-ins" '
                    'of menu 1 of menu bar item "Tools" of menu bar 1')
    log.append({"where": "run-script", "text": out.strip()[:90], "action": "click %d" % code})
    if not wait_for(lambda: (title(pid_) == "Choose Script File") or None, tries=40):
        return False
    with focus.in_front("run-script-go-to-folder", pid_):
        panel_key(5, "{command down, shift down}")
        opened = wait_state("script sheet open", script_sheet_open, timeout=1.5, minimum=0.3)
        panel_key(0, "command down")
        time.sleep(0.5)
        panel_type(program)
        time.sleep(2.0)
        panel_key(36)
        # The panel selects the file after the sheet closes, and the next Return opens it.
        # A sheet that never read as open gives no closed state to wait on.
        if opened:
            wait_state("script sheet closed", lambda: not script_sheet_open(), timeout=3.0, minimum=1.0)
        else:
            time.sleep(3.0)
        panel_key(36)
    return bool(wait_for(lambda: (modal_state(pid_)[1] != "true") or None, tries=60))


def script_sheet_open():
    """True when the Choose Script File panel shows its Go to Folder sheet."""
    _code, out = osa('tell application "System Events" to tell process "Vectorworks" to return '
                     '(exists sheet 1 of window "Choose Script File") as text')
    return out.strip() == "true"


def sheet_open():
    """True when the save panel shows a sheet, such as Go to Folder. Read through AX only."""
    _code, out = osa("\n".join([FIND_PANEL, "return (exists sheet 1 of panel) as text", "end tell"]))
    return out.strip() == "true"


def save_if_panel_in(folder):
    """Press Save through AX only when the Where menu lists folder and its parents first.

    Returns "pressed", "elsewhere", "save disabled", "no panel" or an error text. Nothing
    is pressed unless the result is "pressed"."""
    where = 'pop up button "Where:" of panel'
    _code, out = osa("\n".join([
        FIND_PANEL,
        "try",
        'perform action "AXPress" of %s' % where,
        "delay 1",
        "set chain to {}",
        "set parents to name of every menu item of menu 1 of %s" % where,
        "repeat with j from 1 to count of parents",
        "if item j of parents is missing value then exit repeat",
        "set end of chain to item j of parents",
        "end repeat",
        'perform action "AXCancel" of menu 1 of %s' % where,
        "delay 0.5",
        "if chain does not start with {%s} then return \"elsewhere\"" % ", ".join(
            '"%s"' % part for part in folder_chain(folder)),
        PRESS_SAVE,
        "on error message",
        'return "error: " & message',
        "end try",
        "end tell"]), timeout=60)
    return out.strip()


def save_to_folder_by_pid(folder, pid_):
    """Try the Go to Folder sheet with keys posted to pid_, and press Save only in folder.

    Each key is checked before the next one. Cmd+Shift+G must open a sheet, or no
    more keys go. After the typed path and the sheet's Return, the sheet must be
    gone and the Where menu must list folder. Save is then an AX press. Returns
    "pressed" or the step that failed. A failed try leaves the name field as it was,
    or leaves the sheet open with the path typed into it."""
    if sheet_open():
        return "sheet already open"
    post_key(5, COMMAND | SHIFT, pid_=pid_)
    if not wait_for(lambda: sheet_open() or None, tries=6):
        return "Cmd+Shift+G opened no sheet"
    post_key(KEY_A, COMMAND, pid_=pid_)
    time.sleep(0.5)
    for char in folder:
        post_key(0, 0, char, pid_=pid_)
    time.sleep(1.0)
    post_key(36, pid_=pid_)
    if not wait_for(lambda: (not sheet_open()) or None, tries=6):
        return "the sheet stayed open after Return"
    return save_if_panel_in(folder)


def go_to_folder(folder):
    """Send the open save panel to folder through its Go to Folder sheet.

    The sheet takes its path only from typed System Events keys while Vectorworks is in
    front. Setting its field through the Accessibility API fills the field, and neither
    AXConfirm nor a Return posted to either pid makes the sheet go.

    `ui-export-control --navigate` fails on the glTF and OBJ save panels with `target
    window or sheet is absent`, and its read of the Where popup times out after the
    sheet closes. System Events reaches the sheet, as it does in run_script. The caller
    holds Vectorworks in front through in_front. A save uses it under --front, or when Recent Places
    holds no PANEL entry."""
    panel_key(5, "{command down, shift down}")
    opened = wait_state("folder sheet open", sheet_open, timeout=1.5, minimum=0.3)
    panel_key(0, "command down")
    time.sleep(0.5)
    panel_type(folder)
    time.sleep(2.0)
    panel_key(36)
    # The Where menu takes the folder after the sheet closes, and the caller presses Save next.
    # A sheet that never read as open gives no closed state to wait on.
    if opened:
        wait_state("folder sheet closed", lambda: not sheet_open(), timeout=2.0, minimum=1.0)
    else:
        time.sleep(2.0)


def set_sheet_window(row):
    """Put the front document window at SHEET_WINDOW and record the size read back."""
    x, y = SHEET_WINDOW["position"]
    w, h = SHEET_WINDOW["size"]
    target = 'tell application "System Events" to tell process "Vectorworks" to '
    osa(target + "set position of window 1 to {%d, %d}" % (x, y))
    osa(target + "set size of window 1 to {%d, %d}" % (w, h))

    def size():
        _code, out = osa(target + "get size of window 1")
        return tuple(int(v) for v in out.replace(",", " ").split() if v.strip().lstrip("-").isdigit())

    sizes = []
    wait_state("window size", lambda: sizes.append(size()) or sizes[-1] == (w, h), timeout=1.0)
    got = sizes[-1]
    row["window_size"] = list(got)
    return got == (w, h)


def fit_program(result):
    """The page-fit program text that writes its record to the path result."""
    return PAGE_FIT_PROGRAM % {"out": result, "fill": PAGE_FILL, "min_lw": PAGE_MIN_LW_MILS}


def send_script(pid_, program):
    """Run program through native-script-send. True when the transport acknowledges it."""
    _code, out = run([SCRIPT_CLI, "native-script-send", "--pid", pid_,
                      "--expected-executable", EXE, "--program", program,
                      "--operator-authorized", "--timeout-ms", "15000"], timeout=30)
    return "transport\tacknowledged" in out


def fit_page(pid_, case, row, log):
    """Raise the pen weights, centre and scale the design layers, and choose the PDF page radio.

    Returns the extra setup steps for the options dialog, or None when the row fails.
    A design layer keeps the printable-area page, and the program puts the drawing on the
    page centre across PAGE_FILL of that page. A sheet layer gets the Current view page on a
    window of fixed size after Fit To Objects. The radio is set on every row, because
    the dialog keeps the radio of the previous export. The program writes its record with
    a rename, so the record is complete when the path appears. The poll gap is 0.05 s."""
    os.makedirs(PAGE_FIT_DIR, exist_ok=True)
    program = os.path.join(PAGE_FIT_DIR, case + ".py")
    result = os.path.join(PAGE_FIT_DIR, case + ".json")
    if os.path.exists(result):
        os.remove(result)
    with open(program, "w") as f:
        f.write(fit_program(result))
    started = time.time()
    sent = send_script(pid_, program)
    row["page_fit_route"] = "native-script-send" if sent else "run-script"
    if not sent and not run_script(pid_, program, log):
        row["status"] = "page_fit_script_refused"
        dismiss_modals(pid_, "page-fit", log)
        return None
    if not wait_for(lambda: os.path.exists(result) or None, tries=300, interval=0.05):
        row["status"] = "page_fit_no_result"
        dismiss_modals(pid_, "page-fit", log)
        return None
    row["page_fit_ms"] = round((time.time() - started) * 1000)
    with open(result) as f:
        fit = json.load(f)
    row["page_fit"] = fit
    if fit.get("status") == "error":
        row["status"] = "page_fit_error"
        return None
    kind = fit.get("layer_type", "design")
    if kind == "sheet":
        if not set_sheet_window(row):
            row["status"] = "window_size_refused"
            return None
    _code, out = press_menu(pid_, ["View", "Zoom", "Fit To Objects"])
    row.setdefault("view_steps", {})["fit_after_page_fit"] = (
        "pressed" if "pressed" in out else "refused")
    return [(PDF_RADIO[kind], "1")]


def set_active_layer(pid_, case, name, row, log):
    """Make the design or sheet layer name active before the export menu. The current-layer scope of the
    3DS and IGES dialogs exports the active layer. True when Vectorworks reports name as active."""
    os.makedirs(ACTIVE_LAYER_DIR, exist_ok=True)
    program = os.path.join(ACTIVE_LAYER_DIR, case + ".py")
    result = os.path.join(ACTIVE_LAYER_DIR, case + ".json")
    if os.path.exists(result):
        os.remove(result)
    with open(program, "w") as f:
        f.write(ACTIVE_LAYER_PROGRAM % {"out": result, "name": name})
    sent = send_script(pid_, program)
    row["active_layer_route"] = "native-script-send" if sent else "run-script"
    if not sent and not run_script(pid_, program, log):
        row["status"] = "active_layer_script_refused"
        dismiss_modals(pid_, "active-layer", log)
        return False
    if not wait_for(lambda: os.path.exists(result) or None, tries=300, interval=0.05):
        row["status"] = "active_layer_no_result"
        return False
    with open(result) as f:
        row["active_layer"] = json.load(f)
    if row["active_layer"].get("got") != name:
        row["status"] = "active_layer_not_set"
        return False
    return True


def format_spec(fmt, profile):
    """The FORMATS entry of fmt, with the menu path and save panel title that PROFILES names."""
    spec = dict(FORMATS[fmt])
    for key in ("menu", "save"):
        if key in PROFILES.get(profile or "", {}):
            spec[key] = PROFILES[profile][key]
    return spec


def route_plan(fmt, profile, active_layer=None, defaults=False):
    """The ordered UI steps collect_row runs for one row. --dry-run prints this list."""
    spec = format_spec(fmt, profile)
    steps = ["open copy of source, prove window title",
             "menu View > Zoom > Fit To Objects"]
    if active_layer:
        steps.append("run script: make layer %s active" % active_layer)
    if shows_hidden(profile):
        steps += ["menu View > Class Options > Show Others",
                  "menu View > Layer Options > Show Others"]
    extra = PROFILES.get(profile, {})
    steps += ["menu " + " > ".join(v) for v in spec.get("view", []) + extra.get("view", [])]
    if spec.get("page_fit"):
        steps += ["run script page-fit program (PAGE_FILL=%s, PAGE_MIN_LW_MILS=%s)" % (
                      PAGE_FILL, PAGE_MIN_LW_MILS),
                  "if sheet layer: window position %s size %s" % (
                      SHEET_WINDOW["position"], SHEET_WINDOW["size"]),
                  "menu View > Zoom > Fit To Objects"]
    if spec["menu"]:
        steps.append("menu " + " > ".join(spec["menu"]))
    for item in spec.get("setup", []) + extra.get("setup", []):
        steps.append("set %s = %s" % (item[0], item[1]))
    if spec.get("page_fit"):
        steps.append("set %s = 1 (design) or %s = 1 (sheet)" % (
            PDF_RADIO["design"], PDF_RADIO["sheet"]))
    if defaults and spec["options"]:
        steps.append("read every control of the options dialog, and no rescue step")
    if spec["options"]:
        steps.append("accept options with " + spec.get("accept", "OK"))
    steps.append("save panel Return, move file to "
                 + ("runs/<run_id>/defaults/<case>/" if defaults else "files/<case>/"))
    return steps


def collect_row(args, case, profile, src, sources_sha, run_id, log):
    spec = format_spec(args.format, profile)
    row = {"case": case, "profile": profile, "profile_revision": profile_revision(profile),
           "format": args.format, "run_id": run_id,
           "source": relative(src, ROOT), "source_sha256": sources_sha}
    defaults = getattr(args, "defaults", False)
    keep = keeping(case, run_id, defaults)
    if defaults:
        row["defaults"] = True
    pid_ = live_pid()
    focus.CONTEXT.update(run_id=run_id, case=case, profile=profile)
    note_front(row, "start")

    _work, got = prepare_document(pid_, case, src, log)
    row["document"] = got
    note_front(row, "open")
    if not got:
        row["status"] = "document_not_active"
        row["observed_title"] = title(pid_)
        return row, False

    frame_document(pid_, profile, row)
    if getattr(args, "active_layer", None) and not set_active_layer(pid_, case, args.active_layer, row, log):
        return row, False
    # A profile that names a view needs that view set before the export, because the
    # image route renders whichever view is current.
    extra = PROFILES.get(profile, {})
    for steps in spec.get("view", []) + extra.get("view", []):
        _code, out = press_menu(pid_, steps)
        row.setdefault("view_steps", {})[">".join(steps)] = (
            "pressed" if "pressed" in out else "refused")
    setup = [item[:2] for item in spec.get("setup", []) + extra.get("setup", [])]
    if spec.get("page_fit"):
        extra = fit_page(pid_, case, row, log)
        if extra is None:
            return row, False
        setup += extra
    note_front(row, "view")
    before = title(pid_)
    _code, out = press_menu(pid_, spec["menu"])
    note_front(row, "menu")
    if "pressed" not in out:
        row["status"] = "export_menu_refused"
        row["detail"] = out.strip()[:200]
        return row, False

    if spec["options"]:
        on_panel = wait_for(lambda: (title(pid_) == spec["options"]) or None, tries=30)
        if not on_panel:
            row["status"] = "options_panel_missing"
            row["observed_title"] = title(pid_)
            return row, False
        sets = []
        for sel, value in setup:
            # The Tab key and the type step reach the controls the selector grammar
            # cannot walk. A tab moves focus to the next field and a type replaces the
            # value there, which sets the image Width and Height fields.
            if sel == "tab":
                note([time.strftime("%Y-%m-%dT%H:%M:%S%z"), "setup", "sent Tab", ""])
                press_key(48)
                time.sleep(0.5)
                continue
            if sel == "type":
                note([time.strftime("%Y-%m-%dT%H:%M:%S%z"), "setup", "typed " + value, ""])
                type_text(value)
                time.sleep(0.5)
                continue
            if sel == "pane":
                note([time.strftime("%Y-%m-%dT%H:%M:%S%z"), "setup", "pane " + value, ""])
                ok, detail = select_pane(spec["options"], value)
                sets.append({"control": "pane", "value": value, "ok": ok,
                             "detail": "" if ok else detail.strip()[:200]})
                if not ok:
                    row["status"] = "pane_refused"
                    row["setup"] = sets
                    txt, _m = modal_state(pid_)
                    if txt:
                        press_label(pid_, txt, "Cancel")
                    return row, False
                continue
            ok, detail = set_popup(pid_, spec["options"], sel, value)
            sets.append({"control": sel, "value": value, "ok": ok,
                         "detail": "" if ok else detail.strip()[:200]})
            if not ok:
                row["status"] = "popup_refused"
                row["setup"] = sets
                txt, _m = modal_state(pid_)
                if txt:
                    press_label(pid_, txt, "Cancel")
                return row, False
        if sets:
            row["setup"] = sets
        if defaults:
            row["dialog_read"], tree = read_dialog(pid_, spec["options"])
            with open(os.path.join(RUNS, run_id, "records", "%s.%s.dialog.tsv" % (case, profile)), "w") as f:
                f.write(tree)
        # A dialog is accepted either by an AXPress on its default button or by the
        # label on that button. The label differs by format, so it
        # is named in the table. The dwg and dxf dialogs label it OK, the image dialog
        # labels it Save..., and the pdf dialog labels it Export.
        label = spec.get("accept", "OK")
        rescued = not keep["rescue"]
        # An exporter can answer the accept with a notice and then raise its options
        # dialog again. The IFC exporter does this for the story mapping, and the
        # dialog returns on its Layer Mapping tab. Accept it again while it returns.
        # A save panel is the success path and it is modal as well, so the loop stops
        # the moment the panel appears. Clearing a modal here would cancel that panel.
        mapped = False
        for attempt in range(4):
            if title(pid_) != spec["options"]:
                break
            if spec.get("layer_mapping") and attempt and not mapped:
                status, detail = map_ifc_layers(spec["options"])
                row["layer_mapping"] = detail
                if status:
                    row["status"] = status
                    txt, _m = modal_state(pid_)
                    press_label(pid_, txt, "Cancel")
                    return row, False
                mapped = True
            if label == "default":
                press_default(spec["options"])
            else:
                txt, _m = modal_state(pid_)
                ok, out = press_label(pid_, txt, label)
                if not ok and spec.get("rescue") and not rescued:
                    # The dialog disables its accept button while the export scope holds
                    # nothing the current settings would write. A rescue step changes
                    # those settings, and it runs here alone so the default settings stay
                    # in force for every document the dialog already accepts.
                    rescued = True
                    sets = []
                    for sel, value in spec["rescue"]:
                        got, detail = set_popup(pid_, spec["options"], sel, value)
                        sets.append({"control": sel, "value": value, "ok": got,
                                     "detail": "" if got else str(detail).strip()[:200]})
                    row["rescue"] = sets
                    time.sleep(1.0)
                    continue
                if not ok and wait_for(lambda: save_panel_title(pid_, spec, before), tries=5):
                    row["accept_press"] = "reported failed, save panel appeared"
                    break
                if not ok and "refused_button_missing" in out:
                    path, detail = press_default_labelled(pid_, spec["options"], label)
                    row["accept_press"] = path or "default button refused: " + detail[:160]
                    ok = path is not None
                if not ok:
                    row["status"] = "options_button_refused"
                    row["detail"] = out.strip()[:200]
                    row["observed_title"] = title(pid_)
                    return row, False
            if not wait_for(lambda: (title(pid_) != spec["options"]) or None, tries=20):
                break
            if save_panel_title(pid_, spec, before):
                break
            dismiss_modals(pid_, "after-options", log,
                           keep=(spec["options"], spec["save"]))
            if save_panel_title(pid_, spec, before):
                break

    started = time.time()

    def save_ready():
        return save_panel_title(pid_, spec, before)

    if not wait_for(save_ready, tries=40):
        row["status"] = "save_panel_missing"
        row["observed_title"] = title(pid_)
        return row, False
    # The title of the panel that asks for the file is worth recording, because it is
    # what proves the route reached the save step and it names the format. The panel
    # text carries the name too when the window title holds the document name instead.
    note_front(row, "options")
    row["save_panel_title"] = title(pid_)
    if is_save_panel(pid_) and title(pid_) != spec["save"]:
        row["save_panel_detected"] = "by text"

    # The exporter names its file after the document, so a profile variant is stored
    # under its own name while the exporter still writes the plain document name.
    name = artifact_name(case, profile, spec)
    if spec.get("names_by_profile"):
        written = [name, name.replace(case + ".v", case + "_v", 1)]
    else:
        written = [case + "." + spec["ext"]]
    if row["document"] != case + ".vwx":
        written.append(row["document"][:-len(".vwx")] + "." + spec["ext"])
    cleared = [path for each in written for path in stale_artifacts(SEARCH_ROOTS, each)]
    for stale in cleared:
        try:
            os.unlink(stale)
        except FileNotFoundError:
            pass
    row["cleared_stale"] = cleared
    for stale in own_loose_files(case):
        os.unlink(stale)
        row["cleared_stale"].append(stale)
    folder = destination_folder(row["document"], spec)
    if folder != PANEL:
        try:
            clear_output_folder(folder)
            row["cleared_folder"] = folder
        except (OSError, RuntimeError) as exc:
            row["cleared_folder"] = "kept: " + str(exc)[:120]
    os.makedirs(folder, exist_ok=True)
    row["save_folder"] = folder
    if getattr(args, "front", False):
        row["recent_places"] = row["save_by_pid"] = "not tried under --front"
    else:
        tried_at = time.time()
        row["recent_places"] = recent_panel_folder()
        focus.tried("save-recent-places", row["recent_places"] == "pressed", time.time() - tried_at,
                    row["recent_places"])
    if row["recent_places"] == "pressed":
        row["save_folder_route"] = "Recent Places"
    elif not getattr(args, "front", False):
        tried_at = time.time()
        row["save_by_pid"] = save_to_folder_by_pid(PANEL, pid_)
        focus.tried("save-go-to-folder", row["save_by_pid"] == "pressed", time.time() - tried_at,
                    row["save_by_pid"])
        row["save_folder_route"] = "Go to Folder, keys posted to the pid"
    if row["recent_places"] != "pressed" and row["save_by_pid"] != "pressed":
        row["save_folder_route"] = "Go to Folder, Vectorworks in front"
        with focus.in_front("save-go-to-folder", pid_):
            go_to_folder(PANEL)
            panel_key(36)
            wait_state("save panel closed", lambda: not is_save_panel(pid_), timeout=1.0)
    note_front(row, "save")
    dismiss_modals(pid_, "after-save", log)
    document = row["document"]
    window_seen = []

    def running():
        up = export_running(pid_, document)
        if up:
            window_seen.append(True)
        return up

    found = wait_for_file(lambda: find_any(SEARCH_ROOTS, written, started), running,
                          lambda: find_any(REFUSED_ROOTS, written, started))
    if not found:
        refused = find_any(REFUSED_ROOTS, written, started)
        if refused:
            row["status"] = "save_folder_refused"
            row["origin_path"] = refused
            return row, False
        row["status"] = "no file produced"
        row["observed_exporting"] = export_running(pid_, document)
        row["export_window_seen"] = bool(window_seen)
        return row, False
    if not found.startswith(folder + os.sep):
        row["status"] = "save_folder_refused"
        row["origin_path"] = found
        return row, False
    settled_ok = settled(found, running)
    row["wait"] = "window" if window_seen else "quiet"
    if not settled_ok:
        row["status"] = "file never settled"
        row["origin_path"] = found
        row["observed_bytes"] = os.path.getsize(found) if os.path.exists(found) else 0
        return row, False

    dest_dir = keep["dest_dir"]
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, name)
    shutil.move(found, dest)

    # An exporter can write sidecar files beside its output. The OBJ exporter writes
    # a material library next to the mesh, and it writes both into a folder whose
    # name carries the format extension. Move every sibling beside the artifact so
    # the reference stays complete, then remove the folder the exporter made. The
    # search roots themselves are never removed.
    source_dir = os.path.dirname(found)
    sidecars = []
    roots_flat = {directory for directory, _depth in SEARCH_ROOTS}
    if source_dir == PANEL:
        for path in own_loose_files(case):
            if os.path.getmtime(path) >= started:
                shutil.move(path, os.path.join(dest_dir, os.path.basename(path)))
                sidecars.append(os.path.basename(path))
    elif os.path.isdir(source_dir) and source_dir not in roots_flat:
        for sibling in sorted(os.listdir(source_dir)):
            path = os.path.join(source_dir, sibling)
            if not os.path.isfile(path):
                continue
            target = os.path.join(dest_dir, sibling)
            if os.path.abspath(path) == os.path.abspath(found):
                continue
            shutil.move(path, target)
            sidecars.append(os.path.basename(target))
        for emptied in dict.fromkeys(d for d in (source_dir, folder) if d != PANEL):
            try:
                clear_output_folder(emptied)
            except (OSError, RuntimeError):
                pass
    row["sidecars"] = sidecars
    row["retired_sidecars"] = retire_sidecars(case, profile, sidecars, run_id) if keep["retire_sidecars"] else []

    # The pixel size of an image is the one property a reader cannot recover from the
    # file name, and the route sets it. Record the two numbers from the PNG header as
    # evidence that the export honoured the size the setup asked for.
    if spec["ext"] == "png":
        size = png_size(dest)
        if size:
            row["pixels"] = "%dx%d" % size
    note_front(row, "end")
    row.update({"status": "ok", "origin_path": found, "path": relative(dest, ROOT),
                "bytes": os.path.getsize(dest), "sha256": sha(dest)})
    if not keep["ledger"]:
        return row, True
    with open(LEDGER, "a") as f:
        f.write(json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "run_id": run_id,
            "case": case, "format": args.format, "profile": profile,
            "profile_revision": row["profile_revision"],
            "route": "ui-menu " + " > ".join(spec["menu"])
                     + (", options OK" if spec["options"] else "")
                     + ", save panel default button, framing via View > Zoom > Fit To Objects"
                     + (", page fit via Run Script layer scale and page radio"
                        if spec.get("page_fit") else ""),
            "path": relative(dest, ROOT), "bytes": row["bytes"], "sha256": row["sha256"],
            "sidecars": sidecars, "origin_path": found, "source": relative(src, ROOT), "source_sha256": sources_sha,
            "app_version": "32.1.0 (885363)", "cli": CLI}) + "\n")
    return row, True


def load_sources():
    sources = {}
    with open(SOURCE_MAP) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                sources[parts[0]] = resolve(parts[1], ROOT)
    return sources


def load_pairs(fmt, only, profile):
    pairs = []
    with open(REQUIRED) as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3 or not all(parts):
                continue
            case, name, row_format = parts
            if row_format != fmt:
                continue
            if profile and name != profile:
                continue
            if only and case not in only.split(","):
                continue
            pairs.append((case, name))
    return pairs


def probe(args, cases, sources, run_dir, log):
    """Open the route for one format and record every control it shows.

    The dump answers what the format table needs. Read the options dialog title,
    its popups with their current values, and the title of the save panel."""
    spec = format_spec(args.format, args.profile)
    case = args.only or next((c for c, _p in cases if c in sources), None)
    if not case:
        print(json.dumps({"status": "no case to probe"}))
        return 1
    src = sources[case]
    pid_ = live_pid()
    close_extra_documents(pid_, None, log)
    _work, got = prepare_document(pid_, case, src, log)
    if not got:
        print(json.dumps({"status": "document_not_active", "observed_title": title(pid_)}))
        return 1
    frame_document(pid_, args.profile or "", {})
    layer = {}
    if args.active_layer and not set_active_layer(pid_, case, args.active_layer, layer, log):
        print(json.dumps({"status": layer["status"], "active_layer": layer.get("active_layer")}))
        return 1

    before = title(pid_)
    out_path = os.path.join(run_dir, "probe-" + args.format + ".tsv")
    with open(out_path, "w") as f:
        if layer:
            f.write("active_layer\t%s\t%s\n" % (args.active_layer, json.dumps(layer["active_layer"])))
        f.write("stage\tbefore-menu\twindow_title\t%s\n" % before)
        f.write("menu\t%s\n" % " > ".join(spec["menu"]))
        if not spec["menu"]:
            f.write("note\tthe format table holds no menu path for this format\n")
        else:
            _code, out = press_menu(pid_, spec["menu"])
            f.write("press_status\t%s\n" % out.strip().replace("\n", " "))
            time.sleep(3.0)
            after = title(pid_)
            f.write("stage\tafter-menu\twindow_title\t%s\n" % after)
            # ui-dialog stops at 200 nodes and takes no flag to raise that, so a
            # dialog that runs deeper than that is read whole through the native
            # tree of ui-export-control instead.
            if args.settings and after and after != before:
                ok, detail = set_popup(pid_, after, "popup/sibling/Settings:", args.settings)
                f.write("settings\t%s\t%s\t%s\n" % (args.settings, ok, detail.strip()[:200]))
            if args.pane and after and after != before:
                ok, detail = select_pane(after, args.pane)
                f.write("pane\t%s\t%s\t%s\n" % (args.pane, ok, detail.strip()[:200]))
            if after and after != before:
                _code, tree = cli("ui-export-control", "--pid", pid_,
                                  "--expected-executable", EXE, "--window-title", after,
                                  "--native", "--native-tree", timeout=120)
                f.write("tree_command\tui-export-control --native --native-tree "
                        "--window-title %s\n" % after)
                for line in tree.splitlines():
                    f.write("tree\t%s\n" % line)
            _rows, raw = dump(pid_, 4000)
            for line in raw.splitlines():
                f.write("dump\t%s\n" % line)
            txt, is_modal = modal_state(pid_)
            f.write("modal\t%s\t%s\n" % (is_modal, txt[:300]))
            # --hold leaves the dialog open so an operator can measure the effect of
            # one control on another, then close it by hand.
            if args.hold:
                print(json.dumps({"status": "probed", "case": case,
                                  "dump": out_path, "held": after}))
                return 0
            if is_modal == "true" and txt:
                press_label(pid_, txt, "Cancel")
            elif after and after != before:
                press_label(pid_, after, "Cancel")
            else:
                press_key(53)
            time.sleep(1.0)
    print(json.dumps({"status": "probed", "case": case, "dump": out_path}))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", default="dwg", choices=sorted(FORMATS))
    ap.add_argument("--profile", default=None)
    ap.add_argument("--only")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--unlisted", action="store_true",
                    help="run each --only case with --profile when ledger/required-pairs.tsv does not list the pair")
    ap.add_argument("--active-layer", metavar="LAYER",
                    help="make this design or sheet layer active before the export menu")
    ap.add_argument("--front", action="store_true",
                    help="go to the save folder with Vectorworks in front, with no background save try")
    ap.add_argument("--source", action="append", default=[], metavar="CASE=PATH",
                    help="export PATH under the name CASE. CASE must not be in driver/source-map.tsv")
    ap.add_argument("--pane", choices=sorted(DXF_DWG_PANES),
                    help="probe only: select this DXF/DWG pane before the dump")
    ap.add_argument("--settings", metavar="NAME",
                    help="probe only: choose NAME in the Settings popup of the DXF/DWG dialog before the dump")
    ap.add_argument("--hold", action="store_true",
                    help="probe only: leave the dialog open instead of cancelling it")
    ap.add_argument("--defaults", action="store_true",
                    help="set only the controls of the profile, run no rescue step, record the value of each "
                         "control, and keep the file in runs/<run_id>/defaults/ with no ledger line")
    args = ap.parse_args()

    if args.format not in FORMATS:
        raise SystemExit("no table entry for format " + args.format)
    if FORMATS[args.format].get("refuse"):
        raise SystemExit(FORMATS[args.format]["refuse"])

    sources = load_sources()
    for item in args.source:
        case, _, path = item.partition("=")
        if not (case and path) or case in sources:
            raise SystemExit("--source %s: give CASE=PATH with a CASE that driver/source-map.tsv does not name" % item)
        sources[case] = os.path.abspath(path)
    pairs = load_pairs(args.format, args.only, args.profile)
    if args.unlisted:
        if not (args.only and args.profile):
            raise SystemExit("--unlisted needs --only and --profile")
        pairs += [(case, args.profile) for case in args.only.split(",") if (case, args.profile) not in pairs]
    if args.limit:
        pairs = pairs[:args.limit]

    # A dry run prints each row and its step list. It creates no run directory.
    if args.dry_run:
        for case, profile in pairs:
            print(json.dumps({"case": case, "profile": profile, "source": sources.get(case),
                              "status": "planned" if case in sources else "no source document",
                              "steps": route_plan(args.format, profile, args.active_layer, args.defaults)}))
        return 0

    with vw_lock.held("sweep-ui.py --format " + args.format):
        PROVENANCE.update(run_provenance.require(ROOT, binaries=sorted({CLI, SCRIPT_CLI, vw_memory.CLI})))
        run_id = time.strftime("%Y%m%dT%H%M%S") + "-ui-" + args.format
        run_dir = os.path.join(ROOT, "runs", run_id)
        os.makedirs(os.path.join(run_dir, "records"), exist_ok=True)
        os.makedirs(os.path.join(run_dir, "driver"), exist_ok=True)
        shutil.copy2(os.path.abspath(__file__), os.path.join(run_dir, "driver", "sweep-ui.py"))

        log = []
        workspace = FORMATS[args.format].get("workspace")
        if workspace:
            switch_workspace(workspace, log)
        try:
            if args.probe:
                return probe(args, pairs, sources, run_dir, log)
            return sweep(args, pairs, sources, run_id, run_dir, log)
        finally:
            if workspace:
                switch_workspace(HOME_WORKSPACE, log)


def switch_workspace(name, log):
    """Press Tools > Workspaces > name. The switch takes effect at once and leaves the
    defaultWorkspace preference unchanged."""
    code, out = press_menu(live_pid(), ["Tools", "Workspaces", name])
    log.append({"step": "workspace", "name": name, "code": code})
    print(json.dumps(log[-1]))
    if code != 0 or "pressed" not in out:
        raise SystemExit("workspace switch to %s failed (exit %s): %s" % (name, code, out.strip()))
    time.sleep(3)


def sweep(args, pairs, sources, run_id, run_dir, log):
    done = failed = 0
    workspace = FORMATS[args.format].get("workspace")
    pid = live_pid()
    hold_front("sweep-start")
    pairs = list(pairs)
    for i, (case, profile) in enumerate(pairs):
        src = sources.get(case)
        if not src:
            row = {"case": case, "profile": profile, "format": args.format,
                   "run_id": run_id, "status": "no source document"}
            failed += 1
            print("sweep-ui: %s %s: no source document" % (case, profile), file=sys.stderr, flush=True)
            log.append(row)
            write_record(run_dir, case, profile, row)
            print(json.dumps(row), flush=True)
            continue
        pid, row, ok = export_pair(args, case, profile, src, run_id, log, pid, workspace)
        if not ok and row.get("status") != "paused" and not vw_memory.live_pid():
            first, first_dialogs = row.get("status"), row.get("dialogs")
            pid = keep_workspace(pid, memory_step(vw_memory.restart, log, "gone after %s %s" % (case, profile)),
                                 workspace, log)
            pid, row, ok = export_pair(args, case, profile, src, run_id, log, pid, workspace)
            row["first_try"] = "%s, Vectorworks gone, restarted" % first
            row["first_try_dialogs"] = first_dialogs
        if ok:
            done += 1
        else:
            failed += 1
            print("sweep-ui: %s %s: %s" % (case, profile, failure_text(row)), file=sys.stderr, flush=True)
        log.append(row)
        write_record(run_dir, case, profile, row)
        print(json.dumps({k: row.get(k) for k in ("case", "profile", "status", "bytes")}), flush=True)
        if row.get("status") == "paused":
            break
        next_src = sources.get(pairs[i + 1][0]) if i + 1 < len(pairs) else None
        if next_src != src:
            pid = keep_workspace(pid, memory_step(vw_memory.after_source, log, src), workspace, log)

    memory_step(vw_memory.end_of_batch, log)
    hold_front("end-of-batch")
    with open(os.path.join(run_dir, "records", "run.json"), "w") as f:
        json.dump({"run_id": run_id, "format": args.format, "rows": len(pairs),
                   "ok": done, "failed": failed, "driver": PROVENANCE, "log": log}, f, indent=1)
    print(json.dumps({"run_id": run_id, "rows": len(pairs), "ok": done, "failed": failed}))
    code = 1 if failed else 0
    print("sweep-ui: exit %d, %d of %d pairs failed" % (code, failed, len(pairs)), file=sys.stderr, flush=True)
    return code


def failure_text(row):
    """The status of a failed row, then its detail, the window title it saw and the last dialog text."""
    parts = [str(row.get("status"))]
    for key in ("detail", "observed_title", "origin_path"):
        if row.get(key):
            parts.append("%s %s" % (key, str(row[key])[:200]))
    if row.get("dialogs"):
        last = row["dialogs"][-1]
        parts.append("last dialog %s: %s" % (last.get("where"), str(last.get("text"))[:200]))
    return "; ".join(parts).replace("\n", " ")


def write_record(run_dir, case, profile, row):
    row["driver"] = PROVENANCE
    with open(os.path.join(run_dir, "records", case + "." + profile + ".json"), "w") as f:
        json.dump(row, f, indent=1)


def export_pair(args, case, profile, src, run_id, log, pid, workspace):
    CURRENT.update(run_id=run_id, case=case, profile=profile, dialogs=[])
    try:
        pause.check()
        pid = keep_workspace(pid, vw_memory.before_row(log), workspace, log)
        pid = keep_workspace(pid, clear_documents(log), workspace, log)
        row, ok = collect_row(args, case, profile, src, sha(src), run_id, log)
    except pause.Paused as exc:
        row = {"case": case, "profile": profile, "format": args.format,
               "run_id": run_id, "status": "paused", "detail": str(exc)}
        ok = False
    except Exception as exc:
        row = {"case": case, "profile": profile, "format": args.format,
               "run_id": run_id, "status": "exception",
               "detail": type(exc).__name__ + ": " + str(exc)}
        ok = False
    finally:
        try:
            pid_ = live_pid()
            dismiss_modals(pid_, "end-of-row", log, cancel_save=True)
            close_extra_documents(pid_, None, log)
        except Exception:
            pass
    row["dialogs"] = CURRENT["dialogs"]
    return pid, row, ok


def clear_documents(log):
    """Close what an earlier row left open. Returns the new pid when Vectorworks restarted, else None.

    Documents that stay open pile up to the open document limit, and every later open fails."""
    pid_ = live_pid()
    dismiss_modals(pid_, "row-start", log, cancel_save=True)
    close_extra_documents(pid_, None, log)
    left = title(pid_)
    if not left and modal_state(pid_)[1] != "true":
        return None
    return memory_step(vw_memory.restart, log, "open before the row: " + (left or "a modal"))


def memory_step(step, log, *args):
    try:
        return step(*args, log=log)
    except (pause.Paused, RuntimeError) as exc:
        log.append({"step": "vw_memory", "status": type(exc).__name__, "detail": str(exc)})
        print(json.dumps(log[-1]))
        return None


def keep_workspace(pid, new_pid, workspace, log):
    """A restarted instance opens in the default workspace, so the run's workspace is pressed again."""
    if new_pid and new_pid != pid:
        hold_front("memory-restart")
    if workspace and new_pid and new_pid != pid:
        switch_workspace(workspace, log)
    return new_pid or pid


if __name__ == "__main__":
    raise SystemExit(main())
