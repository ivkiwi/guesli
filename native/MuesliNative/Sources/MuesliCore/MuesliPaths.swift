import Foundation

private final class MuesliTestProcessFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func enable() {
        lock.lock()
        enabled = true
        lock.unlock()
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }
}

public enum MuesliPaths {
    @TaskLocal public static var testSupportDirectoryRoot: URL?
    private static let testProcessFlag = MuesliTestProcessFlag()

    public static func markRunningTestsForCurrentProcess() {
        testProcessFlag.enable()
    }

    public static func defaultSupportDirectoryURL(appName: String = "Guesli", fileManager: FileManager = .default) -> URL {
        if let testSupportDirectoryRoot {
            return testSupportDirectoryRoot
                .appendingPathComponent(appName, isDirectory: true)
                .standardizedFileURL
        }
        if isRunningTests {
            let root = ProcessInfo.processInfo.environment["MUESLI_TEST_SUPPORT_ROOT"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? fileManager.temporaryDirectory
                    .appendingPathComponent("muesli-test-support-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return root
                .appendingPathComponent(appName, isDirectory: true)
                .standardizedFileURL
        }
        return userSupportDirectoryURL(appName: appName, fileManager: fileManager)
    }

    public static func userSupportDirectoryURL(appName: String = "Guesli", fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
            .standardizedFileURL
    }

    public static func defaultDatabaseURL(appName: String = "Guesli") -> URL {
        databaseURL(supportDirectory: defaultSupportDirectoryURL(appName: appName))
    }

    public static func databaseURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("muesli.db")
    }

    public static func preconditionSafeForTestWrite(
        _ url: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard isRunningTests else { return }
        let path = url.standardizedFileURL.path
        for appName in ["Guesli", "Muesli"] {
            let supportPath = userSupportDirectoryURL(appName: appName).path
            if path == supportPath || path.hasPrefix(supportPath + "/") {
                preconditionFailure(
                    "Test attempted to write real user support directory: \(path)",
                    file: file,
                    line: line
                )
            }
        }
    }

    public static var isRunningTests: Bool {
        if testProcessFlag.isEnabled {
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["MUESLI_TEST_SUPPORT_ROOT"]?.isEmpty == false {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if Bundle.main.bundlePath.hasSuffix(".xctest") {
            return true
        }
        return false
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
