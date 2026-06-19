import CloudKit
import Foundation
import MuesliCore

struct ICloudSyncKindCounts: Equatable {
    private(set) var dictations = 0
    private(set) var meetings = 0

    var total: Int {
        dictations + meetings
    }

    mutating func increment(_ kind: SyncTextRecordKind) {
        switch kind {
        case .dictation:
            dictations += 1
        case .meeting:
            meetings += 1
        }
    }
}

struct ICloudSyncResult: Equatable {
    let uploaded: ICloudSyncKindCounts
    let downloaded: ICloudSyncKindCounts
    let hasPendingUploads: Bool
    let syncedAt: Date
}

private struct ICloudZoneChangesPage {
    let records: [CKRecord]
    let serverChangeToken: CKServerChangeToken
    let moreComing: Bool
}

private struct ICloudQueryPage {
    let records: [CKRecord]
    let cursor: CKQueryOperation.Cursor?
}

protocol ICloudChangeTokenStore {
    func loadToken() -> CKServerChangeToken?
    func saveToken(_ token: CKServerChangeToken)
    func clearToken()
}

final class UserDefaultsICloudChangeTokenStore: ICloudChangeTokenStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "muesli.icloud.textRecords.privateDefaultZone.serverChangeToken.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    func saveToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        defaults.set(data, forKey: key)
    }

    func clearToken() {
        defaults.removeObject(forKey: key)
    }
}

private enum ICloudSyncAccountError: LocalizedError {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return "Sign in to iCloud on this Mac to sync text records."
        case .restricted:
            return "iCloud is restricted for this Mac."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try syncing again shortly."
        case .couldNotDetermine:
            return "Couldn't determine iCloud account status."
        }
    }
}

final class MuesliICloudSyncEngine {
    private enum Schema {
        static let containerIdentifier = "iCloud.com.mueslihq.muesli"
        static let textRecordType = "MuesliTextRecord"
        static let textSubscriptionID = "muesli-text-records-private-v1"
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let changeTokenStore: ICloudChangeTokenStore

    init(
        container: CKContainer = CKContainer(identifier: Schema.containerIdentifier),
        changeTokenStore: ICloudChangeTokenStore = UserDefaultsICloudChangeTokenStore()
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.changeTokenStore = changeTokenStore
    }

    func sync(store: DictationStore) async throws -> ICloudSyncResult {
        try await verifyAccountAvailable()

        let remoteRecords = try await fetchChangedTextRecords()
        var downloaded = ICloudSyncKindCounts()
        for record in remoteRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            if try store.upsertSyncedTextRecord(syncRecord) {
                downloaded.increment(syncRecord.kind)
            }
        }

        let dirtyRecords = try store.textRecordsNeedingSync()
        var dirtyRecordsByName: [String: SyncTextRecord] = [:]
        for dirtyRecord in dirtyRecords {
            dirtyRecordsByName[dirtyRecord.id] = dirtyRecord
        }
        let savedRecords = try await save(records: dirtyRecords.map(Self.cloudRecord(from:)))
        var uploaded = ICloudSyncKindCounts()
        var hasPendingUploads = false
        for savedRecord in savedRecords {
            let recordName = savedRecord.recordID.recordName
            guard let kind = Self.kind(from: savedRecord),
                  let dirtyRecord = dirtyRecordsByName[recordName] else { continue }
            uploaded.increment(kind)
            let didMarkSynced = try store.markTextRecordSynced(
                kind: kind,
                recordName: recordName,
                changeTag: savedRecord.recordChangeTag,
                recordUpdatedAt: dirtyRecord.updatedAt
            )
            hasPendingUploads = hasPendingUploads || !didMarkSynced
        }

        return ICloudSyncResult(
            uploaded: uploaded,
            downloaded: downloaded,
            hasPendingUploads: hasPendingUploads,
            syncedAt: Date()
        )
    }

