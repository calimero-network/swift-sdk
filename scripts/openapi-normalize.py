#!/usr/bin/env python3
"""Rewrite core's OpenAPI document into the dialect swift-openapi-generator reads.

Usage: scripts/openapi-normalize.py IN.json OUT.json

openapi/openapi.json stays byte for byte what core publishes; the generator
reads this script's output instead. Each rewrite keeps the document's meaning:

1. `anyOf: [<primitive>, {type: null}]` -> `type: [<primitive>, "null"]`.
   The generator skips a `null` branch of an `anyOf` and with it the whole
   property (`App.org`, `Page.next`, `/auth/me`'s `app`, ...); the type-array
   spelling of the same schema becomes an optional property.
2. `contentEncoding: base64url` is dropped (OpenAPIKit knows only RFC 2045's
   encodings and refuses the document); the value stays a string.
3. Every non-2xx response is dropped. MeroKit's transport throws a refusal as
   its own typed error (`errorFrom`) before the generated client reads it, so
   the per-status error types would never be reached; they were two thirds of
   the generated code. The document keeps them, for reference.
"""
import json
import sys


def normalize(node):
    if isinstance(node, dict):
        if node.get("contentEncoding") == "base64url":
            del node["contentEncoding"]
        for key in ("anyOf", "oneOf"):
            branches = node.get(key)
            if isinstance(branches, list) and len(branches) == 2 and {"type": "null"} in branches:
                other = next(b for b in branches if b != {"type": "null"})
                if isinstance(other.get("type"), str) and "$ref" not in other:
                    del node[key]
                    node.update(other)
                    node["type"] = [other["type"], "null"]
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
