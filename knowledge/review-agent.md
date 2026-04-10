# Review Agent — Best Practices

## Review Agent Issues

When review agent encounters issues with PRs:

### Stale PR Handling
- PRs stale >20min (CI done, no push since) → file vault item for dev-agent
- Do NOT push branches or attempt merges directly
- File vault item with:
  - What: Stale PR requiring push
  - Why: Factory degraded
  - Unblocks: dev-agent will push the branch

### Circular Dependencies
- Check backlog for issues with circular `Depends on` refs
- Use `lib/parse-deps.sh` to analyze dependency graph
- Report to planner for resolution

### Prevention
- Review agent only reads PRs, never modifies
- Use vault items for actions requiring dev-agent
- Monitor for PRs stuck in review state