    func ensureTextRecordSubscription() async throws {
        try await verifyAccountAvailable()
        do {
            _ = try await fetchSubscription(id: Schema.textSubscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            let subscription = CKQuerySubscription(
                recordType: Schema.textRecordType,
                predicate: NSPredicate(value: true),
                subscriptionID: Schema.textSubscriptionID,
                options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
            )
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo
            _ = try await save(subscription: subscription)
        }
    }

    static func isTextRecordSubscriptionNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == Schema.textSubscriptionID
    }

    private func verifyAccountAvailable() async throws {
        let status = try await accountStatus()
        switch status {
        case .available:
            return
        case .noAccount:
            throw ICloudSyncAccountError.noAccount
        case .restricted:
            throw ICloudSyncAccountError.restricted
        case .temporarilyUnavailable:
            throw ICloudSyncAccountError.temporarilyUnavailable
        case .couldNotDetermine:
            throw ICloudSyncAccountError.couldNotDetermine
        @unknown default:
            throw ICloudSyncAccountError.couldNotDetermine
        }
    }

    private func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func fetchChangedTextRecords() async throws -> [CKRecord] {
        // CloudKit's app default zone rejects CKFetchRecordZoneChangesOperation
        // with "AppDefaultZone does not support getChanges call". Earlier builds
        // tried it first and fell back to a full query, but that can leave the
        // sync task stuck if the rejected operation never calls its completion.
        // Keep the token-based implementation below for a future custom zone,
        // but use the reliable query path for the current default-zone schema.
        changeTokenStore.clearToken()
        return try await fetchAllTextRecords()
    }

    private func fetchChangedTextRecordsUsingStoredToken() async throws -> [CKRecord] {
        let zoneID = CKRecordZone.default().zoneID
        var previousToken = changeTokenStore.loadToken()
        var records: [CKRecord] = []

        while true {
            let page = try await fetchZoneChangesPage(
                zoneID: zoneID,
                previousServerChangeToken: previousToken
            )
            records.append(contentsOf: page.records)
            previousToken = page.serverChangeToken
            changeTokenStore.saveToken(page.serverChangeToken)
            if !page.moreComing {
                break
            }
        }

        return records
    }

    private func fetchAllTextRecords() async throws -> [CKRecord] {
        var cursor: CKQueryOperation.Cursor?
        var records: [CKRecord] = []

        repeat {
            let page = try await fetchTextRecordsPage(cursor: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        } while cursor != nil

        return records
    }

    private func fetchTextRecordsPage(cursor: CKQueryOperation.Cursor?) async throws -> ICloudQueryPage {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: CKQuery(
                    recordType: Schema.textRecordType,
                    predicate: NSPredicate(value: true)
                ))
            }
            operation.desiredKeys = Self.desiredTextRecordKeys
            operation.resultsLimit = 200

