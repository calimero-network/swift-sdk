#!/usr/bin/env python3
"""Rewrite core's OpenAPI document into the dialect swift-openapi-generator reads.

Usage: scripts/openapi-normalize.py IN.json OUT.json

openapi/openapi.json stays byte for byte what core publishes; the generator
(1.10.3) reads this script's output instead. Each rewrite keeps the
document's meaning:

1. A nullable reference, `anyOf: [{$ref}, {type: null}]`, becomes the
   reference, and leaves its object's `required` list. The generator skips
   the `null` branch and would wrap the reference in a one-field struct; an
   optional property of the referenced type is what the schema says.
   (Core spells every other nullable `type: [T, "null"]`, which needs nothing.)
2. `contentEncoding: base64url` is dropped: core keeps it on purpose (the
   value travels as base64url text), but OpenAPIKit knows only RFC 2045's
   encodings and refuses the document. The value stays a string.
3. Every non-2xx response is dropped. MeroKit's transport throws a refusal as
   its own typed error (`errorFrom`) before the generated client reads it, so
   the per-status types would never be reached. The document keeps them.
"""
import json
import sys


def nullable_ref(schema):
    """The `$ref` of `anyOf: [{$ref}, {type: null}]`, else None."""
    if not isinstance(schema, dict):
        return None
    branches = schema.get("anyOf")
    if isinstance(branches, list) and len(branches) == 2 and {"type": "null"} in branches:
        other = next(b for b in branches if b != {"type": "null"})
        if set(other) == {"$ref"}:
            return other
    return None


def normalize(node):
    if isinstance(node, dict):
        if node.get("contentEncoding") == "base64url":
            del node["contentEncoding"]
        properties = node.get("properties")
        if isinstance(properties, dict):
            for name, schema in properties.items():
                ref = nullable_ref(schema)
                if ref is not None:
                    properties[name] = dict(ref)
                    if name in node.get("required", []):
                        node["required"] = [r for r in node["required"] if r != name]
        for value in node.values():
            normalize(value)
    elif isinstance(node, list):
        for value in node:
            normalize(value)


def drop_refusals(document):
    for item in document.get("paths", {}).values():
        for operation in item.values():
            if isinstance(operation, dict) and "responses" in operation:
                operation["responses"] = {
                    status: answer for status, answer in operation["responses"].items() if status.startswith("2")
                }


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        document = json.load(f)
    normalize(document)
    drop_refusals(document)
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(document, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
