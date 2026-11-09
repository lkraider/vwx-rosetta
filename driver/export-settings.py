#!/usr/bin/env python3
"""Publish per-profile export settings from the UI and scripted routes."""

import argparse
import ast
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "driver"))
from profile_names import shows_hidden  # noqa: E402
DRIVER = ROOT / "driver/ui/sweep-ui.py"
SCRIPTED_DRIVER = ROOT / "driver/scripted/sweep-scripted.sh"
SCRIPTED_ROUTES = ROOT / "driver/scripted/routes.tsv"
SCRIPTED_EXPORTER = ROOT / "driver/scripted/exporter.py"
COVERAGE = ROOT / "ledger/coverage.tsv"
LEDGER = ROOT / "ledger/corpus-ledger.jsonl"
OUTPUT = ROOT / "ledger/export-settings.tsv"
PROFILE_DIR = ROOT / "driver/inventory/pack-skeleton/profiles"
HEADER = [
    "profile", "format", "dialog_title", "control", "kind", "value",
    "view_steps", "state_overrides", "source",
]
LEGACY_OMITTED_OPTIONS = {
    ("csv.worksheet", "delimiter"),
    ("ifc.semantic", "ifc_schema"),
    ("ifc.semantic", "mvd"),
    ("stl.binary.high-all", "binary"),
    ("stl.binary.high-all", "percent_tess"),
    ("stl.binary.high-all", "objects"),
}

# The driver sets the value of these controls from the given profile revision. The
# earlier revisions made the stored files, and their run records show what was set.
REVISED_CONTROLS = {
    ("dwg.visible-only", "hidden_content"): 3,
    ("dxf.visible-only", "hidden_content"): 2,
}


def stored_entries():
    latest = {}
    with LEDGER.open(encoding="utf-8") as ledger:
        for line in ledger:
            entry = json.loads(line)
            # Early ledger lines hold an absolute path into the repository they were written in.
            path = entry["path"]
            latest[path[path.find("files/"):]] = entry
    stored = {}
    for path, entry in latest.items():
        if (ROOT / path).exists():
            stored.setdefault(entry["profile"], []).append(entry)
    return stored


def recorded_value(entry, label):
    record = ROOT / "runs" / entry["run_id"] / "records" / (
        f"{entry['case']}.{entry['profile']}.json")
    if not record.exists():
        return None
    found = []

    def walk(node):
        if isinstance(node, dict):
            if label in (node.get("selector"), node.get("control"), node.get("label")):
                found.append(str(node.get("value")))
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(json.loads(record.read_text(encoding="utf-8")))
    return found[-1] if found else None


def control_value(profile, control, stored):
    value = scalar(control["value"])
    since = REVISED_CONTROLS.get((profile, control["field"]))
    if since is None:
        return value
    older = [entry for entry in stored.get(profile, ())
             if int(entry.get("profile_revision") or 1) < since]
    if not older:
        return value
    counts = {}
    for entry in older:
        recorded = recorded_value(entry, control["control"])
        counts[recorded] = counts.get(recorded, 0) + 1
    parts = [f"{value} from profile revision {since}"]
    for recorded in sorted(v for v in counts if v is not None):
        parts.append(f"{counts[recorded]} stored files of earlier revisions: set to {recorded} by the driver")
    if None in counts:
        parts.append(f"{counts[None]} stored files of earlier revisions: not set by the driver, "
                     "the dialog kept its last value, unknown")
    return ". ".join(parts)


def assigned_formats(source, name="FORMATS"):
    tree = ast.parse(source, filename=str(DRIVER))
    value_node = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name
            for target in node.targets
        ):
            value_node = node.value
            break
        if (isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name)
                and node.target.id == name):
            value_node = node.value
            break
    if value_node is None:
        raise ValueError(f"module-level {name} assignment not found")
    formats = ast.literal_eval(value_node)
    if not isinstance(formats, dict):
        raise ValueError(f"{name} is not a dictionary")
    entry_nodes = {
        ast.literal_eval(key_node): entry_node
        for key_node, entry_node in zip(value_node.keys, value_node.values)
    }
    return formats, entry_nodes


def dict_value_node(node, name):
    for key_node, value_node in zip(node.keys, node.values):
        if ast.literal_eval(key_node) == name:
            return value_node
    return None


def source_line(path, line, detail=""):
    suffix = f" ({detail})" if detail else ""
    return f"{path}:{line}{suffix}"


def profile_line(path, field, after=None):
    quoted = json.dumps(field)
    seen = after is None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not seen:
            seen = line.lstrip().startswith(json.dumps(after) + ":")
            continue
        if line.lstrip().startswith(quoted + ":"):
            return number
    return 1