            let lock = NSLock()
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    lock.lock()
                    let pageRecords = records
                    lock.unlock()
                    continuation.resume(returning: ICloudQueryPage(records: pageRecords, cursor: cursor))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchZoneChangesPage(
        zoneID: CKRecordZone.ID,
        previousServerChangeToken: CKServerChangeToken?
    ) async throws -> ICloudZoneChangesPage {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken,
                resultsLimit: nil,
                desiredKeys: Self.desiredTextRecordKeys
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            let lock = NSLock()
            var records: [CKRecord] = []
            var zoneResult: Result<(serverChangeToken: CKServerChangeToken, moreComing: Bool), Error>?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result,
                   record.recordType == Schema.textRecordType {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { _, _ in
                // Muesli sync uses soft deletes via the isDeleted field, so hard CloudKit
                // deletions are ignored until we have a record-name-to-kind tombstone map.
            }
            operation.recordZoneFetchResultBlock = { _, result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success(let page):
                    zoneResult = .success((page.serverChangeToken, page.moreComing))
                case .failure(let error):
                    zoneResult = .failure(error)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let pageRecords = records
                    let pageResult = zoneResult
                    lock.unlock()
                    switch pageResult {
                    case .success(let page):
                        continuation.resume(returning: ICloudZoneChangesPage(
                            records: pageRecords,
                            serverChangeToken: page.serverChangeToken,
                            moreComing: page.moreComing
                        ))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .none:
                        continuation.resume(throwing: CKError(.internalError))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchSubscription(id: String) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withSubscriptionID: id) { subscription, error in
                if let subscription {
                    continuation.resume(returning: subscription)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    private func save(records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            let lock = NSLock()
            var savedRecords: [CKRecord] = []
            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    savedRecords.append(record)
                    lock.unlock()
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let records = savedRecords
                    lock.unlock()
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func save(subscription: CKSubscription) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.save(subscription) { savedSubscription, error in
                if let savedSubscription {
                    continuation.resume(returning: savedSubscription)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.internalError))
                }
            }
        }
    }

    private static func cloudRecord(from record: SyncTextRecord) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id)
        let cloud = CKRecord(recordType: Schema.textRecordType, recordID: recordID)
        cloud["kind"] = record.kind.rawValue as NSString
        cloud["title"] = record.title as NSString?
        cloud["text"] = record.text as NSString
        cloud["speakerTranscript"] = record.speakerTranscript as NSString?
        cloud["summaryText"] = record.summaryText as NSString?
        cloud["manualNotes"] = record.manualNotes as NSString?
        cloud["source"] = record.source as NSString?
        cloud["engineIdentifier"] = record.engineIdentifier as NSString?
        cloud["createdAt"] = record.createdAt as NSDate
        cloud["updatedAt"] = record.updatedAt as NSDate
        cloud["startedAt"] = record.startedAt as NSDate?
        cloud["endedAt"] = record.endedAt as NSDate?
        cloud["durationSeconds"] = record.durationSeconds as NSNumber
        cloud["wordCount"] = record.wordCount as NSNumber
        cloud["isDeleted"] = record.isDeleted as NSNumber
        cloud["schemaVersion"] = 1 as NSNumber
        return cloud
    }

    private static func syncTextRecord(from record: CKRecord) -> SyncTextRecord? {
        guard let kind = kind(from: record),
              let text = record["text"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
        return SyncTextRecord(
            id: record.recordID.recordName,
            kind: kind,
            title: record["title"] as? String,
            text: text,
            speakerTranscript: record["speakerTranscript"] as? String,
            summaryText: record["summaryText"] as? String,
            manualNotes: record["manualNotes"] as? String,
            source: record["source"] as? String,
            engineIdentifier: record["engineIdentifier"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: record["startedAt"] as? Date,
            endedAt: record["endedAt"] as? Date,
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue ?? 0,
            wordCount: (record["wordCount"] as? NSNumber)?.intValue ?? 0,
            isDeleted: (record["isDeleted"] as? NSNumber)?.boolValue ?? false,
            cloudChangeTag: record.recordChangeTag
        )
    }

    private static func kind(from record: CKRecord) -> SyncTextRecordKind? {
        guard let raw = record["kind"] as? String else { return nil }
        return SyncTextRecordKind(rawValue: raw)
    }

    private static func isDefaultZoneChangeFetchUnsupported(_ error: Error) -> Bool {
        let nsError = error as NSError
        let message = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion,
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return message.contains("appdefaultzone")
            && message.contains("does not support")
            && message.contains("change")
    }

    private static var desiredTextRecordKeys: [CKRecord.FieldKey] {
        [
            "kind",
            "title",
            "text",
            "speakerTranscript",
            "summaryText",
            "manualNotes",
            "source",
            "engineIdentifier",
            "createdAt",
            "updatedAt",
            "startedAt",
            "endedAt",
            "durationSeconds",
            "wordCount",
            "isDeleted",
            "schemaVersion",
        ]
    }
}
