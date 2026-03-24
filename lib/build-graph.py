#!/usr/bin/env python3
"""build-graph.py — Build a project knowledge graph for structural defect detection.

Parses VISION.md, prerequisite-tree.md, AGENTS.md, formulas/*.toml,
evidence/ tree, and forge issues/labels into a NetworkX DiGraph.
Runs structural analyses and outputs a JSON report.

Usage:
    python3 lib/build-graph.py [--project-root DIR] [--changed-files FILE...]

Environment:
    FORGE_API   — Forge API base URL (e.g. http://localhost:3000/api/v1/repos/johba/disinto)
    FORGE_TOKEN — API authentication token
    PROJECT_NAME — Project name for output file naming
"""
import argparse
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

import networkx as nx


def forge_get(path, token):
    """GET from the Forge API. Returns parsed JSON or empty list on failure."""
    api = os.environ.get("FORGE_API", "")
    if not api or not token:
        return []
    url = f"{api}{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return []


def forge_get_all(path, token):
    """Paginate a Forge API GET endpoint."""
    sep = "&" if "?" in path else "?"
    page = 1
    items = []
    while True:
        page_items = forge_get(f"{path}{sep}limit=50&page={page}", token)
        if not page_items:
            break
        items.extend(page_items)
        if len(page_items) < 50:
            break
        page += 1
    return items


# ---------------------------------------------------------------------------
# Parsers — each adds nodes and edges to the graph
# ---------------------------------------------------------------------------

def parse_vision(G, root):
    """Parse VISION.md for milestone headings and objectives."""
    path = os.path.join(root, "VISION.md")
    if not os.path.isfile(path):
        return
    with open(path) as f:
        text = f.read()

    # Add doc-section nodes for headings
    current_section = None
    for line in text.splitlines():
        m = re.match(r'^(#{1,3})\s+(.+)', line)
        if m:
            heading = m.group(2).strip()
            node_id = f"doc:VISION/{_slug(heading)}"
            G.add_node(node_id, type="doc-section", label=heading, source="VISION.md")
            current_section = node_id

        # Track issue references in vision text
        if current_section:
            for ref in re.findall(r'#(\d+)', line):
                G.add_edge(f"issue:{ref}", current_section, relation="references")


def parse_prerequisite_tree(G, root):
    """Parse prerequisite-tree.md for objectives, prerequisites, and status."""
    path = os.path.join(root, "planner", "prerequisite-tree.md")
    if not os.path.isfile(path):
        return
    with open(path) as f:
        text = f.read()

    current_obj = None
    for line in text.splitlines():
        # Objective headings: ## Objective: Name (#NNN)
        m = re.match(r'^##\s+Objective:\s+(.+?)(?:\s+\(#(\d+)\))?\s*$', line)
        if m:
            name = m.group(1).strip()
            issue_num = m.group(2)
            obj_id = f"objective:{_slug(name)}"
            G.add_node(obj_id, type="objective", label=name, source="prerequisite-tree.md")
            current_obj = obj_id
            if issue_num:
                iss_id = f"issue:{issue_num}"
                G.add_edge(iss_id, obj_id, relation="implements")
            continue

        # Prerequisite items: - [x] or - [ ] text (#NNN)
        m = re.match(r'^-\s+\[([ x])\]\s+(.+)', line)
        if m and current_obj:
            done = m.group(1) == "x"
            prereq_text = m.group(2).strip()
            prereq_id = f"prereq:{_slug(prereq_text)}"
            G.add_node(prereq_id, type="prerequisite", label=prereq_text,
                        done=done, source="prerequisite-tree.md")
            G.add_edge(prereq_id, current_obj, relation="blocks")
            # Link referenced issues
            for ref in re.findall(r'#(\d+)', prereq_text):
                G.add_edge(f"issue:{ref}", prereq_id, relation="implements")
            continue

        # Status lines
        m = re.match(r'^Status:\s+(\S+)', line)
        if m and current_obj:
            status = m.group(1)
            G.nodes[current_obj]["status"] = status