def scalar(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return str(value)


def option_kind(name, value):
    if name in {"binary", "export_materials", "classes_as_layers",
                "export_classes_as_layers", "solid_as_surface"}:
        return "checkbox"
    if name.endswith("_version") or name in {
        "export_3d_as", "view", "render_mode", "objects", "schema_version"
    }:
        return "popup"
    if isinstance(value, bool):
        return "checkbox"
    return "text_field"


def read_profiles():
    profiles = {}
    for path in sorted(PROFILE_DIR.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        profiles[data["profile_id"]] = (path, data)
    return profiles


def read_corpus_profiles():
    found = {}
    with COVERAGE.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            previous = found.setdefault(row["profile"], row["format"])
            if previous != row["format"]:
                raise ValueError(f"profile {row['profile']} has multiple formats")
    return found


def driver_controls(spec, entry_node):
    """Return settable controls and the lines that specify their values."""
    controls = []
    setup_node = dict_value_node(entry_node, "setup")
    setup_items = setup_node.elts if isinstance(setup_node, (ast.List, ast.Tuple)) else []
    text_names = iter(("Width", "Height"))
    for item, item_node in zip(spec.get("setup", []), setup_items):
        selector, value = item[:2]
        if selector in ("tab", "pane"):
            continue
        if selector == "type":
            label = next(text_names, "Focused text field")
            kind = "text_field"
            field = label.lower()
        else:
            label = selector
            prefix = selector.split("/", 1)[0]
            kind = {
                "popup": "popup", "radio": "radio", "checkbox": "checkbox",
                "text_field": "text_field",
            }.get(prefix, "text_field")
            field = item[2] if len(item) > 2 else ""
        controls.append({
            "control": label,
            "kind": kind,
            "value": value,
            "source": source_line("driver/ui/sweep-ui.py", item_node.lineno),
            "field": field,
        })

    # The focused image fields are described as Width and Height in the driver.
    for control in controls:
        if control["control"] == "Width":
            control["field"] = "width_px"
        elif control["control"] == "Height":
            control["field"] = "height_px"

    rescue_node = dict_value_node(entry_node, "rescue")
    if rescue_node is not None:
        for item, item_node in zip(spec.get("rescue", []), rescue_node.elts):
            selector, value = item
            prefix = selector.split("/", 1)[0]
            controls.append({
                "control": selector,
                "kind": {"popup": "popup", "radio": "radio",
                         "checkbox": "checkbox", "text_field": "text_field"}.get(
                             prefix, "text_field"),
                "value": value,
                "source": source_line("driver/ui/sweep-ui.py", item_node.lineno),
                "field": "",
            })
    return controls


def disabled_rows(profile, setup, disabled, disabled_nodes):
    """Return (control, kind, value, source) for each DISABLED_BY control that setup disables."""
    values = {item[0]: item[1] for item in setup}
    rows = []
    for control, (by, value, reason) in disabled.items():
        if values.get(by) != value:
            continue
        if control in values:
            raise ValueError(f"profile {profile} sets {control}, which is disabled by {reason}")
        kind = control.split("/", 1)[0]
        rows.append((control, kind, f"disabled by {reason}",
                     source_line("driver/ui/sweep-ui.py", disabled_nodes[control].lineno)))
    return rows


def code_line(source, needle):
    for number, line in enumerate(source.splitlines(), 1):
        if needle in line:
            return number
    return 1


def scripted_format_names(source):
    for number, line in enumerate(source.splitlines(), 1):
        match = re.match(r'^\s*FORMATS="([^"]*)"\s*$', line)
        if match:
            names = [name for name in match.group(1).split(",") if name]
            if not names:
                raise ValueError("scripted FORMATS list is empty")
            return names
    raise ValueError("scripted FORMATS assignment not found")


def scripted_route_rows(source):
    rows = {}
    reader = csv.DictReader(source.splitlines(), delimiter="\t")
    for line, row in enumerate(reader, 2):
        rows[row["format"]] = (line, row)
    return rows


def binding_argument_names(signature):
    match = re.search(r"\((.*?)\)", signature)
    if not match:
        raise ValueError(f"binding signature has no argument list: {signature}")
    arguments = match.group(1).strip()
    if not arguments:
        return []
    return [part.split(":", 1)[0].strip() for part in arguments.split(",")]


def scripted_argument_nodes(format_name, exporter_source):
    tree = ast.parse(exporter_source, filename=str(SCRIPTED_EXPORTER))
    routes_node = next(
        node.value for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "ROUTES"
                for target in node.targets)
    )
    route_node = dict_value_node(routes_node, format_name)
    if isinstance(route_node, ast.Call) and isinstance(route_node.func, ast.Name) \
            and route_node.func.id == "_direct":
        argf = route_node.args[3]
        if not isinstance(argf, ast.Lambda) or not isinstance(argf.body, ast.Tuple):
            raise ValueError(f"{format_name} direct route has no argument tuple")
        return list(argf.body.elts)

    if isinstance(route_node, ast.Name):
        handler = next((node for node in tree.body
                        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                        and node.name == route_node.id), None)
        if handler is not None:
            for node in ast.walk(handler):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "call" and node.args
                        and isinstance(node.args[0], ast.Constant)
                        and node.args[0].value.startswith("Export")):
                    return list(node.args[1:])
    raise ValueError(f"cannot locate binding arguments for scripted format {format_name}")


