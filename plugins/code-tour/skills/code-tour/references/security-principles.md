# Security Principles

This organization follows the security principles defined in the mai-agents repository.

## Full Reference

**On GitHub:** [mai-agents/plugins/shared/security-principles.md](https://github.com/infinity-microsoft/mai-agents/blob/main/plugins/shared/security-principles.md)

## Quick Summary

All plugins and skills in this repository must follow these core principles:

1. **Least Privilege** - Request only permissions needed for the specific task
2. **Confirm Destructive Actions** - Always get explicit confirmation before irreversible operations
3. **Secret Hygiene** - Never echo, log, commit, or transmit secrets
4. **Scope Boundaries** - Stay within project directory unless explicitly authorized
5. **Network Caution** - Prefer approved endpoints; validate URLs before fetching
6. **Cognitive Bias Awareness** - "Obviously safe" is a warning sign, not a green light
7. **Defense in Depth** - Layer protections so one failure doesn't cause harm

## Applying to Skills

When creating skills in this repository, include a Security Boundaries section:

```yaml
---
name: my-skill
description: "..."
---

# My Skill

## Security Boundaries

This skill follows the [Security Principles](https://github.com/infinity-microsoft/mai-agents/blob/main/plugins/shared/security-principles.md).

**This skill:**
- **CAN**: [allowed operations]
- **CANNOT**: [prohibited operations]
- **MUST CONFIRM**: [operations requiring confirmation]
```

## Org-Specific Security Additions

1. All plugins must follow the dependency management strategy outlined in [dependencies.md].

## Reporting Security Issues

If you discover a security vulnerability:

1. **Do not** create a public issue
2. **Do** contact the maintainers directly
3. **Include**: Description, reproduction steps, potential impact
4. **Wait** for acknowledgment before disclosure

[dependencies.md]: ../../docs/dependencies.md
