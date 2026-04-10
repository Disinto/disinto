# Forgejo Operations — Best Practices

## Forgejo Issues

When Forgejo operations encounter issues:

### API Rate Limits
- Monitor rate limit headers in API responses
- Implement exponential backoff on 429 responses
- Use agent-specific tokens (#747) to increase limits

### Authentication Issues
- Verify FORGE_TOKEN is valid and not expired
- Check agent identity matches token (#747)
- Use FORGE_<AGENT>_TOKEN for agent-specific identities

### Repository Access
- Verify FORGE_REMOTE matches actual git remote
- Check token has appropriate permissions (repo, write)
- Use `resolve_forge_remote()` to auto-detect remote

### Prevention
- Set up monitoring for API failures
- Rotate tokens before expiry
- Document required permissions per agent
