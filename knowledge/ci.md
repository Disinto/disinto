# CI/CD — Best Practices

## CI Pipeline Issues (P2)

When CI pipelines are stuck running >20min or pending >30min:

### Investigation Steps
1. Check pipeline status via Forgejo API:
   ```bash
   curl -sf -H "Authorization: token $FORGE_TOKEN" \
     "$FORGE_API/pipelines?limit=50" | jq '.[] | {number, status, created}'
   ```

2. Check Woodpecker CI if configured:
   ```bash
   curl -sf -H "Authorization: Bearer $WOODPECKER_TOKEN" \
     "$WOODPECKER_SERVER/api/repos/${WOODPECKER_REPO_ID}/pipelines?limit=10"
   ```

### Common Fixes
- **Stuck pipeline**: Cancel via Forgejo API, retrigger
- **Pending pipeline**: Check queue depth, scale CI runners
- **Failed pipeline**: Review logs, fix failing test/step

### Prevention
- Set timeout limits on CI pipelines
- Monitor runner capacity and scale as needed
- Use caching for dependencies to reduce build time