def parse_agents_md(G, root):
    """Parse AGENTS.md files for agent definitions."""
    # Root AGENTS.md
    agents_files = [os.path.join(root, "AGENTS.md")]
    # Per-agent AGENTS.md files
    for entry in os.listdir(root):
        candidate = os.path.join(root, entry, "AGENTS.md")
        if os.path.isfile(candidate):
            agents_files.append(candidate)

    for path in agents_files:
        if not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, root)
        with open(path) as f:
            text = f.read()

        for line in text.splitlines():
            m = re.match(r'^#{1,3}\s+(.+)', line)
            if m:
                heading = m.group(1).strip()
                doc_id = f"doc:{rel.replace('.md', '')}/{_slug(heading)}"
                G.add_node(doc_id, type="doc-section", label=heading, source=rel)

                # Detect agent names from headings or directory names
                agent_name = _extract_agent_name(heading, rel)
                if agent_name:
                    agent_id = f"agent:{agent_name}"
                    G.add_node(agent_id, type="agent", label=agent_name, source=rel)
                    G.add_edge(doc_id, agent_id, relation="defines")


def _extract_agent_name(heading, rel_path):
    """Try to extract an agent name from a heading or file path."""
    known_agents = [
        "dev", "review", "gardener", "predictor", "planner",
        "supervisor", "action", "vault",
    ]
    heading_lower = heading.lower()
    for agent in known_agents:
        if agent in heading_lower:
            return agent
    # From directory path: predictor/AGENTS.md -> predictor
    parts = rel_path.split("/")
    if len(parts) >= 2 and parts[0] in known_agents:
        return parts[0]
    return None


def parse_formulas(G, root):
    """Parse formulas/*.toml for formula nodes."""
    formula_dir = os.path.join(root, "formulas")
    if not os.path.isdir(formula_dir):
        return
    for path in sorted(glob.glob(os.path.join(formula_dir, "*.toml"))):
        with open(path) as f:
            text = f.read()
        # Extract name field
        m = re.search(r'^name\s*=\s*"([^"]+)"', text, re.MULTILINE)
        if m:
            name = m.group(1)
        else:
            name = os.path.basename(path).replace(".toml", "")
        formula_id = f"formula:{name}"
        G.add_node(formula_id, type="formula", label=name,
                    source=os.path.relpath(path, root))

        # Link agent<->formula by naming convention
        # e.g. run-predictor -> predictor, review-pr -> review
        for agent in ["dev", "review", "gardener", "predictor", "planner",
                       "supervisor", "action", "vault"]:
            if agent in name:
                agent_id = f"agent:{agent}"
                if G.has_node(agent_id):
                    G.add_edge(agent_id, formula_id, relation="executes")

        # Scan for label references in the formula text
        for label_ref in re.findall(r'prediction/\w+|backlog|action|in-progress', text):
            label_id = f"label:{label_ref}"
            G.add_edge(formula_id, label_id, relation="produces")


def parse_evidence(G, root):
    """Parse evidence/ tree for evidence files."""
    evidence_root = os.path.join(root, "evidence")
    if not os.path.isdir(evidence_root):
        return
    for dirpath, _, filenames in os.walk(evidence_root):
        for fname in filenames:
            if not fname.endswith(".json"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fname), evidence_root)
            # e.g. red-team/2026-03-20-1.json -> evidence:red-team/2026-03-20-1
            eid = f"evidence:{rel.replace('.json', '')}"
            category = rel.split("/")[0] if "/" in rel else "uncategorized"
            G.add_node(eid, type="evidence", label=rel, source=f"evidence/{rel}",
                        category=category)

            # Try to read the JSON and find prerequisite references
            try:
                full_path = os.path.join(dirpath, fname)
                with open(full_path) as f:
                    data = json.load(f)
                body = json.dumps(data)
                # Link to prerequisites via text matching
                for prereq_node in [n for n, d in G.nodes(data=True)
                                     if d.get("type") == "prerequisite"]:
                    prereq_label = G.nodes[prereq_node].get("label", "")
                    if _slug(prereq_label) in body.lower():
                        G.add_edge(eid, prereq_node, relation="evidences")
            except (json.JSONDecodeError, OSError):
                pass


