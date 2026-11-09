"""Derive the intent of each case from the script that built its source document.

build-index.py calls case_record() for each case and entity_kinds() once, and writes the result to
ledger/intent.json. driver/MANIFEST.md describes the fields. Each script runs against a stand-in `vs` module that records the calls and
calls nothing in Vectorworks. A call with no rule here stops the program, so a new script API gets
a rule before its case gets an intent record.
"""
import collections
import hashlib
import json
import os
import re
import sys
import types

LAYER_TYPE = {1: "design", 2: "sheet"}

OBJECT_TYPE = {
    "Rect": "rectangle",
    "RRect": "rounded rectangle",
    "Oval": "oval",
    "Arc": "arc",
    "ArcByCenter": "arc",
    "Locus": "2D locus",
    "Locus3D": "3D locus",
    "CreateText": "text",
    "LinearDim": "dimension",
    "AngularDim": "dimension",
    "CircularDim": "dimension",
    "ImportImageFile": "image",
    "CreateCustomObject": "plug-in object",
    "CreateCustomObjectN": "plug-in object",
    "CreateCustomObjectPath": "plug-in object",
    "Wall": "wall",
    "RoundWall": "wall",
    "CreateRoof": "roof",
    "CreateCone": "cone",
    "CreateSphere": "sphere",
    "CreateHemisphere": "hemisphere",
    "CreateLight": "light",
    "CreateNurbsCurve": "NURBS curve",
    "CreateNurbsSurface": "NURBS surface",
    "Symbol": "symbol instance",
    "LayerRef": "layer link",
    "CreateWSImage": "worksheet image",
}

CONVERSION_TYPE = {
    "ConvertToPolygon": "polygon",
    "ConvertToNURBS": "NURBS",
    "GroupToMesh": "mesh",
    "CnvrtToGenericSolid": "generic solid",
    "CreateShell": "shell solid",
    "CreateTaperedExtrude": "tapered extrude",
    "CreateExtrudeAlongPath": "extrude along path",
    "CreateSlab": "slab",
    "Space_CreateSpace": "space",
    "CreateLoftSurfaces": "loft",
}

BOOLEAN_TYPE = {
    "AddSolid": "solid addition",
    "SubtractSolid": "solid subtraction",
    "IntersectSolid": "solid intersection",
}

GROUP_TYPE = {"BeginFloor": "floor", "BeginRoof": "roof face"}

SOLID_END = {"EndXtrd": ("BeginXtrd", "extrude"), "EndMXtrd": ("BeginMXtrd", "multiple extrude"),
             "EndSweep": ("BeginSweep", "sweep")}

RESOURCE_TYPE = {
    "BeginVectorFillN": "hatch",
    "CreateGradient": "gradient",
    "CreateMaterial": "material",
    "CreateTextStyleRes": "text style",
    "CreateSlabStyle": "slab style",
    "CreateWallStyle": "wall style",
    "CreateWS": "worksheet",
    "SaveSheet": "saved view",
    "SetDashStyleN": "line type",
    "CreateTile": "tile",
}

MENU_TYPE = {"Site Model from Source Data...": "site model"}

# Calls whose first argument is the object, layer or resource they change.
MODIFIERS = {
    "AddSymToWall", "AddTileGeometryObject", "AddVertex3D", "AppendRoofEdge", "AssociateLinearDimension", "HRotate", "InsertGradientSegment", "InsertNewComponentN",
    "Mirror", "Move3DObj", "NurbsSetPt3D", "NurbsSetWeight", "ResetObject", "Set3DRot", "HScale3D", "SetComponentWidth",
    "SetFPat", "SetIsCurtainWall", "SetLSByClass", "SetLSN", "SetLW", "SetLWByClass", "SetObjMaterialHandle", "SetPenColorByClass",
    "SetObjectVariableBoolean", "SetObjectVariableInt", "SetObjectVariableReal", "SetRField", "SetRecord", "SetVectorFill", "SetVPClassVisibility",
    "SetVPLayerVisibility", "SetWallStyle",
    "SetWSCellFormula", "TrimNurbsSurface", "UpdateVP",
    "JoinWalls", "SetFillBack", "SetFillColorByClass", "SetFillFore", "SetObjBeginningMarker", "SetObjEndMarker",
    "SetObjectVariableLongInt", "SetPenFore", "SetTexMapRealN", "SetTextJust", "SetTextSize", "SetTextStyle", "SetTextVerticalAlign",
    "SetTextureRefN", "SetFPatByClass", "SetVertexVisibility", "RecalculateWS",
    "EnableDropShadow", "SetDropShadowData", "SetImageCropObject", "SetImageCropVisible", "SetLightDirection",
    "SetLightFalloff", "SetOpacityByClassN", "SetOpacityN", "CreateGableDormer", "CreateSkylight", "SetDormerAttributes", "SetSkylight",
}

