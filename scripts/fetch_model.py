#!/usr/bin/env python3
"""Fetch everything useful about one Matterport model into data/<modelId>.json.

Usage:
    python3 scripts/fetch_model.py <modelId>

Auth: HTTP Basic against the Matterport Model API (GraphQL), with
MATTERPORT_API_KEY as the Token ID (username) and MATTERPORT_API_TOKEN as the
Token Secret (password), read from .env in the repo root.

How it works:
  1. Runs a schema introspection query. Every field requested below is checked
     against the live schema before it is sent; nothing is guessed.
  2. Fields that are missing from the schema, marked @beta / limited access,
     deprecated, or that need required arguments we don't supply are skipped.
  3. Each section is queried separately. If the API returns errors for a field,
     that field is dropped and the section is retried, so one failing field
     never loses the rest.
  4. Every skipped field is logged to stderr and recorded under "skipped" in
     the output file.

The script only reads from the API. It writes one new file and does not touch
any other files in data/.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

ENDPOINT = "https://api.matterport.com/api/models/graph"
REPO_ROOT = Path(__file__).resolve().parent.parent
MAX_RETRIES_PER_SECTION = 15

# ---------------------------------------------------------------------------
# Section specs.
#   "*"            -> all scalar/enum fields of that type (from introspection)
#   {...}          -> nested selection
#   ("args", spec) -> field with arguments; args is a literal GraphQL arg string
# Field names below were taken from the live schema introspection.
# ---------------------------------------------------------------------------
METRIC = "units: metric"

POINT3 = {"x": 1, "y": 1, "z": 1}
QUAT = {"w": 1, "x": 1, "y": 1, "z": 1}

SECTIONS = {
    "details": {
        "id": 1, "name": 1, "description": 1, "created": 1, "modified": 1,
        "modifiedByEditor": 1, "state": 1, "demo": 1, "internalId": 1,
        "organization": 1, "accessVisibility": 1,
        "dimensionEstimates": (METRIC, "*"),
        "options": {"unitType": 1, "roomBoundsEnabled": 1, "floorplanEnabled": 1},
        "publication": {"published": 1, "address": 1, "url": 1, "externalUrl": 1,
                        "summary": 1, "presentedBy": 1},
        "propertyClassifications": "*",
    },
    "address": {
        "address": "*",
    },
    "geolocation": {
        "geolocation": "*",
        "geocoordinates": {
            "latitude": 1, "longitude": 1, "altitude": 1, "source": 1,
            "rotation": QUAT, "translation": POINT3,
        },
        "publication": {"geolocation": "*"},
    },
    "floors": {
        "floors": {
            "id": 1, "label": 1, "sequence": 1,
            "dimensionEstimates": (METRIC, "*"),
        },
    },
    "rooms": {
        "rooms": {
            "id": 1, "label": 1, "tags": 1, "keywords": 1,
            "floor": {"id": 1, "label": 1, "sequence": 1},
            "classifications": "*",
            "dimensionEstimates": (METRIC, "*"),
            "ceiling": (METRIC, "*"),
            "boundary": {
                "edges": {
                    "id": 1, "type": 1, "thickness": 1, "centerLineBias": 1,
                    "vertices": {"id": 1, "position": {"x": 1, "y": 1}},
                    "openings": {
                        "id": 1, "type": 1, "label": 1, "width": 1, "height": 1,
                        "lowerElevation": 1, "relativeCenter": 1,
                        "metadata": "*",
                    },
                },
            },
            "holes": {
                "edges": {
                    "id": 1, "type": 1, "thickness": 1, "centerLineBias": 1,
                    "vertices": {"id": 1, "position": {"x": 1, "y": 1}},
                    "openings": {
                        "id": 1, "type": 1, "label": 1, "width": 1, "height": 1,
                        "lowerElevation": 1, "relativeCenter": 1,
                    },
                },
            },
        },
    },
    "panoramas": {
        "panoLocations": {
            "id": 1, "label": 1, "variant": 1, "placement": 1, "source": 1,
            "position": POINT3, "rotation": QUAT,
            "options": "*",
            "anchor": {
                "id": 1, "tags": 1, "neighbors": 1, "position": POINT3,
                "floor": {"id": 1}, "room": {"id": 1},
            },
            "skyboxes": {
                "id": 1, "resolution": 1, "format": 1, "status": 1,
                "url": 1, "urlTemplate": 1, "children": 1, "validUntil": 1,
            },
        },
    },
    "assets": {
        "assets": {
            "meshes": "*",
            "textures": "*",
            "floorplans": {
                "id": 1, "format": 1, "provider": 1, "flags": 1, "status": 1,
                "url": 1, "validUntil": 1, "width": 1, "height": 1,
                "resolution": 1, "origin": {"x": 1, "y": 1}, "floor": {"id": 1},
            },
            "resources": "*",
        },
    },
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def log(msg):
    print(msg, file=sys.stderr)


def load_env():
    env = dict(os.environ)
    path = REPO_ROOT / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    for k in ("MATTERPORT_API_KEY", "MATTERPORT_API_TOKEN"):
        if not env.get(k):
            sys.exit(f"Missing {k} in .env or environment")
    return env["MATTERPORT_API_KEY"], env["MATTERPORT_API_TOKEN"]


def post(auth, query, variables=None):
    for attempt in range(4):
        r = requests.post(
            ENDPOINT,
            json={"query": query, "variables": variables or {}},
            auth=auth,
            headers={"Content-Type": "application/json"},
            timeout=120,
        )
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
            time.sleep(2 ** attempt)
            continue
        if r.status_code == 401:
            sys.exit("401 Unauthorized: check MATTERPORT_API_KEY / MATTERPORT_API_TOKEN")
        r.raise_for_status()
        return r.json()


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
TYPE_REF = "kind name ofType { kind name ofType { kind name ofType { kind name } } }"
INTROSPECTION = f"""
query {{
  __schema {{
    types {{
      kind name
      fields(includeDeprecated: true) {{
        name description isDeprecated
        args {{ name type {{ {TYPE_REF} }} }}
        type {{ {TYPE_REF} }}
      }}
    }}
  }}
}}"""


class Schema:
    def __init__(self, raw):
        self.types = {t["name"]: t for t in raw["data"]["__schema"]["types"]}

    @staticmethod
    def unwrap(t):
        while t.get("ofType") is not None and t["kind"] in ("NON_NULL", "LIST"):
            t = t["ofType"]
        return t

    def field(self, type_name, field_name):
        for f in self.types.get(type_name, {}).get("fields") or []:
            if f["name"] == field_name:
                return f
        return None

    def leaf_fields(self, type_name):
        """Scalar/enum fields with no required args, not deprecated, not beta."""
        out = []
        for f in self.types[type_name].get("fields") or []:
            base = self.unwrap(f["type"])
            if base["kind"] not in ("SCALAR", "ENUM"):
                continue
            if f["isDeprecated"] or skip_reason(f):
                continue
            if any(a["type"]["kind"] == "NON_NULL" for a in f["args"]):
                continue
            out.append(f["name"])
        return out


def skip_reason(field):
    desc = (field.get("description") or "").lower()
    if "@beta" in desc or "limited access" in desc:
        return "beta / limited access"
    return None


# ---------------------------------------------------------------------------
# Query building: spec -> validated selection tree -> GraphQL text
# ---------------------------------------------------------------------------
def build_tree(schema, type_name, spec, path, skipped, section):
    """Return {field: (args, subtree_or_None)} using only fields in the schema."""
    if spec == "*":
        return {name: ("", None) for name in schema.leaf_fields(type_name)}
    tree = {}
    for name, sub in spec.items():
        fpath = path + [name]
        f = schema.field(type_name, name)
        if f is None:
            skipped.append({"section": section, "field": ".".join(fpath),
                            "reason": f"not in schema (type {type_name})"})
            continue
        reason = skip_reason(f) or ("deprecated" if f["isDeprecated"] else None)
        if reason:
            skipped.append({"section": section, "field": ".".join(fpath), "reason": reason})
            continue
        args = ""
        if isinstance(sub, tuple):
            args, sub = sub
        given = {a.split(":")[0].strip() for a in args.split(",") if a.strip()}
        missing = [a["name"] for a in f["args"]
                   if a["type"]["kind"] == "NON_NULL" and a["name"] not in given]
        if missing:
            skipped.append({"section": section, "field": ".".join(fpath),
                            "reason": f"requires args {missing}"})
            continue
        base = schema.unwrap(f["type"])
        if base["kind"] in ("SCALAR", "ENUM"):
            tree[name] = (args, None)
        elif base["kind"] in ("OBJECT", "INTERFACE"):
            subspec = "*" if sub in (1, "*") else sub
            child = build_tree(schema, base["name"], subspec, fpath, skipped, section)
            if child:
                tree[name] = (args, child)
        else:
            skipped.append({"section": section, "field": ".".join(fpath),
                            "reason": f"{base['kind']} type not expanded"})
    return tree


def render(tree, indent=2):
    pad = " " * indent
    lines = []
    for name, (args, child) in tree.items():
        head = f"{name}({args})" if args else name
        if child is None:
            lines.append(pad + head)
        else:
            lines.append(pad + head + " {")
            lines.append(render(child, indent + 2))
            lines.append(pad + "}")
    return "\n".join(lines)


def remove_path(tree, parts):
    """Remove a field path (list of names) from the tree. Returns True if removed."""
    node = tree
    for p in parts[:-1]:
        if p not in node or node[p][1] is None:
            return False
        node = node[p][1]
    if parts and parts[-1] in node:
        del node[parts[-1]]
        return True
    return False


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
def fetch_section(auth, schema, model_id, section, spec, skipped):
    tree = build_tree(schema, "Model", spec, ["model"], skipped, section)
    for _ in range(MAX_RETRIES_PER_SECTION):
        if not tree:
            return None
        query = "query($id: ID!) {\n  model(id: $id) {\n" + render(tree, 4) + "\n  }\n}"
        resp = post(auth, query, {"id": model_id})
        errors = resp.get("errors") or []
        if not errors:
            return (resp.get("data") or {}).get("model")
        removed_any = False
        for err in errors:
            path = [p for p in (err.get("path") or []) if isinstance(p, str)]
            # path starts with "model"; the tree is rooted inside model
            parts = path[1:] if path[:1] == ["model"] else path
            code = (err.get("extensions") or {}).get("code", "")
            msg = err.get("message", "")
            if parts and remove_path(tree, parts):
                removed_any = True
                skipped.append({"section": section, "field": "model." + ".".join(parts),
                                "reason": f"API error {code}: {msg}".strip()})
        if not removed_any:
            msgs = "; ".join(e.get("message", "") for e in errors)
            skipped.append({"section": section, "field": "(whole section)",
                            "reason": f"API error: {msgs}"})
            return None
    skipped.append({"section": section, "field": "(whole section)",
                    "reason": "too many failing fields"})
    return None


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 scripts/fetch_model.py <modelId>")
    model_id = sys.argv[1]
    auth = load_env()

    log("Introspecting schema...")
    schema = Schema(post(auth, INTROSPECTION))

    skipped = []
    sections = {}
    for name, spec in SECTIONS.items():
        log(f"Fetching {name}...")
        data = fetch_section(auth, schema, model_id, name, spec, skipped)
        if data:
            sections[name] = data

    out = {
        "modelId": model_id,
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
        "source": ENDPOINT,
        "units": "metric",
        "sections": sections,
        "skipped": skipped,
    }
    out_path = REPO_ROOT / "data" / f"{model_id}.json"
    out_path.write_text(json.dumps(out, indent=2))

    log("")
    log(f"Wrote {out_path.relative_to(REPO_ROOT)}")
    log("Sections returned: " + (", ".join(sections) or "none"))
    missing = [s for s in SECTIONS if s not in sections]
    if missing:
        log("Sections missing: " + ", ".join(missing))
    if skipped:
        log(f"Skipped {len(skipped)} field(s):")
        for s in skipped:
            log(f"  [{s['section']}] {s['field']}: {s['reason']}")


if __name__ == "__main__":
    main()
