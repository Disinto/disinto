# Evaluation: MCP server wrapper for factory tools

**Issue**: #713
**Date**: 2026-03-26
**Status**: Not recommended at this time

## Question

Should disinto expose factory tools as an MCP (Model Context Protocol) server,
in addition to the existing SKILL.md skill?

## Current state

The SKILL.md skill (v0.2.0) already exposes factory operations to MCP-compatible
clients via three bash scripts:

| Script | Capability | MCP tool equivalent |
|--------|-----------|-------------------|
| `skill/scripts/factory-status.sh` | Agent health, open issues, CI pipelines | `factory_status`, `list_issues`, `ci_status` |
| `skill/scripts/file-issue.sh` | Create issues with labels | `file_issue` |
| `skill/scripts/read-journal.sh` | Read planner/supervisor journals | `read_journal` |

The dependency graph analysis (`lib/build-graph.py`) is available but runs
locally — not exposed through the skill scripts.

## Analysis

### What an MCP server would add

An MCP server would provide typed JSON-RPC tool definitions with schemas for
each parameter, structured error responses, and transport-level features
(SSE streaming, session management). Clients could discover tools
programmatically instead of parsing SKILL.md instructions.

### What it would cost

1. **New language dependency.** The entire factory is bash. An MCP server
   requires TypeScript (`@modelcontextprotocol/sdk`) or Python
   (`mcp` package). This adds a build step, runtime dependency, and
   language that no current contributor or agent maintains.

2. **Persistent process.** The factory is cron-driven — no long-running
   daemons. An MCP server must stay up, be monitored, and be restarted on
   failure. This contradicts the factory's event-driven architecture (AD-004).

3. **Thin wrapper over existing APIs.** Every proposed MCP tool maps directly
   to a forge API call or a skill script invocation. The MCP server would be
   `curl` with extra steps:

   ```
   MCP client → MCP server (TypeScript) → forge API (HTTP) → Forgejo
   ```

   vs. the current path:

   ```
   SKILL.md instruction → bash script → forge API (HTTP) → Forgejo
   ```

4. **Maintenance surface.** MCP SDK versioning, transport configuration
   (stdio vs SSE), authentication handling, and registry listings all
   need ongoing upkeep — for a wrapper that adds no logic of its own.

### Overlap with SKILL.md

The SKILL.md skill already works with Claude Code, Claude Desktop, and any
client that supports the skill/tool-use protocol. The scripts it references
are the same scripts an MCP server would wrap. Adding MCP does not unlock
new capabilities — it provides an alternative invocation path.

### When MCP would make sense

- **Non-Claude MCP clients** need to operate the factory (VS Code Copilot,
  Cursor, custom agents using only MCP transport).
- **Type safety** becomes a real issue — structured schemas prevent
  misformed requests that natural language instructions currently handle.
- **The factory adopts a server model** — if a persistent API gateway is
  added for other reasons, exposing MCP tools becomes low marginal cost.
- **Graph queries** need remote access — `build-graph.py` is the one tool
  that doesn't have a simple curl equivalent and could benefit from
  structured input/output schemas.

## Recommendation

**Do not build an MCP server now.** The SKILL.md skill already covers the
primary use case (human-assisted factory operation via Claude). The six
proposed MCP tools map 1:1 to existing scripts and API calls, so the
server would be pure glue code in a language the factory doesn't use.

**Revisit when** any of these conditions are met:

1. A concrete use case requires MCP transport (e.g., a VS Code extension
   that operates the factory and cannot use SKILL.md).
2. The factory adds a persistent API gateway (forge proxy, webhook
   receiver) that could host MCP endpoints at near-zero marginal cost.
3. Graph analysis (`build-graph.py`) is needed by external clients —
   this is the strongest candidate for a standalone MCP tool since it
   has complex input/output that benefits from typed schemas.

**If revisiting**, scope to a minimal stdio-transport server wrapping only
`factory_status` and `query_graph`. Do not duplicate what the skill
scripts already provide unless there is demonstrated client demand.
