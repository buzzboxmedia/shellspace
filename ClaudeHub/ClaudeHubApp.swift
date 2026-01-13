import SwiftUI

@main
struct ClaudeHubApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    // Make sure app is active when window appears
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Claude Hub", systemImage: "terminal.fill") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app can become active
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // When app becomes active, make sure the main window is key
        if let window = NSApplication.shared.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

class AppState: ObservableObject {
    @Published var selectedProject: Project?
    @Published var sessions: [Session] = []
    @Published var activeSession: Session?
    @Published var mainProjects: [Project] = []
    @Published var clientProjects: [Project] = []

    private let defaults = UserDefaults.standard
    private let mainProjectsKey = "mainProjects"
    private let clientProjectsKey = "clientProjects"
    private let sessionsKey = "sessions"

    init() {
        loadProjects()
        loadSessions()
    }

    func sessionsFor(project: Project) -> [Session] {
        sessions.filter { $0.projectPath == project.path }
    }

    func createSession(for project: Project) -> Session {
        let session = Session(
            id: UUID(),
            name: "New Chat",
            projectPath: project.path,
            createdAt: Date()
        )
        sessions.append(session)
        activeSession = session
        saveSessions()
        return session
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if activeSession?.id == session.id {
            activeSession = nil
        }
        saveSessions()
    }

    func updateSessionName(_ session: Session, name: String) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].name = name
            saveSessions()
        }
    }

    // MARK: - Session Persistence

    private func loadSessions() {
        if let data = defaults.data(forKey: sessionsKey),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: sessionsKey)
        }
    }

    // MARK: - Project Management

    func addMainProject(_ project: Project) {
        mainProjects.append(project)
        saveProjects()
    }

    func addClientProject(_ project: Project) {
        clientProjects.append(project)
        saveProjects()
    }

    func removeMainProject(_ project: Project) {
        mainProjects.removeAll { $0.id == project.id }
        saveProjects()
    }

    func removeClientProject(_ project: Project) {
        clientProjects.removeAll { $0.id == project.id }
        saveProjects()
    }

    // MARK: - Persistence

    private func loadProjects() {
        if let data = defaults.data(forKey: mainProjectsKey),
           let saved = try? JSONDecoder().decode([SavedProject].self, from: data) {
            mainProjects = saved.map { $0.toProject() }
        } else {
            // Default projects
            mainProjects = [
                Project(name: "Miller", path: NSString("~/Dropbox/Miller").expandingTildeInPath, icon: "person.fill"),
                Project(name: "Talkspresso", path: NSString("~/Dropbox/Talkspresso").expandingTildeInPath, icon: "cup.and.saucer.fill"),
                Project(name: "Buzzbox", path: NSString("~/Dropbox/Buzzbox").expandingTildeInPath, icon: "shippingbox.fill")
            ]
        }

        if let data = defaults.data(forKey: clientProjectsKey),
           let saved = try? JSONDecoder().decode([SavedProject].self, from: data) {
            clientProjects = saved.map { $0.toProject() }
        } else {
            // Default clients
            clientProjects = [
                Project(name: "AAGL", path: NSString("~/Dropbox/Buzzbox/Clients/AAGL").expandingTildeInPath, icon: "cross.case.fill"),
                Project(name: "AFL", path: NSString("~/Dropbox/Buzzbox/Clients/AFL").expandingTildeInPath, icon: "building.columns.fill"),
                Project(name: "Citadel", path: NSString("~/Dropbox/Buzzbox/Clients/Citadel").expandingTildeInPath, icon: "car.fill"),
                Project(name: "INFAB", path: NSString("~/Dropbox/Buzzbox/Clients/INFAB").expandingTildeInPath, icon: "shield.fill"),
                Project(name: "TDS", path: NSString("~/Dropbox/Buzzbox/Clients/TDS").expandingTildeInPath, icon: "eye.fill")
            ]
        }
    }

    private func saveProjects() {
        let mainSaved = mainProjects.map { SavedProject(from: $0) }
        let clientSaved = clientProjects.map { SavedProject(from: $0) }

        if let data = try? JSONEncoder().encode(mainSaved) {
            defaults.set(data, forKey: mainProjectsKey)
        }
        if let data = try? JSONEncoder().encode(clientSaved) {
            defaults.set(data, forKey: clientProjectsKey)
        }
    }
}

// Codable wrapper for Project persistence
struct SavedProject: Codable {
    let name: String
    let path: String
    let icon: String

    init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.icon = project.icon
    }

    func toProject() -> Project {
        Project(name: name, path: path, icon: icon)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let project = appState.selectedProject {
                WorkspaceView(project: project)
            } else {
                LauncherView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
