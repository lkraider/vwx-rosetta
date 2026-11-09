#!/usr/bin/env python3
"""Audit fixture recipe geometry against required mesh profiles."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import struct
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECIPE_DIR = ROOT / "driver/inventory/scripts"
MATRIX_PATH = ROOT / "driver/inventory/matrix.tsv"
BINDINGS_PATH = Path(os.environ.get("VWX_BINDINGS", ROOT / "driver/sdk/vs.py"))
FILES_DIR = ROOT / "files"
NEGATIVES_PATH = ROOT / "ledger/negatives.tsv"
TABLE_PATH = ROOT / "ledger/recipe-profile-audit.tsv"

MESH_PROFILES = {
    "obj.mesh": "obj",
    "fbx.mesh": "fbx",
    "3ds.mesh": "3ds",
    "gltf.mesh": "gltf",
}
PROFILE_ORDER = ("obj.mesh", "fbx.mesh", "3ds.mesh", "gltf.mesh")
RISK_CLASSES = {"no_geometry", "2d_only", "3d_container"}
CALL_RE = re.compile(r"\bvs\.([A-Za-z_]\w*)\s*\(")

# Calls are grouped by their Vectorworks API meaning. The mapping is checked
# against the binding names and categories when that local binding is readable.
CALL_KINDS: dict[str, str] = {}


def add(kind: str, names: str) -> None:
    for name in names.split():
        if name in CALL_KINDS:
            raise RuntimeError(f"duplicate API classification for {name}")
        CALL_KINDS[name] = kind


add("2d", """
    Add2DVertex AddPoint Arc BeginPoly ClosePoly ConvertToPolygon EndPoly
    HRotate ImportImageFile LineTo LinearDim Locus MoveTo OpenPoly Oval
    RRect Rect SetVertexVisibility CreateText TextOrigin TextRotate TextSize Mirror AngularDim
    CircularDim AssociateLinearDimension CreateCustomObjectN CreateCustomObjectPath ArcByCenter
    SetTextJust SetTextSize SetTextStyle SetTextVerticalAlign TextFont TextJust TextVerticalAlign
""")
add("3d", """
    Add3DPt AddSolid AddVertex3D AppendRoofEdge BeginMXtrd BeginMesh
    BeginPoly3D BeginSweep BeginXtrd CnvrtToGenericSolid ConvertToNURBS
    CreateCone CreateCustomObject CreateHemisphere CreateLight CreateNurbsCurve
    CreateTaperedExtrude CreateExtrudeAlongPath
    CreateNurbsSurface CreateRoof CreateShell CreateSlab CreateSphere EndMXtrd
    EndMesh EndPoly3D EndSweep EndXtrd GroupToMesh HScale3D Locus3D Move3DObj
    NurbsSetPt3D NurbsSetWeight Set3DRot SubtractSolid IntersectSolid
    TrimNurbsSurface Wall Space_CreateSpace SetIsCurtainWall CreateLoftSurfaces
    AddSymToWall JoinWalls RoundWall SetLightDirection SetLightFalloff
    CreateGableDormer CreateSkylight SetDormerAttributes SetSkylight BeginFloor BeginRoof
""")
add("container", """
    BeginGroup EndGroup BeginSym EndSym Symbol CreateLayer Layer LayerRef
    SetLayerElevation SetLScale HideLayer
""")
add("document", """
    ActLayer DelObject LNewObj Name2Index NameObject ResetObject SetDocGeoRefByUsrOrg SetName SetOriginAbsolute
    GetFontID SetObjectVariableBoolean SetObjectVariableInt SetObjectVariableLongInt SetObjectVariableReal SetSelect SetUnits SetWorkingPlaneN SetDimStd
    SetPref DoMenuTextByName
