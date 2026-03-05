import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    // Fetch projects
    @Query(sort: \Project.name) private var allProjects: [Project]

    var mainProjects: [Project] {
        allProjects.filter { $0.category == .main }
    }

    var clientProjects: [Project] {
        allProjects.filter { $0.category == .client }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Projects")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Main Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("MAIN PROJECTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(category: .main)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ForEach(mainProjects) { project in
                    ProjectRow(project: project)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Client Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CLIENTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(category: .client)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                ForEach(clientProjects) { project in
                    ProjectRow(project: project)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Relay Connection Section
            RelaySettingsSection()

            Divider()
                .padding(.vertical, 8)

            // Team & Companion Sharing Section
            TeamSharingSection(projects: allProjects)

            Divider()
                .padding(.vertical, 8)

            // Legacy Companion Sharing (fallback for users without assignments)
            CompanionSharingSection(projects: allProjects)

            Spacer()

            Divider()

            // About Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ABOUT")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack {
                    Text("Shellspace")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text("v\(AppVersion.version)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                HStack {
                    Text("Build: \(AppVersion.buildHash)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check for Updates") {
                        checkForUpdates()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            // Footer
            HStack {
                Text("Click + to add a folder from your Mac")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 350, height: 700)
        .background(.ultraThinMaterial)
    }

    func checkForUpdates() {
        // Open GitHub releases page
        if let url = URL(string: "https://github.com/buzzboxmedia/shellspace/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func addProject(category: ProjectCategory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to add as a project"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let name = url.lastPathComponent
                let path = url.path
                let icon = "folder.fill"

                let project = Project(name: name, path: path, icon: icon, category: category)
                modelContext.insert(project)
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        }
    }
}

struct ProjectRow: View {
    @Environment(\.modelContext) private var modelContext
    let project: Project
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: project.icon)
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .medium))

                Text(displayPath(project.path))
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button {
                    editProjectPath()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Change folder path")

                Button {
                    modelContext.delete(project)
                    ProjectSyncService.shared.exportProjects(from: modelContext)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }

    func editProjectPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select new folder for \(project.name)"
        panel.directoryURL = URL(fileURLWithPath: project.path)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                project.path = url.path
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        }
    }

    func displayPath(_ path: String) -> String {
        // Show just the last 2 path components for cleaner look
        let components = path.split(separator: "/")
        if components.count >= 2 {
            let lastTwo = components.suffix(2).joined(separator: "/")
            return ".../" + lastTwo
        }
        return path
    }
}

// MARK: - Team Sharing

struct TeamSharingSection: View {
    let projects: [Project]
    @State private var members = TeamAssignments.members
    @State private var newEmail = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var expandedMember: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TEAM")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            if members.isEmpty {
                Text("No team members. Add people by email to share access.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(members) { member in
                        TeamMemberRow(
                            member: member,
                            projects: projects,
                            isExpanded: expandedMember == member.userId,
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedMember = expandedMember == member.userId ? nil : member.userId
                                }
                            },
                            onRemove: {
                                Task {
                                    try? await RelayAuth.shared.revokeDeviceShare(userId: member.userId)
                                    TeamAssignments.removeMember(userId: member.userId)
                                    members = TeamAssignments.members
                                }
                            }
                        )
                    }
                }
            }

            // Add member field
            HStack(spacing: 8) {
                TextField("Email address", text: $newEmail)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addMember() }

                Button {
                    addMember()
                } label: {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Add")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .disabled(newEmail.isEmpty || isAdding)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)

            if let error = addError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            Text("Team members can connect from iOS and only see assigned projects")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        }
    }

    private func addMember() {
        guard !newEmail.isEmpty else { return }
        isAdding = true
        addError = nil

        Task {
            do {
                let (userId, email) = try await RelayAuth.shared.shareDevice(email: newEmail)
                TeamAssignments.addMember(userId: userId, email: email)
                await MainActor.run {
                    members = TeamAssignments.members
                    newEmail = ""
                    isAdding = false
                    // Auto-expand newly added member for project assignment
                    expandedMember = userId
                }
            } catch {
                await MainActor.run {
                    addError = error.localizedDescription
                    isAdding = false
                }
            }
        }
    }
}

struct TeamMemberRow: View {
    let member: TeamAssignments.TeamMember
    let projects: [Project]
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onRemove: () -> Void

    @State private var assignedIds = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            // Member header
            HStack(spacing: 10) {
                Image(systemName: isOnline ? "person.circle.fill" : "person.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOnline ? .green : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(member.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if member.name != nil {
                        Text(member.email)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isOnline {
                    Text("Online")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                }

                // Expand/collapse for project assignment
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Remove button
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Expanded: project assignment checkboxes
            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(projects) { project in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { assignedIds.contains(project.id.uuidString) },
                                set: { _ in
                                    TeamAssignments.toggleProject(project.id.uuidString, for: member.userId)
                                    assignedIds = TeamAssignments.assignedProjectIds(for: member.userId)
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)

                            Image(systemName: project.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(project.name)
                                .font(.system(size: 12))

                            Spacer()
                        }
                        .padding(.horizontal, 32)
                    }

                    if assignedIds.isEmpty {
                        Text("No projects assigned = sees all shared projects")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 32)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.02))
            }
        }
        .onAppear {
            assignedIds = TeamAssignments.assignedProjectIds(for: member.userId)
        }
    }

    private var isOnline: Bool {
        // Check if this member is currently connected via tunnel
        // We'd need access to the relay client's connectedTunnelUsers
        // For now, use a simple check via AppState or UserDefaults
        false // Will be connected to live data
    }
}

