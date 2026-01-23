# Sync / Git

**Status:** active
**Created:** 2026-01-23
**Project:** ClaudeHub

## Description
Merge the `cleanup-simplify` branch into `main` and push to remote.

## Current State
- **Branch:** `cleanup-simplify` (up to date with origin)
- **Commits ahead of main:** 1 (`edfc05d Remove unused services and simplify codebase`)

## Changes to Merge
The cleanup commit removes ~1,843 lines and adds ~393 lines:

**Removed (unused):**
- Services: `ActiveProjectsParser`, `DataMigration`, `GoogleSheetsService`, `ParkerBriefingGenerator`, `TailscaleServer`
- Views: `SendToBillingSheet`, `TaskDetailView`
- Models: `ActiveProject`, `TaskGroup`

**Added:**
- `SessionSyncService`

**Simplified:**
- `ClaudeHubApp`, `Session`, `TerminalView`, `WorkspaceView`, `LauncherView`, `TaskFolderService`

**Other:**
- Moved `001-claudehub-mobile` to `tasks/completed/`

## Next Steps
1. Merge `cleanup-simplify` into `main`
2. Push to remote
3. Mark task complete

## Progress

### 2026-01-23
- Reviewed current git state
- Identified 1 commit on `cleanup-simplify` ready to merge
- Documented changes above for cross-machine context
- Set up Claude session sync via Dropbox symlink

## Claude Session Sync Setup

**This machine (done):**
```bash
mv ~/.claude ~/Dropbox/.claude
ln -s ~/Dropbox/.claude ~/.claude
```

**Other machine (run this once Dropbox syncs):**
```bash
rm -rf ~/.claude
ln -s ~/Dropbox/.claude ~/.claude
```

This syncs all Claude Code conversation history across machines via Dropbox.
