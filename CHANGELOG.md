# Changelog

## 0.2.0-alpha — 2026-10-11

### Added
- Public alpha release of the interactive factory stages and fresh worker/reviewer runner.
- Regression checks for approval, initial commits, manifest validation, evidence paths, and fail-fast checks.

### Fixed
- Valid Windows evidence paths now pass repository containment validation.
- Mandatory checks are written as valid multiline scripts, with stderr captured before their exit status is evaluated.
- Runs require an initial Git commit before starting workers.
- Malformed checks, task fields, and duplicate completed task IDs are rejected before execution.
- Alignment skill instructions use native discovery instead of a machine-specific cache path.

### Limitations
- Live model execution has not been validated end to end.
- Specification approval and red/green ordering remain supervised workflow gates.
- Focused test commands are supplied to workers; the runner independently executes only mandatory checks.
- Windows PowerShell is required. Conversation isolation does not isolate repository files.
