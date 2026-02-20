# Shellspace

A native macOS app for managing Claude Code sessions across projects.

## Setup

```bash
# New machine (after Dropbox syncs):
~/Dropbox/Shellspace/go.sh

# Or from scratch:
git clone git@github.com:buzzboxmedia/shellspace.git ~/Code/shellspace
cd ~/Code/shellspace && ./install.sh
```

## Project Structure

```
Shellspace/
├── ShellspaceApp.swift      # Main app entry + AppState
├── Models/
│   ├── Project.swift       # Project definition
│   └── Session.swift       # Chat session model
├── Views/
│   ├── LauncherView.swift  # Home screen with project cards
│   ├── WorkspaceView.swift # Split view: sidebar + terminal
│   ├── TerminalView.swift  # Terminal emulator (placeholder)
│   └── MenuBarView.swift   # Menu bar dropdown
└── Services/               # (Future: ProcessManager, etc.)
```

## Current Status

- [x] Launcher view with glass design
- [x] Workspace view with session sidebar
- [x] Menu bar integration
- [x] Session management (create, switch, rename)
- [ ] SwiftTerm integration for actual terminal
- [ ] PTY process management for Claude Code
- [ ] Session persistence to disk
- [ ] Background session support

## Next Steps (Reid)

1. Integrate SwiftTerm into TerminalView
2. Create ProcessManager to spawn `claude` CLI
3. Wire PTY to terminal view
4. Add session persistence

## Design

- Apple glass aesthetic (vibrancy, translucency)
- Two-section launcher (Main Projects / Clients)
- Minimal sidebar (session names only)
- SF Mono for terminal, SF Pro for UI
