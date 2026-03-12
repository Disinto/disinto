## Vision

The factory supervisor manages compute and memory resources for the entire factory. It should be able to make autonomous decisions about production capacity, self-tune its monitoring, and scale across repositories and machines.

## Feature Requests

### 1. Production Halt / Resume
The supervisor should be able to **stop the factory** when resources are insufficient:
- Disable dev-agent cron (or write a halt file that dev-poll.sh checks)
- Disable review-agent cron when CI is overloaded
- Resume automatically when resources recover
- Graduated response: halt dev first (heaviest), then review, keep supervisor running last

### 2. Self-Tuning Wake Parameters
The supervisor should adjust its own schedule based on conditions:
- Increase frequency during active development (PRs open, CI running)
- Decrease frequency during quiet periods (no backlog, no open PRs)
- Set alarms for specific events (e.g., "wake me when pipeline #940 finishes")
- Modify its own crontab entry or use a dynamic sleep loop instead of fixed cron

### 3. Multi-Repository Support
Extend the factory to work across multiple Codeberg repos:
- Configuration file listing repos, their labels, branch protection rules
- Per-repo `.env` or config section (different tokens, different CI)
- Shared best-practices with repo-specific overrides
- Single supervisor managing dev/review agents across repos

### 4. Multi-VPS / Distributed Factory
Scale the factory across multiple machines:
- Supervisor on primary VPS, agents on secondary VPS(es)
- SSH-based remote execution or message queue between nodes
- Resource-aware scheduling: route heavy builds to beefier machines
- Centralized logging / alerting across all nodes
- Failover: if primary supervisor goes down, secondary picks up

## Design Principles
- Supervisor is always the last thing to shut down
- Halt is reversible and automatic when conditions improve
- No human intervention needed for routine scaling decisions
- Progressive enhancement: each feature builds on the previous
