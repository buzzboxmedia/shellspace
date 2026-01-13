# Monday Night — Claude Hub Project

## What We Built

**Claude Hub** — a native macOS app for managing Claude Code sessions across your projects.

## Location

```
~/Dropbox/Buzzbox/ClaudeHub/
```

## How to Run

```bash
~/Dropbox/Buzzbox/ClaudeHub/.build/debug/ClaudeHub
```

Or rebuild first:
```bash
cd ~/Dropbox/Buzzbox/ClaudeHub && swift build && .build/debug/ClaudeHub
```

## Features Complete

- [x] Glass design launcher with project cards
- [x] Two sections: Main Projects + Clients
- [x] Workspace view with session sidebar
- [x] SwiftTerm integration for terminal emulation
- [x] Auto-start Claude when clicking a project
- [x] Settings panel (gear icon) to add/remove projects
- [x] Project persistence (saves your project list)
- [x] Session persistence (sessions survive app restart)
- [x] Session delete (hover over session, click X)
- [x] Session rename (double-click session name)
- [x] Menu bar icon for quick access
- [x] Keyboard focus improvements (key forwarding to terminal)
- [x] App delegate for proper window activation

## Still Needs Testing

- [ ] **Keyboard input** — verify typing works in terminal
- [ ] **Claude process** — verify Claude actually starts and responds

## Files Structure

```
ClaudeHub/
├── Package.swift
├── README.md
├── MONDAY-NIGHT.md          ← This file
└── ClaudeHub/
    ├── ClaudeHubApp.swift   ← Main app + AppState + persistence
    ├── Models/
    │   ├── Project.swift
    │   └── Session.swift    ← Now Codable for persistence
    └── Views/
        ├── LauncherView.swift
        ├── WorkspaceView.swift
        ├── TerminalView.swift   ← SwiftTerm + key forwarding
        ├── MenuBarView.swift
        └── SettingsView.swift   ← Add/remove projects
```

## Key Fixes Made

1. **Keyboard focus**: Added key event forwarding from container to terminal
2. **Window activation**: Added AppDelegate to ensure app becomes active
3. **Session persistence**: Sessions now save to UserDefaults
4. **Session management**: Can delete sessions (hover + X) and rename (double-click)

## Tech Stack

- SwiftUI (native macOS)
- SwiftTerm (terminal emulation)
- No Xcode needed — builds with `swift build`