def scripted_argument_value(node, source):
    if isinstance(node, ast.Constant):
        return scalar(node.value)
    if isinstance(node, ast.Name):
        return node.id
    # The scripted sweep sends no stl_tess option, so this expression resolves to
    # the documented default passed by the handler.
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
            and node.func.id == "float" and node.args:
        option = node.args[0]
        if (isinstance(option, ast.Call) and isinstance(option.func, ast.Attribute)
                and option.func.attr == "get" and len(option.args) > 1
                and isinstance(option.args[1], ast.Constant)):
            return scalar(option.args[1].value)
    expression = ast.get_source_segment(source, node)
    return expression if expression is not None else ast.unparse(node)


def build_scripted_rows(driver_source, routes_source, exporter_source, corpus_profiles):
    formats = scripted_format_names(driver_source)
    route_rows = scripted_route_rows(routes_source)
    profiles_by_format = {}
    for profile, format_name in corpus_profiles.items():
        profiles_by_format.setdefault(format_name, []).append(profile)

    rows = []
    for format_name in formats:
        if format_name not in route_rows:
            raise ValueError(f"scripted format {format_name!r} has no routes.tsv row")
        route_line, route = route_rows[format_name]
        route_profile_list = profiles_by_format.get(format_name, [])
        if len(route_profile_list) > 1:
            raise ValueError(f"scripted format {format_name!r} has multiple corpus profiles")
        profile = route_profile_list[0] if route_profile_list else "none"
        dialog_title = "none (direct binding call)"
        view_steps = ""
        state_overrides = "none"

        argument_names = binding_argument_names(route["function and full signature (vs.py line)"])
        argument_nodes = scripted_argument_nodes(format_name, exporter_source)
        if len(argument_names) != len(argument_nodes):
            raise ValueError(
                f"{format_name} binding signature has {len(argument_names)} arguments, "
                f"but exporter passes {len(argument_nodes)}"
            )
        for argument_name, argument_node in zip(argument_names, argument_nodes):
            rows.append([
                profile, format_name, dialog_title, argument_name, "binding_call",
                scripted_argument_value(argument_node, exporter_source), view_steps,
                state_overrides,
                source_line("driver/scripted/exporter.py", argument_node.lineno),
            ])

        for control, key in (
            ("mechanism", "mechanism"),
            ("binding_signature", "function and full signature (vs.py line)"),
            ("exporter_status", "exporter status without allow_modal"),
            ("evidence_still_missing", "evidence still missing"),
        ):
            value = route[key]
            if control == "evidence_still_missing" and len(value) > 200:
                value = value[:200]
            rows.append([
                profile, format_name, dialog_title, control, "route_metadata", value,
                view_steps, state_overrides,
                source_line("driver/scripted/routes.tsv", route_line),
            ])
    return rows