""")
add("resource", """
    AddTileGeometryObject AddVectorFillLayer BeginFolder BeginVectorFillN
    CreateGradient CreateMaterial CreateSlabStyle CreateTextStyleRes CreateTexture
    CreateTile CreateWallStyle CreateWS CreateWSImage EndFolder EndVectorFill
    HideClass InsertGradientSegment NameClass NewField SetClass SetFPat SetLW
    SetObjMaterialHandle SetRField SetRecord SetWSCellFormula SetClLSN SetClLW
    SetClPenFore SetDashStyleN SetLSByClass SetLSN SetLWByClass
    BuildResourceList ImportResourceToCurrentFile
    SetPenColorByClass SetVectorFill SetClFillBack SetClFillFore SetFillBack
    SetFillColorByClass SetFillFore SetObjBeginningMarker SetObjEndMarker
    SetPenFore SetTexMapRealN SetTextureRefN EnableDropShadow SetDropShadowData
    SetClFPat SetFPatByClass SetClTextureG SetClUseTexture RecalculateWS
    CreateImageFromPaint SetCLOpacityN SetImageCropObject SetImageCropVisible SetOpacityByClassN SetOpacityN
""")
add("view", """
    AddVPAnnotationObject CreateVP SaveSheet SetVPCropObject SetVPLayerVisibility
    SetView SetVPClassVisibility UpdateVP