# Settings that the next created text object takes.
TEXT_SETTINGS = {"TextFont", "TextJust", "TextOrigin", "TextRotate", "TextSize", "TextVerticalAlign"}

# Class attribute calls. The first argument names the class.
CLASS_SETTINGS = {"SetClFillBack", "SetClFillFore", "SetClFPat", "SetClLSN", "SetCLOpacityN", "SetClLW", "SetClPenFore",
                  "SetClTextureG", "SetClUseTexture"}

DOCUMENT_SETTINGS = {"SetUnits": "units", "SetView": "view", "SetOriginAbsolute": "origin",
                     "SetDocGeoRefByUsrOrg": "georeference", "SetSlabPreferencesStyle": "slab style",
                     "SetDimStd": "dimension standard", "SetPref": "preference"}


class Handle:
    def __init__(self, record):
        self.record = record


class ResourceIndex:
    """The value vs.Name2Index returns. A negative index names a line type or a vector fill."""

    def __init__(self, name, sign=1):
        self.name = name
        self.sign = sign

    def __neg__(self):
        return ResourceIndex(self.name, -self.sign)


class Recorder:
    def __init__(self):
        self.objects = []
        self.layers = []
        self.classes = {}
        self.resources = []
        self.document = {}
        self.last = None
        self.layer = None
        self.cls = None
        self.plane = None
        self.closed = None
        self.text = []
        self.pen = None
        self.frames = []
        self.next_name = None
        self.folders = []

    def layer_record(self, name):
        for r in self.layers:
            if r.get("name") == name:
                return r
        r = {"name": name}
        self.layers.append(r)
        return r

    def class_record(self, name):
        return self.classes.setdefault(name, {"name": name})

    def place(self, record):
        """Put a new object into the open frame, or into the drawing when none is open."""
        for frame in reversed(self.frames):
            if frame["kind"] in ("profile", "mesh"):
                frame["items"].append(record)
                return Handle(record)
            if frame["kind"] in ("group", "symbol"):
                record["in"] = frame["in"]
                frame["items"].append(record)
                break
        if not any(f["kind"] == "symbol" for f in self.frames) and self.layer is not None:
            record["layer"] = self.layer
        if self.cls is not None:
            record["class"] = self.cls
        if self.plane is not None:
            record["working_plane"] = self.plane
        self.objects.append(record)
        h = Handle(record)
        self.last = h
        return h

    def menu(self, *path):
        """Record the object that a menu command builds from the selected objects."""
        sources = [r for r in self.objects if r.pop("selected", False)]
        for r in sources:
            self.objects.remove(r)
        return self.place({"type": MENU_TYPE[path[-1]], "api": "menu " + " > ".join(path), "args": list(path),
                           "from": sources})

    def create(self, kind, api, args, **extra):
        record = {"type": kind, "api": "vs." + api, "args": list(args)}
        record.update(extra)
        return self.place(record)

    def call(self, name, args):
        if name == "LNewObj":
            return self.last
        if name == "SetName":
            args[0].record["name"] = args[1]
            return None
        if name in OBJECT_TYPE:
            extra = {}
            if name == "CreateText" and self.text:
                extra["settings"], self.text = self.text, []
            if name == "Symbol":
                extra["definition"] = args[0]
            if name in ("CreateCustomObject", "CreateCustomObjectN", "CreateCustomObjectPath"):
                extra["plugin"] = args[0]
            return self.create(OBJECT_TYPE[name], name, args, **extra)
        if name in TEXT_SETTINGS:
            self.text.append({"api": "vs." + name, "args": list(args)})
            return None
        if name in MODIFIERS:
            args[0].record.setdefault("calls", []).append({"api": "vs." + name, "args": list(args[1:])})
            if name == "TrimNurbsSurface":
                args[1].record["trims"] = args[0]
            return True
        if name in CLASS_SETTINGS:
            self.class_record(args[0]).setdefault("calls", []).append({"api": "vs." + name, "args": list(args[1:])})
            return None
        if name == "Name2Index":
            return ResourceIndex(args[0])
        if name == "GetFontID":
            return {"api": "vs." + name, "args": list(args)}
        if name == "DoMenuTextByName" and args[0] == "Standard Views":
            self.document["view"] = {"api": "vs." + name, "args": list(args)}
            return None
        if name in DOCUMENT_SETTINGS:
            self.document[DOCUMENT_SETTINGS[name]] = {"api": "vs." + name, "args": list(args)}
            return None
        if name == "BuildResourceList":
            return ({"api": "vs." + name, "args": list(args)}, 0)
        if name == "ImportResourceToCurrentFile":
            r = {"type": "library resource", "name": None, "api": "vs." + name, "args": [args[0]["args"], args[1]]}
            self.resources.append(r)
            return Handle(r)
        if name == "CreateTexture":
            r = {"type": "texture", "name": None, "api": "vs." + name, "args": []}
            self.resources.append(r)
            return Handle(r)
        if name == "CreateImageFromPaint":
            r = {"type": "image", "name": args[1], "api": "vs." + name, "args": list(args)}
            self.resources.append(r)
            return Handle(r)
        if name in RESOURCE_TYPE:
            r = {"type": RESOURCE_TYPE[name], "name": args[0], "api": "vs." + name, "args": list(args)}
            self.resources.append(r)
            return Handle(r)
        if name == "NewField":
            for r in self.resources:
                if r["type"] == "record format" and r["name"] == args[0]:
                    r["fields"].append(list(args[1:]))
                    return None
            self.resources.append({"type": "record format", "name": args[0], "api": "vs.NewField",
                                   "fields": [list(args[1:])]})
            return None
        if name == "SetWorkingPlaneN":
            self.plane = {"api": "vs." + name, "args": list(args)}
            return None
        if name == "CreateLayer":
            r = self.layer_record(args[0])
            r["type"] = LAYER_TYPE[args[1]]
            return Handle(r)
        if name == "Layer":
            self.layer_record(args[0])
            self.layer = args[0]
            return None
        if name == "ActLayer":
            if self.layer is None:
                for r in self.layers:
                    if r.get("active_at_start"):
                        return Handle(r)
                r = {"active_at_start": True}
                self.layers.append(r)
                return Handle(r)
            return Handle(self.layer_record(self.layer))
        if name == "HideLayer":
            self.layer_record(self.layer)["hidden"] = True
            return None
        if name == "SetLayerElevation":
            args[0].record["elevation"] = args[1]
            args[0].record["thickness"] = args[2]
            return None
        if name == "SetLScale":
            args[0].record["scale"] = args[1]
            return None
        if name == "NameClass":
            self.class_record(args[0])
            self.cls = args[0]
            return None
        if name == "SetClass":
            self.class_record(args[1])
            args[0].record["class"] = args[1]
            return None
        if name == "HideClass":
            self.class_record(args[0])["hidden"] = True
            return None
        if name == "MoveTo":
            self.pen = args[0]
            return None
        if name == "LineTo":
            h = self.create("line", "LineTo", [self.pen, args[0]])
            self.pen = args[0]
            return h
        if name == "ClosePoly":
            self.closed = True
            return None
        if name == "OpenPoly":
            self.closed = False
            return None
        if name in ("BeginPoly", "BeginPoly3D"):
            self.frames.append({"kind": name, "items": []})
            return None
        if name in ("AddPoint", "Add3DPt"):
            self.frames[-1]["items"].append(args[0])
            return None
        if name == "Add2DVertex":
            self.frames[-1]["items"].append(list(args))
            self.frames[-1]["polyline"] = True
            return None
        if name == "EndPoly":
            frame = self.frames.pop()
            extra = {"vertices": frame["items"]}
            if self.closed is not None:
                extra["closed"] = self.closed
            return self.create("polyline" if frame.get("polyline") else "polygon", "EndPoly", [], **extra)
        if name == "EndPoly3D":
            frame = self.frames.pop()
            return self.create("3D polygon", "EndPoly3D", [], vertices=frame["items"])
        if name in ("BeginXtrd", "BeginMXtrd", "BeginSweep"):
            self.frames.append({"kind": "profile", "begin": name, "args": list(args), "items": []})
            return None
        if name in SOLID_END:
            frame = self.frames.pop()
            begin, kind = SOLID_END[name]
            return self.create(kind, begin, frame["args"], profile=frame["items"])
        if name == "BeginMesh":
            self.frames.append({"kind": "mesh", "items": []})
            return None
        if name == "EndMesh":
            frame = self.frames.pop()
            return self.create("mesh", "BeginMesh", [], faces=[f["vertices"] for f in frame["items"]])
        if name == "BeginGroup":
            group = {"type": "group", "api": "vs.BeginGroup", "args": []}
            self.frames.append({"kind": "group", "record": group, "in": {"object": Handle(group)}, "items": []})
            return None
        if name in GROUP_TYPE:
            record = {"type": GROUP_TYPE[name], "api": "vs." + name, "args": list(args)}
            self.frames.append({"kind": "profile", "record": record, "items": []})
            return None
        if name == "EndGroup":
            frame = self.frames.pop()
            if frame["kind"] == "profile":
                frame["record"]["profile"] = frame["items"]
            return self.place(frame["record"])
        if name == "BeginSym":
            r = {"type": "symbol definition", "name": args[0], "api": "vs.BeginSym", "args": list(args)}
            if self.folders:
                r["folder"] = self.folders[-1]
            self.resources.append(r)
            self.frames.append({"kind": "symbol", "in": {"symbol": args[0]}, "items": []})
            return None
        if name == "EndSym":
            self.frames.pop()
            return None
        if name == "CreateVP":
            h = self.place({"type": "viewport", "api": "vs.CreateVP", "args": list(args)})
            h.record["layer"] = args[0].record["name"]
            return h
        if name in ("SetVPCropObject", "AddVPAnnotationObject"):
            args[0].record.setdefault("calls", []).append({"api": "vs." + name, "args": list(args[1:])})
            args[1].record["in"] = {"object": args[0]}
            args[1].record.pop("layer", None)
            return True
        if name in CONVERSION_TYPE:
            return self.create(CONVERSION_TYPE[name], name, args)
        if name in BOOLEAN_TYPE:
            h = self.create(BOOLEAN_TYPE[name], name, args)
            for operand in args:
                operand.record["in"] = {"object": h}
            return 0, h
        if name == "AddVectorFillLayer":
            hatch = [r for r in self.resources if r["type"] == "hatch"][-1]
            hatch.setdefault("layers", []).append(list(args))
            return None
        if name == "EndVectorFill":
            return None
        if name == "NameObject":
            self.next_name = args[0]
            return None
        if name == "BeginFolder":
            r = {"type": "symbol folder", "name": self.next_name, "api": "vs.BeginFolder", "args": []}
            self.next_name = None
            self.resources.append(r)
            self.folders.append(r["name"])
            return None
        if name == "EndFolder":
            self.folders.pop()
            return None
        if name == "SetSelect":
            args[0].record["selected"] = True
            return None
        if name == "DelObject":
            gone = args[0].record
            members = [r for r in self.objects if r.get("in", {}).get("object", Handle(None)).record is gone]
            self.objects = [r for r in self.objects if r is not gone and r not in members]
            for r in self.objects:
                held = [n for n, a in enumerate(r["args"]) if isinstance(a, Handle) and a.record is gone]
                for n in held:
                    r["args"][n] = "profile"
                if held:
                    r["profile"] = [{k: v for k, v in m.items() if k in ("type", "api", "args", "vertices", "name", "calls")}
                                    for m in members]
            return None
        if name == "GetObject":
            for r in self.resources + self.objects:
                if r.get("name") == args[0]:
                    return Handle(r)
            return None
        raise KeyError(name)


