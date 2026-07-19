import CoreServices
import Foundation

@MainActor
final class CodexFileEventMonitor {
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor @Sendable () -> Void)?

    func start(codexHome: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [codexHome.standardizedFileURL.path] as CFArray
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<CodexFileEventMonitor>.fromOpaque(info).takeUnretainedValue()
                    monitor.onChange?()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
                | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        onChange = nil
    }
}
