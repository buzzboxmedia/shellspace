import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    // Fetch all projects, sorted by name
    @Query(sort: \Project.name) private var allProjects: [Project]

    @State private var showSettings = false
    @State private var showCleanup = false
    @State private var showAddProject = false
    @State private var draggedProject: Project?

    // Persisted order for dashboard
    @AppStorage("dashboardOrder") private var orderData: Data = Data()

    private var savedOrder: [String] {
        (try? JSONDecoder().decode([String].self, from: orderData)) ?? []
    }

    private func saveOrder(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths) {
            orderData = data
        }
        ProjectSyncService.shared.exportProjects(from: modelContext)
    }

    // All projects sorted by persisted order
    var displayProjects: [Project] {
        let order = savedOrder
        guard !order.isEmpty else { return allProjects.map { $0 } }
        return allProjects.sorted { a, b in
            let indexA = order.firstIndex(of: a.path) ?? Int.max
            let indexB = order.firstIndex(of: b.path) ?? Int.max
            return indexA < indexB
        }
    }

    // Adaptive grid that responds to window width
    private let gridColumns = [
        GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)
    ]

    var body: some View {
        ZStack {
            // Glass background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 40) {
                    // Header with settings button and running sessions indicator
                    HStack {
                        Spacer()
                        Text("Shellspace")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .leading) {
                        // Show running sessions indicator
                        if !appState.terminalControllers.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                Text("\(appState.terminalControllers.count) running")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.leading, 8)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 12) {
                            Button {
                                showCleanup = true
                            } label: {
                                Image(systemName: "tray.full.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage Sessions")

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                                SettingsView()
                                    .environmentObject(appState)
                            }
                        }
                        .padding(.trailing, 8)
                    }

                    VStack(spacing: 36) {
                        // All projects in a single grid
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Spacer()

                                Button {
                                    showAddProject = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .medium))
                                        Text("Add")
                                            .font(.system(size: 14, weight: .medium))
                                    }
                                    .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }

                            if displayProjects.isEmpty {
                                Text("No projects yet. Click Add to get started.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 20)
                            } else {
                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    ForEach(displayProjects) { project in
                                        ProjectCard(project: project)
                                            .onDrag {
                                                draggedProject = project
                                                return NSItemProvider(object: project.path as NSString)
                                            }
                                            .onDrop(of: [.text], delegate: DashboardDropDelegate(
                                                targetProject: project,
                                                allProjects: displayProjects,
                                                draggedProject: $draggedProject,
                                                saveOrder: saveOrder
                                            ))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(48)
            }
        }
        .sheet(isPresented: $showCleanup) {
            SessionCleanupView()
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet()
        }
    }
}

// MARK: - Dashboard Drop Delegate

struct DashboardDropDelegate: DropDelegate {
    let targetProject: Project
    let allProjects: [Project]
    @Binding var draggedProject: Project?
    let saveOrder: ([String]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedProject = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedProject,
              dragged.path != targetProject.path,
              let fromIndex = allProjects.firstIndex(where: { $0.path == dragged.path }),
              let toIndex = allProjects.firstIndex(where: { $0.path == targetProject.path }) else {
            return
        }

        var paths = allProjects.map { $0.path }
        let movedPath = paths.remove(at: fromIndex)
        paths.insert(movedPath, at: toIndex)

        withAnimation(.easeInOut(duration: 0.2)) {
            saveOrder(paths)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Project Card

struct ProjectCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var showEditProject = false

    /// Count of sessions with active terminal controllers (running in background)
    var runningCount: Int {
        project.sessions.filter { appState.terminalControllers[$0.id] != nil }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: project.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.primary)

                // Show blue dot for running sessions
                if runningCount > 0 {
                    Circle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 10, height: 10)
                        .offset(x: 5, y: -5)
                }
            }

            Text(project.name)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: 120, height: 120)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            // Delete button on hover
            if isHovered {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.ultraThinMaterial).frame(width: 20, height: 20))
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: 4)
                .transition(.opacity)
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                windowState.selectedProject = project
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Open") {
                withAnimation(.spring(response: 0.3)) {
                    windowState.selectedProject = project
                }
            }

            Button("Edit Project...") {
                showEditProject = true
            }

            Divider()

            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }

            Divider()

            Button("Remove...", role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .sheet(isPresented: $showEditProject) {
            ProjectSheet(editing: project)
        }
        .alert("Remove \(project.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                modelContext.delete(project)
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        } message: {
            Text("This removes it from Shellspace. Your files on disk are not affected.")
        }
    }

}

// NSVisualEffectView wrapper for glass effect
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Preview available in Xcode only