// MARK: - Companion Sharing

/// Controls which projects are visible to iOS companion apps.
/// When restricted, only selected projects are sent to connected iOS devices.
enum CompanionSharing {
    private static let key = "companionSharedProjectIds"
    private static let restrictedKey = "companionSharingRestricted"

    /// Whether companion sharing is restricted (only selected projects visible)
    static var isRestricted: Bool {
        get { UserDefaults.standard.bool(forKey: restrictedKey) }
        set { UserDefaults.standard.set(newValue, forKey: restrictedKey) }
    }

    /// Project IDs that are shared with iOS companions (only used when restricted)
    static var sharedProjectIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func isShared(_ projectId: String) -> Bool {
        if !isRestricted { return true }
        return sharedProjectIds.contains(projectId)
    }

    static func toggle(_ projectId: String) {
        var ids = sharedProjectIds
        if ids.contains(projectId) {
            ids.remove(projectId)
        } else {
            ids.insert(projectId)
        }
        sharedProjectIds = ids
    }
}

struct CompanionSharingSection: View {
    let projects: [Project]
    @State private var isRestricted = CompanionSharing.isRestricted
    @State private var sharedIds = CompanionSharing.sharedProjectIds

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iOS COMPANION")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            Toggle(isOn: $isRestricted) {
                Text("Restrict visible projects")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 16)
            .onChange(of: isRestricted) { _, newValue in
                CompanionSharing.isRestricted = newValue
            }

            if isRestricted {
                VStack(spacing: 4) {
                    ForEach(projects) { project in
                        HStack(spacing: 10) {
                            Image(systemName: project.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            Text(project.name)
                                .font(.system(size: 13))

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { sharedIds.contains(project.id.uuidString) },
                                set: { _ in
                                    CompanionSharing.toggle(project.id.uuidString)
                                    sharedIds = CompanionSharing.sharedProjectIds
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                }

                Text("Only toggled projects are visible on iOS")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            } else {
                Text("All projects visible on iOS companions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Relay Settings

struct RelaySettingsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var connectionMode: RelayAuth.ConnectionMode = RelayAuth.shared.connectionMode
    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var loginError: String?
    @State private var showSignup = false

    private var isAuthenticated: Bool {
        RelayAuth.shared.isAuthenticated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REMOTE ACCESS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                // Connection status indicator
                if connectionMode == .relay {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Mode toggle
            Picker("Mode", selection: $connectionMode) {
                Text("Local (LAN/Tailscale)").tag(RelayAuth.ConnectionMode.local)
                Text("Relay (Internet)").tag(RelayAuth.ConnectionMode.relay)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .onChange(of: connectionMode) { _, newValue in
                RelayAuth.shared.connectionMode = newValue
            }

            if connectionMode == .relay {
                if isAuthenticated {
                    // Logged in state
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.green)
                        Text(RelayAuth.shared.email ?? "Connected")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Logout") {
                            RelayAuth.shared.logout()
                            email = ""
                            password = ""
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 16)
                } else {
                    // Login form
                    VStack(spacing: 6) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .textContentType(.emailAddress)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit { performLogin() }

                        if let error = loginError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }

                        HStack {
                            Button(showSignup ? "Sign Up" : "Login") {
                                performLogin()
                            }
                            .disabled(email.isEmpty || password.isEmpty || isLoggingIn)
                            .font(.system(size: 13, weight: .medium))

                            Spacer()

                            Button(showSignup ? "Have an account? Login" : "Create Account") {
                                showSignup.toggle()
                                loginError = nil
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var statusColor: Color {
        switch appState.relayConnectionState {
        case .connected, .authenticated: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch appState.relayConnectionState {
        case .connected: return "Connected"
        case .authenticated: return "Authenticated"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        }
    }

    private func performLogin() {
        guard !email.isEmpty, !password.isEmpty else { return }
        isLoggingIn = true
        loginError = nil

        Task {
            do {
                if showSignup {
                    try await RelayAuth.shared.signup(email: email, password: password)
                } else {
                    try await RelayAuth.shared.login(email: email, password: password)
                }
                await MainActor.run {
                    isLoggingIn = false
                    loginError = nil
                    password = ""
                }
            } catch {
                await MainActor.run {
                    isLoggingIn = false
                    loginError = error.localizedDescription
                }
            }
        }
    }
}

// Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}