""")

# The recipe block distinction is narrower than the API class distinction.
# Extrudes, meshes, and sweeps create 3D geometry, not symbol/group containers.
CONTAINER_BLOCK_START = {"BeginSym": "symbol", "BeginGroup": "group"}
CONTAINER_BLOCK_END = {"EndSym": "symbol", "EndGroup": "group"}
FIELDS = [
    "case_id",
    "recipe_file",
    "geometry_class",
    "calls_3d",
    "calls_2d",
    "calls_container",
    "required_mesh_profiles",
    "at_risk_profiles",
    "artifact_state",
    "artifact_measure",
    "note",
]


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def binding_categories() -> tuple[dict[str, str], bool]:
    """Return API Category text for locally readable binding definitions."""
    if not BINDINGS_PATH.is_file():
        return {}, False
    source = BINDINGS_PATH.read_text(encoding="utf-8", errors="replace")
    lines = source.splitlines()
    result: dict[str, str] = {}
    for index, line in enumerate(lines):
        match = re.match(r"def\s+([A-Za-z_]\w*)\s*\(", line)
        if not match:
            continue
        name = match.group(1)
        end = min(index + 180, len(lines))
        for cursor in range(index + 1, end):
            if re.match(r"def\s+[A-Za-z_]\w*\s*\(", lines[cursor]):
                end = cursor
                break
        for row in lines[index:end]:
            category = re.search(r"Category:\s*([^\r\n]+)", row)
            if category:
                result[name] = category.group(1).strip()
                break
    return result, True


def extract_calls(source: str) -> list[str]:
    return CALL_RE.findall(source)


def classify_recipe(source: str, call_kinds: dict[str, str]) -> tuple[str, list[str]]:
    calls = extract_calls(source)
    unknown = sorted({call for call in calls if call not in call_kinds})
    if unknown:
        return "unknown", calls

    has_2d = any(call_kinds[call] == "2d" for call in calls)
    has_3d = any(call_kinds[call] == "3d" for call in calls)
    if not has_2d and not has_3d:
        return "no_geometry", calls
    if has_2d and not has_3d:
        return "2d_only", calls
    if not has_3d:
        return "unknown", calls

    stack: list[str] = []
    has_3d_in_container = False
    for call in calls:
        if call in CONTAINER_BLOCK_END:
            expected = CONTAINER_BLOCK_END[call]
            if stack and stack[-1] == expected:
                stack.pop()
            elif expected in stack:
                stack = stack[: stack.index(expected)]
            continue
        if call_kinds[call] == "3d" and stack:
            has_3d_in_container = True
        if call in CONTAINER_BLOCK_START:
            stack.append(CONTAINER_BLOCK_START[call])
    return ("3d_container" if has_3d_in_container else "3d_mesh"), calls


def count_3ds_records(data: bytes) -> tuple[int, int]:
    """Walk 3DS container chunks and count vertex and face records."""
    vertex_records = 0
    face_records = 0
    containers = {0x4D4D, 0x3D3D, 0x4000, 0x4100, 0x4120}

    def walk(start: int, end: int) -> None:
        nonlocal vertex_records, face_records
        cursor = start
        while cursor < end:
            if cursor + 6 > end:
                raise ValueError("truncated 3DS chunk header")
            chunk_id, chunk_size = struct.unpack_from("<HI", data, cursor)
            chunk_end = cursor + chunk_size
            if chunk_size < 6 or chunk_end > end:
                raise ValueError(f"invalid 3DS chunk size for 0x{chunk_id:04x}")
            payload = cursor + 6
            child_start = chunk_end
            if chunk_id == 0x4110:
                if payload + 2 > chunk_end:
                    raise ValueError("truncated 3DS vertex chunk")
                vertex_records += struct.unpack_from("<H", data, payload)[0]
            elif chunk_id == 0x4120:
                if payload + 2 > chunk_end:
                    raise ValueError("truncated 3DS face chunk")
                count = struct.unpack_from("<H", data, payload)[0]
                face_records += count
                child_start = payload + 2 + count * 8
                if child_start > chunk_end:
                    raise ValueError("truncated 3DS face records")
            elif chunk_id == 0x4000:
                terminator = data.find(b"\0", payload, chunk_end)
                if terminator < 0:
                    raise ValueError("unterminated 3DS object name")
                child_start = terminator + 1
            elif chunk_id in containers:
                child_start = payload

            if chunk_id in containers and child_start < chunk_end:
                walk(child_start, chunk_end)
            cursor = chunk_end

    walk(0, len(data))
    return vertex_records, face_records


def measure_artifact(
    case_id: str, profile: str, negatives: dict[tuple[str, str], str]
) -> tuple[str, str, bool]:
    fmt = MESH_PROFILES[profile]
    path = FILES_DIR / case_id / f"{case_id}.{fmt}"
    if path.is_file():
        data = path.read_bytes()
        if fmt == "obj":
            text = data.decode("utf-8", errors="replace")
            vertices = sum(line.startswith("v ") for line in text.splitlines())
            faces = sum(line.startswith("f ") for line in text.splitlines())
            measure = f"v={vertices} f={faces}"
            no_mesh = vertices == 0 or faces == 0
        elif fmt == "fbx":
            has_vertices = b"Vertices" in data
            measure = "Vertices node=yes" if has_vertices else "no Vertices node"
            no_mesh = not has_vertices
        elif fmt == "3ds":
            vertices, faces = count_3ds_records(data)
            measure = f"v={vertices} f={faces}"
            no_mesh = vertices == 0 or faces == 0
        elif fmt == "gltf":
            doc = json.loads(data)
            accessors = doc.get("accessors", [])
            vertices = triangles = 0
            for mesh in doc.get("meshes", []):
                for primitive in mesh.get("primitives", []):
                    position = primitive.get("attributes", {}).get("POSITION")
                    count = accessors[position]["count"] if position is not None else 0
                    vertices += count
                    if "indices" in primitive:
                        count = accessors[primitive["indices"]]["count"]
                    triangles += count // 3
            measure = f"v={vertices} t={triangles}"
            no_mesh = vertices == 0 or triangles == 0
        else:
            raise AssertionError(fmt)
        return "artifact", measure, no_mesh

    status = negatives.get((case_id, profile))
    if status:
        return "negative", status, True
    return "none", "no artifact", True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero when the generated TSV differs from the file on disk",
    )
    args = parser.parse_args()

    for required in (RECIPE_DIR, MATRIX_PATH, FILES_DIR, NEGATIVES_PATH):
        if not required.exists():
            print(f"missing required input: {required}", file=sys.stderr)
            return 2

    recipes = sorted(RECIPE_DIR.glob("*.py"))
    recipe_by_case = {path.stem: path for path in recipes}
    if len(recipes) != 193 or len(recipe_by_case) != len(recipes):
        print(f"expected 193 unique .py recipes, found {len(recipes)}", file=sys.stderr)
        return 2

    matrix = read_tsv(MATRIX_PATH)
    required_by_case: dict[str, list[str]] = {}
    for row in matrix:
        if row["applicable"] == "yes" and row["profile_id"] in MESH_PROFILES:
            required_by_case.setdefault(row["case_id"], []).append(row["profile_id"])
    missing_recipes = sorted(set(required_by_case) - set(recipe_by_case))
    if missing_recipes:
        print(f"required cases lack recipes: {', '.join(missing_recipes)}", file=sys.stderr)
        return 2

    negatives = {
        (row["case"], row["profile"]): row["status"]
        for row in read_tsv(NEGATIVES_PATH)
    }
    binding_categories_map, binding_readable = binding_categories()
    if not binding_readable:
        print(
            f"{BINDINGS_PATH} is missing, so the binding check is skipped. "
            "driver/sdk/README.md says how to fetch it.",
            file=sys.stderr,
        )
    call_counts: Counter[str] = Counter()
    for recipe_path in recipe_by_case.values():
        call_counts.update(extract_calls(recipe_path.read_text(encoding="utf-8")))

    unresolved = sorted(set(call_counts) - set(CALL_KINDS))
    if unresolved:
        print(f"unclassified Vectorworks calls: {', '.join(unresolved)}", file=sys.stderr)
        return 2
    if binding_readable:
        missing_bindings = sorted(set(call_counts) - set(binding_categories_map))
        if missing_bindings:
            print(
                "readable binding lacks definitions/categories for: "
                + ", ".join(missing_bindings),
                file=sys.stderr,
            )
            return 2

    rows: list[dict[str, str]] = []
    no_geometry_pairs = 0
    for case_id, recipe_path in sorted(recipe_by_case.items()):
        source = recipe_path.read_text(encoding="utf-8")
        geometry_class, calls = classify_recipe(source, CALL_KINDS)
        callset = set(calls)
        calls_3d = sorted(call for call in callset if CALL_KINDS[call] == "3d")
        calls_2d = sorted(call for call in callset if CALL_KINDS[call] == "2d")
        calls_container = sorted(call for call in callset if CALL_KINDS[call] == "container")
        required_profiles = sorted(
            set(required_by_case.get(case_id, [])), key=PROFILE_ORDER.index
        )
        for profile in required_profiles or [""]:
            if profile:
                state, measure, no_mesh = measure_artifact(case_id, profile, negatives)
                if no_mesh:
                    no_geometry_pairs += 1
                at_risk = profile if geometry_class in RISK_CLASSES else ""
                if geometry_class == "no_geometry":
                    note = "recipe has no explicit 2D or 3D geometry producer"
                elif geometry_class == "2d_only":
                    note = "recipe produces 2D geometry but no 3D geometry"
                elif geometry_class == "3d_container":
                    note = "3D geometry is created inside a symbol or group block"
                else:
                    note = ""
            else:
                state, measure, at_risk, note = "none", "", "", ""

            rows.append(
                {
                    "case_id": case_id,
                    "recipe_file": str(recipe_path.relative_to(ROOT)),
                    "geometry_class": geometry_class,
                    "calls_3d": ",".join(calls_3d),
                    "calls_2d": ",".join(calls_2d),
                    "calls_container": ",".join(calls_container),
                    "required_mesh_profiles": profile,
                    "at_risk_profiles": at_risk,
                    "artifact_state": state,
                    "artifact_measure": measure,
                    "note": note if at_risk else "",
                }
            )

    output_lines = ["\t".join(FIELDS)]
    output_lines.extend("\t".join(row[field] for field in FIELDS) for row in rows)
    expected = ("\n".join(output_lines) + "\n").encode("utf-8")

    if args.check:
        try:
            actual = TABLE_PATH.read_bytes()
        except OSError as error:
            print(f"cannot read generated table {TABLE_PATH}: {error}", file=sys.stderr)
            return 1
        if actual != expected:
            print(f"stale audit table: {TABLE_PATH}", file=sys.stderr)
            return 1
        print(
            f"check ok: {TABLE_PATH} ({len(rows)} rows, "
            f"{no_geometry_pairs} required mesh pairs without mesh geometry)"
        )
        return 0

    TABLE_PATH.write_bytes(expected)
    print(
        f"wrote {TABLE_PATH}: {len(rows)} rows, {len(recipes)} recipes, "
        f"{len(call_counts)} distinct calls, {no_geometry_pairs} required mesh pairs "
        "without mesh geometry"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
