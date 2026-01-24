import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "FileWatcherService")

/// Service for watching filesystem changes in real-time
/// Uses FSEvents to monitor the tasks directory and trigger validation
class FileWatcherService {
    static let shared = FileWatcherService()

    private var streamRef: FSEventStreamRef?
    private var watchedPath: String?
    private var debounceWorkItem: DispatchWorkItem?

    /// Callback when changes are detected
    var onChangesDetected: (() -> Void)?

    private init() {}

    /// Start watching a project's tasks directory
    func startWatching(projectPath: String) {
        let tasksPath = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("tasks").path

        // Don't restart if already watching the same path
        if watchedPath == tasksPath && streamRef != nil {
            return
        }

        // Stop any existing watcher
        stopWatching()

        watchedPath = tasksPath

        // Check if directory exists
        guard FileManager.default.fileExists(atPath: tasksPath) else {
            logger.info("Tasks directory doesn't exist, not watching: \(tasksPath)")
            return
        }

        // Create FSEvents stream
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [tasksPath] as CFArray

        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallBackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()
            watcher.handleFSEvents()
        }

        streamRef = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // Latency in seconds (debounce at FSEvents level)
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = streamRef {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            logger.info("Started watching: \(tasksPath)")
        }
    }

    /// Stop watching
    func stopWatching() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            logger.info("Stopped watching: \(self.watchedPath ?? "unknown")")
        }
        self.watchedPath = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// Handle FSEvents - debounced to avoid rapid-fire updates
    private func handleFSEvents() {
        // Cancel any pending work
        debounceWorkItem?.cancel()

        // Create new debounced work item
        let workItem = DispatchWorkItem { [weak self] in
            logger.info("Filesystem changes detected, triggering validation")
            DispatchQueue.main.async {
                self?.onChangesDetected?()
            }
        }

        debounceWorkItem = workItem

        // Execute after 0.5 second debounce
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    deinit {
        stopWatching()
    }
}
