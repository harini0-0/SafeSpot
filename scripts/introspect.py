#!/usr/bin/env python3
"""Read-only GraphQL introspection of the Matterport Model API.

Lists every field on the Model type and reports whether fields exist for the
capabilities Safe Spot cares about (objects/detections/furniture, mattertags,
measurements, labels, roof, and asset downloads). It does NOT write any file and
does NOT touch data/. Nothing is invented: every name printed comes straight
from the live schema.

Usage:
    scripts/.venv/bin/python scripts/introspect.py

Auth: HTTP Basic, MATTERPORT_API_KEY (token id) + MATTERPORT_API_TOKEN (secret),
read from .env in the repo root.
"""
import os
import sys
from pathlib import Path

import requests
from dotenv import dotenv_values

ENDPOINT = "https://api.matterport.com/api/models/graph"
REPO_ROOT = Path(__file__).resolve().parent.parent

TYPE_REF = "kind name ofType { kind name ofType { kind name ofType { kind name } } }"
INTROSPECTION = f"""
query {{
  __schema {{
    types {{
      kind name
      fields(includeDeprecated: true) {{
        name description isDeprecated
        type {{ {TYPE_REF} }}
      }}
    }}
  }}
}}"""

# capability -> substrings to look for in field names (lowercase)
CAPABILITIES = {
    "objects / detections / furniture": ["object", "detection", "furnitur", "item"],
    "mattertags": ["mattertag", "tag"],
    "measurements": ["measurement", "measure"],
    "labels": ["label"],
    "roof": ["roof"],
    "asset download (mesh)": ["mesh"],
    "asset download (textures)": ["texture"],
    "asset download (skybox)": ["skybox", "pano"],
    "asset download (floorplan)": ["floorplan", "floor plan"],
}


def load_auth():
    env = {**dotenv_values(REPO_ROOT / ".env"), **os.environ}
    key, tok = env.get("MATTERPORT_API_KEY"), env.get("MATTERPORT_API_TOKEN")
    if not key or not tok:
        sys.exit("Missing MATTERPORT_API_KEY / MATTERPORT_API_TOKEN in .env or environment")
    return (key, tok)


def unwrap(t):
    """Render a GraphQL type ref like [Foo!]! as a readable string."""
    if t is None:
        return "?"
    k, n = t.get("kind"), t.get("name")
    if k == "NON_NULL":
        return unwrap(t.get("ofType")) + "!"
    if k == "LIST":
        return "[" + unwrap(t.get("ofType")) + "]"
    return n or k


def main():
    auth = load_auth()
    r = requests.post(ENDPOINT, json={"query": INTROSPECTION}, auth=auth,
                      headers={"Content-Type": "application/json"}, timeout=120)
    if r.status_code == 401:
        sys.exit("401 Unauthorized: check credentials in .env")
    r.raise_for_status()
    data = r.json()
    if data.get("errors"):
        sys.exit("GraphQL errors: " + str(data["errors"]))

    types = {t["name"]: t for t in data["data"]["__schema"]["types"] if t.get("name")}
    model = types.get("Model")
    if not model:
        sys.exit("No 'Model' type found in schema")

    model_fields = model.get("fields") or []
    print("=" * 70)
    print(f"Model type: {len(model_fields)} fields")
    print("=" * 70)
    for f in sorted(model_fields, key=lambda x: x["name"]):
        dep = "  [DEPRECATED]" if f["isDeprecated"] else ""
        print(f"  {f['name']}: {unwrap(f['type'])}{dep}")

    # Build a global index: typeName.fieldName for keyword scanning.
    all_fields = []  # (typeName, fieldName, typeStr)
    for tname, t in types.items():
        for f in (t.get("fields") or []):
            all_fields.append((tname, f["name"], unwrap(f["type"])))

    print("\n" + "=" * 70)
    print("Capability check (schema-wide field-name match)")
    print("=" * 70)
    for cap, subs in CAPABILITIES.items():
        hits = [(tn, fn, ts) for (tn, fn, ts) in all_fields
                if any(s in fn.lower() for s in subs)]
        if hits:
            print(f"\n[FOUND] {cap}:")
            for tn, fn, ts in sorted(hits):
                print(f"    {tn}.{fn}: {ts}")
        else:
            print(f"\n[NOT FOUND] {cap}: no field name matches {subs}")

    # Drill into likely asset/download types: any field named url/downloadUrl/urlTemplate
    print("\n" + "=" * 70)
    print("Download-bearing fields (url / downloadUrl / urlTemplate / children)")
    print("=" * 70)
    dl_subs = ["url", "download", "children"]
    dl = [(tn, fn, ts) for (tn, fn, ts) in all_fields
          if any(s in fn.lower() for s in dl_subs)]
    for tn, fn, ts in sorted(dl):
        print(f"    {tn}.{fn}: {ts}")


if __name__ == "__main__":
    main()
