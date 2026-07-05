import Foundation

public enum MuesliPaths {
    public static func defaultSupportDirectoryURL(appName: String = "Guesli", fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Guesli") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("muesli.db")
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