def run(script):
    recorder = Recorder()

    class Stub(types.ModuleType):
        def __getattr__(self, name):
            def f(*args):
                try:
                    return recorder.call(name, list(args))
                except KeyError as e:
                    if e.args == (name,):
                        sys.exit("recipe_intent.py: %s calls vs.%s, which has no rule" % (script, name))
                    raise
            return f

    saved = sys.modules.get("vs")
    sys.modules["vs"] = Stub("vs")
    g = {
        "rosetta_save_reopen": lambda: None,
        "rosetta_checkpoint": lambda _id: None,
        "rosetta_dependency": lambda dep: "dependency:" + dep,
        "rosetta_menu": recorder.menu,
    }
    try:
        with open(script) as f:
            exec(compile(f.read(), script, "exec"), g)
    finally:
        if saved is None:
            sys.modules.pop("vs", None)
        else:
            sys.modules["vs"] = saved
    return recorder


def bounds(points):
    return [[min(p[i] for p in points) for i in range(len(points[0]))],
            [max(p[i] for p in points) for i in range(len(points[0]))]]


def box(record):
    api = record["api"]
    if api in ("vs.Rect", "vs.Oval", "vs.RRect"):
        return bounds(record["args"][:2])
    if api == "vs.LineTo":
        return bounds(record["args"])
    if record["type"] in ("polygon", "3D polygon") and api in ("vs.EndPoly", "vs.EndPoly3D"):
        return bounds(record["vertices"])
    if api == "vs.CreateSphere":
        c, r = record["args"]
        return [[v - r for v in c], [v + r for v in c]]
    return None


