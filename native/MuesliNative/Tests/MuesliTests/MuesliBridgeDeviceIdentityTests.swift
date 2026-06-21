import CloudKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MuesliBridgeDeviceIdentity", .serialized)
struct MuesliBridgeDeviceIdentityTests {
    private enum DefaultsKey {
        static let localDeviceID = "muesli.sync.bridge.localDeviceID.v1"
        static let remoteDeviceID = "muesli.sync.bridge.remoteDeviceID.v1"
        static let remoteDeviceName = "muesli.sync.bridge.remoteDeviceName.v1"
        static let remoteDevicePlatform = "muesli.sync.bridge.remoteDevicePlatform.v1"
        static let remoteDeviceLastSeenAt = "muesli.sync.bridge.remoteDeviceLastSeenAt.v1"
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.muesli.tests.bridge-device-identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func bridgeRecord(
        deviceID: String? = "device-1",
        platform: String? = "iOS",
        deviceName: String? = "iPhone",
        appVersion: String? = "1.0",
        lastSeenAt: Date? = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> CKRecord {
        let record = CKRecord(recordType: "MuesliBridgeDevice")
        if let deviceID {
            record["deviceID"] = deviceID as NSString
        }
        if let platform {
            record["platform"] = platform as NSString
        }
        if let deviceName {
            record["deviceName"] = deviceName as NSString
        }
        if let appVersion {
            record["appVersion"] = appVersion as NSString
        }
        if let lastSeenAt {
            record["lastSeenAt"] = lastSeenAt as NSDate
        }
        return record
    }

    @Test("shouldRefresh returns true with no timestamp")
    func shouldRefreshReturnsTrueWithNoTimestamp() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: Date(timeIntervalSince1970: 1_770_000_000)
        ))
    }

    @Test("shouldRefresh uses a short interval before a remote device is known")
    func shouldRefreshUsesShortIntervalBeforeRemoteDeviceIsKnown() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        #expect(!MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(59)
        ))
        #expect(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60)
        ))
    }

    @Test("shouldRefresh can force refresh before the throttle expires")
    func shouldRefreshCanForceRefreshBeforeThrottleExpires() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        #expect(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(1),
            forceRefresh: true
        ))
    }

    @Test("failed refresh uses short retry backoff instead of success throttle")
    func failedRefreshUsesShortRetryBackoffInsteadOfSuccessThrottle() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        defaults.set("remote-iphone", forKey: DefaultsKey.remoteDeviceID)
        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now.addingTimeInterval(-10))
        MuesliBridgeDeviceIdentity.markRefreshFailed(defaults: defaults, at: now)

        #expect(!MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(14)
        ))
        #expect(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(15)
        ))
    }

    @Test("shouldRefresh returns false within one hour and true after one hour once linked")
    func shouldRefreshUsesOneHourIntervalOnceLinked() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        defaults.set("remote-iphone", forKey: DefaultsKey.remoteDeviceID)
        MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults, at: now)

        #expect(!MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60 * 59)
        ))
        #expect(MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            now: now.addingTimeInterval(60 * 60)
        ))
    }

    @Test("updateRemoteDevices with empty records clears remote keys")
    func updateRemoteDevicesWithEmptyRecordsClearsRemoteKeys() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousLastSeenAt = Date(timeIntervalSince1970: 1_770_000_000)
        defaults.set("remote-previous", forKey: DefaultsKey.remoteDeviceID)
        defaults.set("Previous iPhone", forKey: DefaultsKey.remoteDeviceName)
        defaults.set("iOS", forKey: DefaultsKey.remoteDevicePlatform)
        defaults.set(previousLastSeenAt, forKey: DefaultsKey.remoteDeviceLastSeenAt)

        MuesliBridgeDeviceIdentity.updateRemoteDevices(from: [], defaults: defaults)

        #expect(defaults.object(forKey: DefaultsKey.remoteDeviceID) == nil)
        #expect(defaults.object(forKey: DefaultsKey.remoteDeviceName) == nil)
        #expect(defaults.object(forKey: DefaultsKey.remoteDevicePlatform) == nil)
        #expect(defaults.object(forKey: DefaultsKey.remoteDeviceLastSeenAt) == nil)
    }

    @Test("updateRemoteDevices picks the most recent non-local record")
    func updateRemoteDevicesPicksMostRecentNonLocalRecord() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("local-mac", forKey: DefaultsKey.localDeviceID)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let olderRemote = bridgeRecord(
            deviceID: "remote-old",
            deviceName: "Old iPhone",
            lastSeenAt: now.addingTimeInterval(-60)
        )
        let latestRemote = bridgeRecord(
            deviceID: "remote-new",
            platform: "iPadOS",
            deviceName: "iPad",
            lastSeenAt: now
        )
        let localRecord = bridgeRecord(
            deviceID: "local-mac",
            platform: "macOS",
            deviceName: "This Mac",
            lastSeenAt: now.addingTimeInterval(60)
        )

        MuesliBridgeDeviceIdentity.updateRemoteDevices(
            from: [olderRemote, latestRemote, localRecord],
            defaults: defaults
        )

        #expect(defaults.string(forKey: DefaultsKey.remoteDeviceID) == "remote-new")
        #expect(defaults.string(forKey: DefaultsKey.remoteDeviceName) == "iPad")
        #expect(defaults.string(forKey: DefaultsKey.remoteDevicePlatform) == "iPadOS")
        #expect(defaults.object(forKey: DefaultsKey.remoteDeviceLastSeenAt) as? Date == now)
    }

    @Test("snapshot returns nil when required fields are missing")
    func snapshotReturnsNilWhenRequiredFieldsAreMissing() {
        #expect(MuesliBridgeDeviceIdentity.snapshot(from: bridgeRecord(deviceID: nil)) == nil)
        #expect(MuesliBridgeDeviceIdentity.snapshot(from: bridgeRecord(platform: nil)) == nil)
        #expect(MuesliBridgeDeviceIdentity.snapshot(from: bridgeRecord(deviceName: nil)) == nil)
        #expect(MuesliBridgeDeviceIdentity.snapshot(from: bridgeRecord(lastSeenAt: nil)) == nil)
    }

    @Test("local persists UUID across calls for the same defaults suite")
    func localPersistsUUIDAcrossCallsForSameDefaultsSuite() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MuesliBridgeDeviceIdentity.local(defaults: defaults)
        let second = MuesliBridgeDeviceIdentity.local(defaults: defaults)

        #expect(first.deviceID == second.deviceID)
        #expect(UUID(uuidString: first.deviceID) != nil)
        #expect(defaults.string(forKey: DefaultsKey.localDeviceID) == first.deviceID)
    }
}
