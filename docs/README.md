# Claude Code Auxiliary Documentation

This directory contains supplementary documentation for the global CLAUDE.md configuration.

## File Structure

### CLAUDE.md (Main Configuration)

Location: `~/.claude/CLAUDE.md` (621 lines)

**Contains:**

- 🔴 All 6 Mandatory Protocols (0-5)
- 📋 All Verification Checklists (Pre-Commit, Pre-Push, Completion)
- Commit Message Format
- Agent Reference (when to use, naming conventions, security patterns)
- Testing Standards
- Code Review Standards
- Technical Standards (Architecture, Error Handling, Shell Scripts)
- Git Workflow
- Safety Boundaries
- Project Integration
- Global Infrastructure
- Conditional guidance to auxiliary docs

**Read when:** Starting any session, committing code, completing tasks, or during active development (hot path).

### PHILOSOPHY.md (Decision Frameworks)

Location: `~/.claude/docs/PHILOSOPHY.md` (140 lines)

**Contains:**

- Directive Hierarchy (Red/Yellow/Green compliance levels)
- Interpretation Rules
- Self-Checking Requirements
- Core Beliefs (Incremental progress, learning before implementing)
- Epistemic Discipline (Predictions pay rent, notice confusion)
- Simplicity principles
- Know the reason before you change it
- Application guidelines (when and how to apply philosophy)

**Read when:**

- At project start to understand decision frameworks
- When facing architectural choices or design decisions
- When unclear about directive compliance levels
- When onboarding to understand the overall approach
- When you need to understand "why" behind the protocols

### REFERENCE.md (Commands & Templates)

Location: `~/.claude/docs/REFERENCE.md` (175 lines)

**Contains:**

- CI/CD Monitoring Commands (gh run, gh pr workflows)
- Repository Initialization (creating project-specific CLAUDE.md)
- Communication preferences (addressing, style, output format)
- Important Reminders (NEVER/ALWAYS lists, common mistakes)

**Read when:**

- When setting up new repositories
- When needing git/gh command references
- When troubleshooting CI/CD issues
- For communication preferences and style guidelines

### CUSTOM_AGENTS.md (Pre-existing)

Location: `~/.claude/docs/CUSTOM_AGENTS.md`

**Contains:**

- Custom agent development guide
- Agent creation procedures
- Integration patterns

**Read when:**

- Creating or modifying agents
- Extending the agent system

## Philosophy

The main CLAUDE.md contains "hot path" protocols and standards used in 90%+ of sessions. Auxiliary files contain:

1. **Cold path content** - Accessed <10% of sessions
2. **Reference material** - Used for lookups and commands
3. **Meta-documentation** - Philosophy and decision frameworks

This organization ensures:

- Fast access to frequently-used protocols
- Comprehensive documentation without cognitive overload
- Minimal fragmentation (90%+ operations stay in core file)
- Scalable structure for future additions

## Maintenance

### When Adding New Content

- **Protocols and checklists** → `CLAUDE.md` (hot path)
- **Philosophical guidance or decision frameworks** → `PHILOSOPHY.md` (cold path)
- **Commands, templates, or reference material** → `REFERENCE.md` (cold path)
- **Agent creation procedures** → `CUSTOM_AGENTS.md` (existing)

### When Updating Content

- **Protocol changes**: Update `CLAUDE.md` and test hot path workflows
- **Philosophy updates**: Update `PHILOSOPHY.md` and verify decision frameworks remain clear
- **Reference updates**: Update `REFERENCE.md` and verify commands/templates are current
- **Cross-file changes**: Update all affected files and validate cross-references

### Validation After Changes

1. Verify all protocols present (0-5)
2. Test hot path workflows (session start, commit, completion)
3. Check markdown anchor links work
4. Validate conditional guidance references correct files
5. Ensure no information loss

## File Size Summary

| File | Lines | Purpose |
|------|-------|---------|
| CLAUDE.md | 621 | Hot path protocols, standards, checklists |
| PHILOSOPHY.md | 140 | Decision frameworks, core beliefs |
| REFERENCE.md | 175 | Commands, templates, reminders |
| **Total** | **936** | **Complete documentation set** |

## Optimization History

### 2026-01-14: Hybrid Optimization

- **Reduced core CLAUDE.md:** 713 lines → 621 lines (13% reduction)
- **Consolidated duplicates:** Single canonical checklists, agent reference, testing standards
- **Reorganized by frequency:** Hot path protocols first, reference material to auxiliary docs
- **Extracted cold path:** Philosophy and reference material to auxiliary docs
- **Added navigation:** Quick Access section with direct links
- **Result:** 13% core reduction, improved discoverability, minimal fragmentation

**Validation:**

- ✓ All 6 protocols preserved
- ✓ All checklists consolidated and accessible
- ✓ All agent information complete
- ✓ Hot path workflows tested
- ✓ No information loss

## Quick Reference

### I'm starting a session

→ Read `CLAUDE.md` from the top (Protocol 0)

### I'm about to commit

→ Reference `CLAUDE.md` Protocol 4 and Pre-Commit Checklist

### I'm declaring work complete

→ Follow `CLAUDE.md` Completion Protocol (6 stages)

### I need philosophical guidance

→ Read `PHILOSOPHY.md` for decision frameworks

### I need command references

→ Read `REFERENCE.md` for CI/CD commands and templates

### I'm setting up a new repository

→ Read `REFERENCE.md` Repository Initialization section

### I'm facing an architectural decision

→ Read `PHILOSOPHY.md` Core Beliefs and Application Guidelines