def header(text, key):
    m = re.search(r"^# %s: (.+)$" % key, text, re.M)
    return m.group(1).strip() if m else None


def script_for(root, case):
    base = os.path.join(root, "driver", "inventory", "scripts")
    revisions = []
    for name in os.listdir(os.path.join(base, "revisions")):
        m = re.fullmatch(re.escape(case) + r"\.rev([0-9]+)\.py", name)
        if m:
            revisions.append((int(m.group(1)), os.path.join(base, "revisions", name)))
    return max(revisions)[1] if revisions else os.path.join(base, case + ".py")


def sha256_file(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def recipe_for(root, script):
    """Follow `# base:` lines to the nearest script that names a recipe JSON."""
    rel = os.path.relpath(script, root)
    while True:
        text = open(os.path.join(root, rel)).read()
        recipe = header(text, "recipe_path")
        if recipe:
            p = "driver/inventory/" + recipe
            if sha256_file(os.path.join(root, p)) != header(text, "recipe_sha256"):
                sys.exit("recipe_intent.py: %s does not hash to the recipe_sha256 of %s" % (p, rel))
            return p
        base = header(text, "base")
        if not base:
            sys.exit("recipe_intent.py: %s names neither a recipe_path nor a base" % rel)
        rel = base


def plain(value, ids):
    if isinstance(value, Handle):
        return ids[id(value.record)]
    if isinstance(value, ResourceIndex):
        return ("-" if value.sign < 0 else "") + "index of " + value.name
    if isinstance(value, dict):
        return {k: plain(v, ids) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v, ids) for v in value]
    return value