def parse_forge_issues(G, token):
    """Fetch issues from the Forge API and add nodes/edges."""
    issues = forge_get_all("/issues?state=open&type=issues", token)
    issues += forge_get_all("/issues?state=closed&type=issues&sort=updated"
                            "&direction=desc&limit=50", token)
    seen = set()
    for issue in issues:
        num = issue.get("number")
        if not num or num in seen:
            continue
        seen.add(num)
        iss_id = f"issue:{num}"
        G.add_node(iss_id, type="issue", label=issue.get("title", ""),
                    state=issue.get("state", ""))

        # Label edges
        for label in issue.get("labels", []):
            lname = label.get("name", "")
            if lname:
                label_id = f"label:{lname}"
                G.add_edge(iss_id, label_id, relation="uses-label")

        # Parse body for issue references (#NNN) and blocking relationships
        body = issue.get("body") or ""
        for ref in re.findall(r'#(\d+)', body):
            if int(ref) != num:
                G.add_edge(iss_id, f"issue:{ref}", relation="references")

        # Detect blocking via "blocks #NNN" or "blocked by #NNN" patterns
        for ref in re.findall(r'blocks?\s+#(\d+)', body, re.IGNORECASE):
            if int(ref) != num:
                G.add_edge(iss_id, f"issue:{ref}", relation="blocks")
        for ref in re.findall(r'blocked\s+by\s+#(\d+)', body, re.IGNORECASE):
            if int(ref) != num:
                G.add_edge(f"issue:{ref}", iss_id, relation="blocks")

        # Link to objectives if the issue title/body mentions an objective
        for obj_node in [n for n, d in G.nodes(data=True)
                         if d.get("type") == "objective"]:
            obj_label = G.nodes[obj_node].get("label", "")
            if obj_label and _slug(obj_label) in _slug(body + " " + issue.get("title", "")):
                G.add_edge(iss_id, obj_node, relation="implements")


def parse_forge_labels(G, token):
    """Fetch labels from the Forge API and ensure label nodes exist."""
    labels = forge_get("/labels", token)
    for label in labels:
        name = label.get("name", "")
        if name:
            label_id = f"label:{name}"
            if not G.has_node(label_id):
                G.add_node(label_id, type="label", label=name, source="forge")


# ---------------------------------------------------------------------------
# Structural analyses
# ---------------------------------------------------------------------------

def find_orphans(G):
    """Find orphaned nodes: labels, formulas, evidence with no connections."""
    orphans = []
    for node in nx.isolates(G):
        data = G.nodes[node]
        ntype = data.get("type", "unknown")
        reasons = {
            "label": "no issue uses this label",
            "formula": "no agent executes this formula",
            "evidence": "not linked to any prerequisite",
            "issue": "not connected to any objective or other issue",
        }
        if ntype in reasons:
            orphans.append({
                "id": node,
                "type": ntype,
                "reason": reasons[ntype],
            })
    return orphans


def find_cycles(G):
    """Find circular blocking chains."""
    cycles = []
    try:
        # Only look at "blocks" edges
        blocks_edges = [(u, v) for u, v, d in G.edges(data=True)
                        if d.get("relation") == "blocks"]
        if blocks_edges:
            blocks_graph = G.edge_subgraph(blocks_edges).copy()
            for cycle in nx.simple_cycles(blocks_graph):
                if len(cycle) >= 2:
                    cycles.append({
                        "chain": cycle,
                        "relation": "blocks",
                    })
    except nx.NetworkXError:
        pass
    return cycles


def find_disconnected(G):
    """Find clusters not connected to any vision objective."""
    clusters = []
    obj_nodes = {n for n, d in G.nodes(data=True) if d.get("type") == "objective"}
    if not obj_nodes:
        return clusters

    undirected = G.to_undirected()
    for component in nx.connected_components(undirected):
        if not component & obj_nodes:
            # Filter to interesting node types
            interesting = [n for n in component
                           if G.nodes[n].get("type") in ("issue", "formula", "evidence")]
            if interesting:
                clusters.append({
                    "cluster": interesting[:10],
                    "reason": "no path to any objective",
                })
    return clusters


def find_thin_objectives(G):
    """Find objectives with weak evidence coverage."""
    thin = []
    for node, data in G.nodes(data=True):
        if data.get("type") != "objective":
            continue

        # Count evidence reachable via ancestors
        ancestors = set()
        try:
            ancestors = nx.ancestors(G, node)
        except nx.NetworkXError:
            pass
        evidence_count = sum(1 for a in ancestors
                             if G.nodes.get(a, {}).get("type") == "evidence")
        issue_count = sum(1 for a in ancestors
                          if G.nodes.get(a, {}).get("type") == "issue")

        status = data.get("status", "UNKNOWN")
        # Flag objectives that are DONE/READY with little evidence
        if evidence_count < 2 or (status in ("DONE", "READY") and issue_count < 2):
            thin.append({
                "id": node,
                "status": status,
                "evidence_count": evidence_count,
                "issue_count": issue_count,
            })
    return thin


