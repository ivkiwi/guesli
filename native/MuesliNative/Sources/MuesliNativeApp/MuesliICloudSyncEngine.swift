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
    let syncedAt: Date
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

    init(container: CKContainer = CKContainer(identifier: Schema.containerIdentifier)) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func sync(store: DictationStore) async throws -> ICloudSyncResult {
        try await verifyAccountAvailable()

        let remoteRecords = try await fetchTextRecords()
        var downloaded = ICloudSyncKindCounts()
        for record in remoteRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            try store.upsertSyncedTextRecord(syncRecord)
            downloaded.increment(syncRecord.kind)
        }

        let dirtyRecords = try store.textRecordsNeedingSync()
        let savedRecords = try await save(records: dirtyRecords.map(Self.cloudRecord(from:)))
        var uploaded = ICloudSyncKindCounts()
        for savedRecord in savedRecords {
            guard let kind = Self.kind(from: savedRecord) else { continue }
            uploaded.increment(kind)
            try store.markTextRecordSynced(
                kind: kind,
                recordName: savedRecord.recordID.recordName,
                changeTag: savedRecord.recordChangeTag
            )
        }

        return ICloudSyncResult(uploaded: uploaded, downloaded: downloaded, syncedAt: Date())
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

    private func fetchTextRecords() async throws -> [CKRecord] {
        let query = CKQuery(recordType: Schema.textRecordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        let firstPage = try await fetch(query: query)
        records.append(contentsOf: firstPage.records)
        var cursor = firstPage.cursor
        while let nextCursor = cursor {
            let page = try await fetch(cursor: nextCursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        }
        return records
    }

    private func fetch(query: CKQuery) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKQueryOperation(query: query)
            collect(operation: operation, continuation: continuation)
            database.add(operation)
        }
    }

    private func fetch(cursor: CKQueryOperation.Cursor) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKQueryOperation(cursor: cursor)
            collect(operation: operation, continuation: continuation)
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

    private func collect(
        operation: CKQueryOperation,
        continuation: CheckedContinuation<(records: [CKRecord], cursor: CKQueryOperation.Cursor?), Error>
    ) {
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
                continuation.resume(returning: (pageRecords, cursor))
            case .failure(let error):
                continuation.resume(throwing: error)
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
}