def names(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from names(v)


# Relationship fields that hold a value of the relation. Every other field names an object, layer,
# class or resource that the effective script must create.
RELATION_VALUES = {"kind", "api", "operation", "axis", "path"}


def case_record(root, case):
    script = script_for(root, case)
    rec = run(script)
    script_rel = os.path.relpath(script, root)
    recipe_rel = recipe_for(root, script)
    recipe = json.load(open(os.path.join(root, recipe_rel)))

    ids = {}
    for n, o in enumerate(rec.objects, 1):
        ids[id(o)] = o.get("name") or "#%d" % n
    for r in rec.layers + rec.resources:
        ids[id(r)] = r.get("name")
    roles = {o["object_id"]: o["role"] for o in recipe["objects"]}
    for r in rec.layers + rec.resources:
        if r.get("name") in roles:
            r["role"] = roles[r["name"]]

    objects = []
    for o in rec.objects:
        out = {"id": ids[id(o)]}
        for key in ("type", "plugin", "definition", "api", "args", "settings", "vertices", "closed", "faces",
                    "profile", "working_plane", "layer", "class", "in", "trims", "calls"):
            if key in o:
                out[key] = plain(o[key], ids)
        if "profile" in out:
            out["profile"] = [{**({"name": p["name"]} if "name" in p else {}),
                               "type": p["type"], "api": p["api"], "args": plain(p["args"], ids),
                               **({"vertices": plain(p["vertices"], ids)} if "vertices" in p else {}),
                               **({"calls": plain(p["calls"], ids)} if "calls" in p else {})}
                              for p in o["profile"]]
        b = box(o)
        if b is not None:
            out["bounds"] = plain(b, ids)
        if out["id"] in roles:
            out["role"] = roles[out["id"]]
        objects.append(out)

    hidden_classes = {name for name, c in rec.classes.items() if c.get("hidden") and name != rec.cls}
    hidden_layers = {r["name"] for r in rec.layers if r.get("hidden")}
    if hidden_layers or any(c.get("hidden") for c in rec.classes.values()):
        by_id = {o["id"]: o for o in objects}

        def hidden(o):
            if o.get("class") in hidden_classes or o.get("layer") in hidden_layers:
                return True
            parent = o.get("in")
            if parent is None:
                return False
            if "object" in parent:
                return hidden(by_id[parent["object"]])
            instances = [i for i in objects if i.get("definition") == parent["symbol"]]
            return bool(instances) and all(hidden(i) for i in instances)

        for o in objects:
            o["hidden"] = hidden(o)

    known = {o["id"] for o in objects} | {r["name"] for r in rec.resources} \
        | {r["name"] for r in rec.layers if "name" in r} | set(rec.classes)
    relationships = [r for r in recipe["expected_relationships"]
                     if all(n in known for k, v in r.items() if k not in RELATION_VALUES for n in names(v))]

    record = {
        "script": {"path": script_rel, "sha256": sha256_file(script),
                   "revision": header(open(script).read(), "recipe_revision")},
        "recipe": {"path": recipe_rel, "sha256": sha256_file(os.path.join(root, recipe_rel)),
                   "revision": recipe["recipe_revision"], "title": recipe["title"]},
        "objects": objects,
    }
    if rec.layers:
        record["layers"] = plain(rec.layers, ids)
    if rec.classes:
        record["classes"] = plain([rec.classes[k] for k in sorted(rec.classes)], ids)
    if rec.resources:
        record["resources"] = plain(rec.resources, ids)
    if rec.document:
        record["document"] = plain(rec.document, ids)
    if recipe["parameters"]:
        record["parameters"] = recipe["parameters"]
    if relationships:
        record["expected_relationships"] = relationships
    return record


def dxf_kinds(p):
    """Count the entities of the ENTITIES and BLOCKS sections of a text DXF."""
    with open(p, encoding="latin-1") as f:
        lines = [line.strip() for line in f.read().splitlines()]
    entities = collections.Counter()
    blocks = collections.Counter()
    section = None
    for i in range(0, len(lines) - 1, 2):
        code, value = lines[i], lines[i + 1]
        if code != "0":
            continue
        if value == "SECTION":
            section = lines[i + 3]
        elif value == "ENDSEC":
            section = None
        elif section == "ENTITIES":
            entities[value] += 1
        elif section == "BLOCKS" and value not in ("BLOCK", "ENDBLK"):
            blocks[value] += 1
    return entities, blocks


def dwg_kinds(measure):
    m = re.search(r"types=(\{.*\})", measure)
    if not m:
        return None
    return collections.Counter({k: int(v) for k, v in re.findall(r"'([^']+)': (\d+)", m.group(1))})


# Calls that complete the geometry of a new object. A reference case may hold these and no other call.
DEFINING = {"vs.AddVertex3D", "vs.AppendRoofEdge", "vs.NurbsSetPt3D", "vs.NurbsSetWeight", "vs.ResetObject"}

# Every measured DXF and DWG artifact holds a VIEWPORT entity. The table leaves it out.
DOCUMENT_ENTITIES = {"VIEWPORT"}


def reference_case(record):
    """Return the one object of a case that draws a single plain object, or None."""
    if len(record["objects"]) != 1 or "layers" in record or "classes" in record or "document" in record:
        return None
    o = record["objects"][0]
    if any(k in o for k in ("working_plane", "in")) or any(c["api"] not in DEFINING for c in o.get("calls", [])):
        return None
    if "resources" in record:
        return None
    return o


def entity_kinds(root, records, pairs):
    """Measure the entity kinds of each object type in the cases that draw one plain object."""
    rows = []
    for case, record in records.items():
        o = reference_case(record)
        if o is None:
            continue
        for p in pairs:
            if p["case"] != case or p["state"] != "artifact" or p["profile"] not in ("dxf.all-content", "dwg.all-content"):
                continue
            row = {"type": o["type"]}
            if "plugin" in o:
                row["plugin"] = o["plugin"]
            row.update({"format": p["format"], "case": case, "artifact_path": p["artifact_path"]})
            if p["format"] == "dxf":
                entities, blocks = dxf_kinds(os.path.join(root, p["artifact_path"]))
                row["entities"] = {k: v for k, v in sorted(entities.items()) if k not in DOCUMENT_ENTITIES}
                row["block_entities"] = dict(sorted(blocks.items()))
            else:
                kinds = dwg_kinds(p["inert_measure"])
                if kinds is None:
                    continue
                row["entities"] = {k: v for k, v in sorted(kinds.items()) if k not in DOCUMENT_ENTITIES}
            rows.append(row)
    rows.sort(key=lambda r: (r["type"], r.get("plugin", ""), r["format"], r["case"]))
    return rows


def digest(record):
    text = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()
