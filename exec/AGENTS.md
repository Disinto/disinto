<!-- last-reviewed: cebcb8c13ab7948fc794f49c379ed34570e45652 -->
# Executive Assistant Agent

**Role**: Interactive personal assistant for the executive (project founder).
Communicates via Matrix in a persistent conversational loop. Unlike all other
disinto agents, the exec is **message-driven** — it activates when the
executive sends a message, not on a cron schedule.

Think of it as the human-facing interface to the entire factory. The executive
talks to exec; exec talks to the factory. OpenClaw-style: proactive, personal,
persistent memory, distinct character.

**Trigger**: Matrix messages tagged `[exec]` or direct messages to the exec
bot. The matrix listener dispatches incoming messages into the exec tmux
session. If no session exists, `exec-session.sh` spawns one on demand.

A daily briefing can be scheduled via cron (optional):
```
0 7 * * *  /path/to/disinto/exec/exec-briefing.sh
```

**Key files**:
- `exec/exec-session.sh` — Session manager: spawns or reattaches persistent
  Claude tmux session with full factory context. Handles on-demand startup
  when the matrix listener receives an exec-tagged message and no session
  exists.
- `exec/exec-briefing.sh` — Optional cron wrapper for daily morning briefing.
  Spawns a session, injects the briefing prompt, posts summary to Matrix.
- `exec/CHARACTER.md` — Personality definition, tone, communication style.
  Read by Claude at session start. The exec has a distinct voice.
- `exec/PROMPT.md` — System prompt template with factory context injection
  points.
- `exec/MEMORY.md` — Persistent memory across conversations. Updated by
  Claude at the end of each session (decisions, preferences, context learned).
- `exec/journal/` — Raw conversation logs, one file per day.

**Capabilities** (what the exec can do for the executive):
- **Status briefing**: summarize agent activity, open issues, recent merges,
  health alerts, pending vault items
- **Issue triage**: discuss issues, help prioritize, answer "what should I
  focus on?"
- **Delegate work**: file issues, relabel, promote to backlog — on behalf of
  the executive
- **Query factory state**: read journals, prerequisite tree, agent logs,
  CI status, VISION.md progress
- **Research**: search the web, fetch pages, gather information
- **Memory**: remember decisions, preferences, project context across sessions

**What the exec does NOT do**:
- Write code or open PRs (that's the dev agent's job)
- Review PRs (that's the review agent's job)
- Make autonomous decisions about the codebase
- Approve vault items (the executive does that directly)

**Session lifecycle**:
1. Matrix message arrives tagged `[exec]` (or dispatched to exec)
2. Listener checks for active `exec-${PROJECT_NAME}` tmux session
3. If no session → spawn via `exec-session.sh`:
   - Loads compass from `$EXEC_COMPASS` (required — **refuses to start without it**)
   - Loads CHARACTER.md from repo (voice, relationships)
   - Loads MEMORY.md, factory state into prompt
4. Inject message into tmux session
5. Claude responds → response captured and posted back to Matrix thread
6. Session stays alive for `EXEC_SESSION_TTL` (default: 1h idle timeout)
7. On session end → Claude updates MEMORY.md, session logged to journal

**Compass separation**: The compass (identity, moral core) lives **outside the
repo** at a path specified by `EXEC_COMPASS` in `.env` or `.env.enc`. This is
intentional — the factory can modify CHARACTER.md (voice, relationships) via
PRs, but it cannot modify the compass. The executive controls the compass
directly, like a secret.

**Environment variables consumed**:
- `EXEC_COMPASS` — **Required.** Path to the compass file (identity, moral core). Lives outside the repo. Agent refuses to start without it.
- `FORGE_TOKEN`, `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Required (exec is Matrix-native)
- `EXEC_SESSION_TTL` — Idle timeout in seconds (default: 3600)
- `EXEC_CHARACTER` — Override character file path (default: exec/CHARACTER.md)
