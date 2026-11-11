#!/usr/bin/env python3
"""The facade methods one regeneration added, removed or changed, as Markdown.

    python3 scripts/facade-diff.py <Facade.swift before> <Facade.swift after>

Reads the facade scripts/generate-facade.py writes (one `public nonisolated var`
per group, one `public func` per operation), keyed by `group.method`. Prints a
section for the openapi-sync pull request body. The exit code is 0 when nothing
a caller compiles against was removed or changed, and 3 when a method was
removed or its signature changed (a major version), which core's
sdk-openapi-sync.yml reads as breaking.
"""

import re
import sys


def methods(path):
    """`group.name` -> the method's declaration, one line."""
    out, group = {}, None
    try:
        lines = open(path, encoding="utf-8").readlines()
    except FileNotFoundError:
        return out
    for line in lines:
        m = re.match(r"    public nonisolated var (\w+):", line)
        if m:
            group = m.group(1)
        m = re.match(r"        public func (`?\w+`?)\((.*)\) async throws(.*?) \{$", line)
        if m and group:
            out[f"{group}.{m.group(1)}"] = f"{group}.{m.group(1)}({m.group(2)}){m.group(3)}".rstrip()
    return out


def block(title, keys, show):
    print(f"**{title}** ({len(keys)})")
    print()
    if not keys:
        print("None.")
    for k in keys:
        print(f"- `{show(k)}`")
    print()


def main(before_path, after_path):
    before, after = methods(before_path), methods(after_path)
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(k for k in set(before) & set(after) if before[k] != after[k])

    block("Added", added, lambda k: after[k])
    block("Removed", removed, lambda k: before[k])
    print(f"**Signature changed** ({len(changed)})")
    print()
    if not changed:
        print("None.")
    for k in changed:
        print(f"- `{k}`")
        print(f"  - before: `{before[k]}`")
        print(f"  - after: `{after[k]}`")
    print()
    if removed or changed:
        print("> A removed or renamed facade method, or a changed signature, breaks callers: "
              "release this with a **major** version bump.")
        return 3
    print("> No facade method was removed or changed: a minor (or patch) release.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