def find_bottlenecks(G):
    """Find structural bottlenecks via betweenness centrality."""
    if G.number_of_nodes() < 3:
        return []
    try:
        centrality = nx.betweenness_centrality(G)
    except nx.NetworkXError:
        return []

    # Only report nodes with meaningful centrality
    bottlenecks = []
    for node, score in sorted(centrality.items(), key=lambda x: -x[1]):
        if score < 0.05:
            break
        dependents = len(list(G.predecessors(node)))
        bottlenecks.append({
            "id": node,
            "centrality": round(score, 4),
            "dependents": dependents,
        })
        if len(bottlenecks) >= 10:
            break
    return bottlenecks


def filter_for_changed_files(report, G, changed_files, root):
    """Add affected-objectives context for changed files (reviewer mode)."""
    if not changed_files:
        return report

    affected_objectives = set()
    affected_prereqs = set()
    alerts = []

    for fpath in changed_files:
        # Check if the file relates to a formula
        if fpath.startswith("formulas/"):
            fname = os.path.basename(fpath).replace(".toml", "")
            for node in G.nodes():
                if node.startswith("formula:") and fname in node:
                    # Trace to objectives
                    try:
                        for desc in nx.descendants(G, node):
                            if G.nodes.get(desc, {}).get("type") == "objective":
                                affected_objectives.add(desc)
                    except nx.NetworkXError:
                        pass

        # Check if file is in an agent directory
        for agent in ["dev", "review", "gardener", "predictor", "planner",
                       "supervisor", "action", "vault"]:
            if fpath.startswith(f"{agent}/"):
                agent_id = f"agent:{agent}"
                if G.has_node(agent_id):
                    try:
                        for desc in nx.descendants(G, agent_id):
                            if G.nodes.get(desc, {}).get("type") == "objective":
                                affected_objectives.add(desc)
                    except nx.NetworkXError:
                        pass

        # Check if file is evidence
        if fpath.startswith("evidence/"):
            for node in G.nodes():
                if node.startswith("evidence:") and _slug(fpath) in _slug(node):
                    try:
                        for desc in nx.descendants(G, node):
                            if G.nodes.get(desc, {}).get("type") == "prerequisite":
                                affected_prereqs.add(desc)
                    except nx.NetworkXError:
                        pass

    # Check for DONE prerequisites affected by changes
    for prereq in affected_prereqs:
        data = G.nodes.get(prereq, {})
        if data.get("done"):
            alerts.append({
                "prereq": prereq,
                "label": data.get("label", ""),
                "alert": "PR modifies file tracing to a DONE prerequisite",
            })

    report["affected_objectives"] = sorted(affected_objectives)
    report["affected_prerequisites"] = sorted(affected_prereqs)
    report["alerts"] = alerts
    return report


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _slug(text):
    """Convert text to a URL-friendly slug."""
    text = text.lower().strip()
    text = re.sub(r'[^a-z0-9\s-]', '', text)
    text = re.sub(r'[\s]+', '-', text)
    text = re.sub(r'-+', '-', text)
    return text.strip('-')


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Build project knowledge graph")
    parser.add_argument("--project-root", default=os.environ.get("PROJECT_REPO_ROOT", "."),
                        help="Root directory of the project repo")
    parser.add_argument("--changed-files", nargs="*", default=None,
                        help="Changed files (reviewer mode)")
    parser.add_argument("--output", default=None,
                        help="Output file path (default: /tmp/{project}-graph-report.json)")
    args = parser.parse_args()

    root = os.path.abspath(args.project_root)
    token = os.environ.get("FORGE_TOKEN", "")
    project_name = os.environ.get("PROJECT_NAME", os.path.basename(root))

    G = nx.DiGraph()

    # Build graph from local sources
    parse_vision(G, root)
    parse_prerequisite_tree(G, root)
    parse_agents_md(G, root)
    parse_formulas(G, root)
    parse_evidence(G, root)

    # Build graph from Forge API (gracefully skipped if unavailable)
    parse_forge_labels(G, token)
    parse_forge_issues(G, token)

    # Run structural analyses
    report = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stats": {"nodes": G.number_of_nodes(), "edges": G.number_of_edges()},
        "orphans": find_orphans(G),
        "cycles": find_cycles(G),
        "disconnected": find_disconnected(G),
        "thin_objectives": find_thin_objectives(G),
        "bottlenecks": find_bottlenecks(G),
    }

    # Reviewer mode: filter for changed files
    if args.changed_files is not None:
        report = filter_for_changed_files(report, G, args.changed_files, root)

    # Write output
    output_path = args.output or f"/tmp/{project_name}-graph-report.json"
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)

    print(f"Graph report: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges "
          f"-> {output_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
