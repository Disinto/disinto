#!/usr/bin/env python3
"""Extract dependency issue numbers from an issue body.

Usage:
    echo "$ISSUE_BODY" | python3 lib/parse-deps.py
    python3 lib/parse-deps.py "$ISSUE_BODY"
    python3 lib/parse-deps.py --json < issues.json

Modes:
    stdin/arg:  reads a single issue body, prints one dep number per line
    --json:     reads a JSON array of issues from stdin, prints JSON
                dep graph: {"issue_num": [dep1, dep2], ...}

Matches the same logic as dev-poll.sh get_deps():
  - Sections: ## Dependencies / ## Depends on / ## Blocked by
  - Inline: "depends on #NNN" / "blocked by #NNN" anywhere
  - Ignores: ## Related (safe for sibling cross-references)
"""
import json
import re
import sys


def parse_deps(body):
    """Return sorted list of unique dependency issue numbers from an issue body."""
    deps = set()
    in_section = False
    for line in (body or "").split("\n"):
        if re.match(r"^##?\s*(Depends on|Blocked by|Dependencies)", line, re.IGNORECASE):
            in_section = True
            continue
        if in_section and re.match(r"^##?\s", line):
            in_section = False
        if in_section:
            deps.update(int(m) for m in re.findall(r"#(\d+)", line))
        if re.search(r"(depends on|blocked by)", line, re.IGNORECASE):
            deps.update(int(m) for m in re.findall(r"#(\d+)", line))
    return sorted(deps)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        issues = json.load(sys.stdin)
        graph = {}
        for issue in issues:
            num = issue["number"]
            deps = parse_deps(issue.get("body", ""))
            deps = [d for d in deps if d != num]
            if deps:
                graph[num] = deps
        json.dump(graph, sys.stdout)
        print()
    else:
        if len(sys.argv) > 1:
            body = sys.argv[1]
        else:
            body = sys.stdin.read()
        for dep in parse_deps(body):
            print(dep)
