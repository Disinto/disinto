# RESOURCES.md — Factory Capability Inventory

## harb-staging
- type: compute
- capability: run disinto agents, serve website, CI server
- agents: dev, review, action, gardener, supervisor, planner, predictor
- ram: 8GB
- note: disinto-only — no other project agents on this box

## codeberg-johba
- type: source-control
- capability: host repos, issue tracker, PR workflow, API access
- repos: johba/disinto
- note: owner account

## codeberg-disinto-bot
- type: source-control
- capability: review PRs, merge PRs, push branches
- repos: johba/disinto
- note: bot account, push+pull permissions, no admin

## woodpecker-ci
- type: ci
- capability: run pipelines on PR and push events, docker backend
- url: ci.niovi.voyage
- note: self-hosted on harb-staging

## disinto-ai
- type: asset
- capability: static site, landing page, dashboard
- domain: disinto.ai, www.disinto.ai
- note: served by Caddy on harb-staging

## matrix-bot
- type: communication
- capability: post factory status, receive human replies, escalation channel
- env: MATRIX_TOKEN
- note: used by supervisor and dev-agent for notifications

## telegram-clawy
- type: communication
- capability: notify human, collect decisions, relay vault requests
- note: OpenClaw bot, human's primary interface
