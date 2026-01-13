# Claude Hub

A native macOS app for managing Claude Code sessions across projects.

## Setup Instructions

### Option 1: Open in Xcode (Recommended)

1. Open Xcode
2. File → New → Project
3. Choose "macOS" → "App"
4. Settings:
   - Product Name: `ClaudeHub`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Save to: `~/Dropbox/Buzzbox/ClaudeHub` (replace existing)
5. Delete the auto-generated ContentView.swift
6. Add existing files: Drag the `ClaudeHub/` folder contents into Xcode
7. Add SwiftTerm package:
   - File → Add Package Dependencies
   - URL: `https://github.com/migueldeicaza/SwiftTerm.git`
   - Add to target: ClaudeHub
8. Build and run (Cmd+R)

### Option 2: Swift Package Manager

```bash
cd ~/Dropbox/Buzzbox/ClaudeHub
swift build
swift run
```

Note: SPM works for building but Xcode gives a better experience for Mac app development.

## Project Structure

```
ClaudeHub/
├── ClaudeHubApp.swift      # Main app entry + AppState
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