def build_table(source):
    formats, entry_nodes = assigned_formats(source)
    profile_steps, profile_nodes = assigned_formats(source, "PROFILES")
    disabled, disabled_nodes = assigned_formats(source, "DISABLED_BY")
    profile_specs = read_profiles()
    corpus_profiles = read_corpus_profiles()
    stored = stored_entries()
    driver_source = DRIVER.read_text(encoding="utf-8")
    fit_line = code_line(driver_source, 'press_menu(pid_, ["View", "Zoom", "Fit To Objects"])')
    show_others_line = code_line(driver_source, 'press_menu(pid_, ["View", step + " Options", "Show Others"])')

    rows = []
    for profile in sorted(corpus_profiles):
        format_name = corpus_profiles[profile]
        if format_name not in formats:
            raise ValueError(f"coverage format {format_name!r} has no FORMATS entry")
        spec = formats[format_name]
        entry_node = entry_nodes[format_name]
        title = spec.get("options") or "unknown"
        state_condition = "shows_hidden(profile)" if shows_hidden(profile) else ""
        views = [("View > Zoom > Fit To Objects", fit_line, "")]
        if shows_hidden(profile):
            views.extend([
                ("View > Class Options > Show Others", show_others_line, state_condition),
                ("View > Layer Options > Show Others", show_others_line, state_condition),
            ])
        view_node = dict_value_node(entry_node, "view")
        if view_node is not None:
            for path_node in view_node.elts:
                path = ast.literal_eval(path_node)
                views.append((" > ".join(path), path_node.lineno, ""))
        profile_node = profile_nodes.get(profile)
        profile_view_node = (dict_value_node(profile_node, "view")
                             if profile_node is not None else None)
        if profile_view_node is not None:
            for path_node in profile_view_node.elts:
                path = ast.literal_eval(path_node)
                views.append((" > ".join(path), path_node.lineno, ""))
        view_steps = "; ".join(path for path, _line, _condition in views)

        controls = driver_controls(spec, entry_node)
        if profile_node is not None:
            controls += driver_controls(profile_steps[profile], profile_node)
        profile_doc = profile_specs.get(profile)
        profile_data = profile_doc[1] if profile_doc else None
        profile_path = profile_doc[0] if profile_doc else None
        options = profile_data.get("options", {}) if profile_data else {}

        # A profile option that directly corresponds to a driver control is
        # represented by that driver-control row, not repeated as a second row.
        matched = {}
        for control in controls:
            field = control["field"]
            if field in options:
                matched[field] = (scalar(control["value"]), control["source"])
        if "view" in options and profile_view_node is not None:
            view_path, view_line, _condition = views[-1]
            matched["view"] = (
                view_path, source_line("driver/ui/sweep-ui.py", view_line)
            )

        for control in controls:
            rows.append([
                profile, format_name, spec.get("options") or "unknown",
                control["control"], control["kind"],
                control_value(profile, control, stored),
                view_steps, state_condition, control["source"],
            ])
        setup = spec.get("setup", []) + profile_steps.get(profile, {}).get("setup", [])
        for control, kind, value, line in disabled_rows(profile, setup, disabled, disabled_nodes):
            rows.append([
                profile, format_name, spec.get("options") or "unknown",
                control, kind, value, view_steps, state_condition, line,
            ])

        if profile_data:
            for field, value in options.items():
                if field in matched or (profile, field) in LEGACY_OMITTED_OPTIONS:
                    continue
                field_line = profile_line(profile_path, field)
                profile_source = source_line(
                    str(profile_path.relative_to(ROOT)), field_line, f"options.{field}"
                )
                reported = (
                    "not recorded in the profile spec"
                    if value is None else "not set by the driver"
                )
                if field == "view" and value == "as_saved":
                    reported = "the view the source opens in, not set by the driver"
                rows.append([
                    profile, format_name, spec.get("options") or "unknown",
                    field, option_kind(field, value), reported, view_steps,
                    state_condition, profile_source,
                ])

        # An option read from a reference file, and not from a dialog, is published
        # with the file it came from.
        for field, text in (profile_data or {}).get("inferred", {}).items():
            rows.append([
                profile, format_name, spec.get("options") or "unknown", field,
                "inferred", text, view_steps, state_condition,
                source_line(str(profile_path.relative_to(ROOT)),
                            profile_line(profile_path, field, "inferred"), f"inferred.{field}"),
            ])

        reasons = (profile_data or {}).get("state_override_reasons", {})
        for field, value in (profile_data or {}).get("state_overrides", {}).items():
            reported = f"{value}: {reasons[field]}" if field in reasons else value
            rows.append([
                profile, format_name, spec.get("options") or "unknown", field,
                "state_override", reported, view_steps, state_condition,
                source_line(str(profile_path.relative_to(ROOT)),
                            profile_line(profile_path, field, "state_overrides"),
                            f"state_overrides.{field}"),
            ])

        for path, line, condition in views:
            rows.append([
                profile, format_name, spec.get("options") or "unknown", path,
                "view", path, view_steps, condition or state_condition,
                source_line("driver/ui/sweep-ui.py", line),
            ])
        # Keep the mapping referenced so a missing view control cannot silently
        # turn a recorded profile setting into a claim that the driver set it.
        if "view" in matched and not any(row[3] == matched["view"][0] for row in rows):
            raise ValueError(f"view setting was not published for {profile}")

    rows.extend(build_scripted_rows(
        SCRIPTED_DRIVER.read_text(encoding="utf-8"),
        SCRIPTED_ROUTES.read_text(encoding="utf-8"),
        SCRIPTED_EXPORTER.read_text(encoding="utf-8"),
        corpus_profiles,
    ))
    return rows


def render(rows):
    from io import StringIO
    output = StringIO(newline="")
    writer = csv.writer(output, delimiter="\t", lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        content = render(build_table(DRIVER.read_text(encoding="utf-8")))
        if args.check:
            try:
                actual = OUTPUT.read_text(encoding="utf-8")
            except FileNotFoundError:
                print(f"missing generated table: {OUTPUT}", file=sys.stderr)
                return 1
            if actual != content:
                print(f"generated table differs: {OUTPUT}", file=sys.stderr)
                return 1
            return 0
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(content, encoding="utf-8", newline="")
        return 0
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
