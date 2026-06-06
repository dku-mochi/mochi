import Foundation
import RealmSwift
import CoreDomain

/// 도메인 ``MochiItem`` ↔ ``RealmMochiItem`` 의 명시적 매핑.
///
/// **무손실(round-trip) 매핑**을 보장한다: read → toRealm → toDomain 했을 때
/// entities · actionCandidates · imageRefs · syncState 의 detail 까지 복원되어야 한다.
public enum RealmMochiItemMapper {

    // MARK: - Domain → Realm

    public static func toRealm(_ mochiItem: MochiItem) -> RealmMochiItem {
        let row = RealmMochiItem()
        row.id = mochiItem.id.uuidString
        row.channelRawValue = mochiItem.source.channel.rawValue
        row.urlString = mochiItem.source.url?.absoluteString
        row.text = mochiItem.source.text
        row.userMemo = mochiItem.source.userMemo
        row.summary = mochiItem.analysis?.summary
        row.importance = mochiItem.analysis?.importance.rawValue ?? 3
        row.needsReview = mochiItem.analysis?.needsReview ?? false
        row.modelVersion = mochiItem.analysis?.modelVersion
        row.lifecycleStateRawValue = lifecycleStateRaw(mochiItem.lifecycleState)
        row.syncStateRawValue = syncStateRaw(mochiItem.syncState)
        row.capturedAt = mochiItem.source.capturedAt
        row.analyzedAt = mochiItem.analysis?.analyzedAt
        row.userTitle = mochiItem.userTitle
        row.createdAt = mochiItem.createdAt
        row.updatedAt = mochiItem.updatedAt

        row.imageRefs.removeAll()
        for ref in mochiItem.source.imageRefs {
            let imgRow = RealmImageRef()
            imgRow.id = ref.id.uuidString
            imgRow.relativePath = ref.relativePath
            imgRow.mimeType = ref.mimeType
            imgRow.byteSize = ref.byteSize
            imgRow.sha256 = ref.sha256
            imgRow.objectKey = ref.objectKey
            row.imageRefs.append(imgRow)
        }

        row.entities.removeAll()
        for entity in mochiItem.analysis?.entities ?? [] {
            row.entities.append(encode(entity: entity))
        }

        row.actionCandidates.removeAll()
        for candidate in mochiItem.analysis?.actionCandidates ?? [] {
            row.actionCandidates.append(encode(actionCandidate: candidate))
        }

        row.tags.removeAll()
        for tag in mochiItem.analysis?.tags ?? [] {
            row.tags.append(tag)
        }

        row.intentInstances.removeAll()
        for instance in mochiItem.analysis?.instances ?? [] {
            row.intentInstances.append(encode(intentInstance: instance))
        }

        row.reviewOptions.removeAll()
        for option in mochiItem.analysis?.reviewOptions ?? [] {
            row.reviewOptions.append(encode(reviewOption: option))
        }
        return row
    }

    // MARK: - Realm → Domain

    public static func toDomain(_ row: RealmMochiItem) -> MochiItem {
        let source = IngestSource(
            id: UUID(uuidString: row.id) ?? UUID(),
            channel: IngestChannel(rawValue: row.channelRawValue) ?? .unknown,
            url: row.urlString.flatMap(URL.init(string:)),
            text: row.text,
            imageRefs: row.imageRefs.map(decode(imageRef:)),
            userMemo: row.userMemo,
            capturedAt: row.capturedAt
        )

        var analysis: MochiItemAnalysis?
        if let analyzedAt = row.analyzedAt {
            analysis = MochiItemAnalysis(
                summary: row.summary ?? "",
                instances: row.intentInstances.compactMap(decode(intentInstance:)),
                needsReview: row.needsReview,
                reviewOptions: row.reviewOptions.compactMap(decode(reviewOption:)),
                entities: row.entities.compactMap(decode(entity:)),
                actionCandidates: row.actionCandidates.compactMap(decode(actionCandidate:)),
                tags: Array(row.tags),
                importance: MochiItemAnalysis.Importance(rawValue: row.importance) ?? .medium,
                modelVersion: row.modelVersion ?? "unknown",
                analyzedAt: analyzedAt
            )
        }

        return MochiItem(
            source: source,
            analysis: analysis,
            lifecycleState: lifecycleState(from: row),
            syncState: syncStateFromRaw(row.syncStateRawValue),
            userTitle: row.userTitle,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    public static func lifecycleState(from row: RealmMochiItem) -> ProcessingState {
        return decodeLifecycle(raw: row.lifecycleStateRawValue) ?? .ingested
    }

    public static func apply(lifecycleState: ProcessingState, to row: RealmMochiItem) {
        row.lifecycleStateRawValue = lifecycleStateRaw(lifecycleState)
    }

    public static func instanceLifecycle(from row: RealmIntentInstance) -> InstanceLifecycle? {
        decodeInstanceLifecycle(kind: row.lifecycleKindRawValue, reason: row.archiveReasonRawValue)
    }

    public static func apply(instanceLifecycle: InstanceLifecycle, to row: RealmIntentInstance) {
        let encoded = encodeInstanceLifecycle(instanceLifecycle)
        row.lifecycleKindRawValue = encoded.kind
        row.archiveReasonRawValue = encoded.reason
    }

    // MARK: - Entity encoding

    private static func encode(entity: ExtractedEntity) -> RealmExtractedEntity {
        let row = RealmExtractedEntity()
        row.kindRawValue = entity.kind.rawValue
        row.value = entity.value
        switch entity.provenance {
        case let .textRange(start, end):
            row.provenanceKind = "textRange"
            row.textRangeStart = start
            row.textRangeEnd = end
        case let .ocrBoundingBox(x, y, w, h):
            row.provenanceKind = "ocrBox"
            row.ocrX = x; row.ocrY = y; row.ocrWidth = w; row.ocrHeight = h
        case .none:
            row.provenanceKind = ""
        }
        return row
    }

    private static func decode(entity row: RealmExtractedEntity) -> ExtractedEntity? {
        guard let kind = ExtractedEntity.Kind(rawValue: row.kindRawValue) else { return nil }
        let provenance: ExtractedEntity.Provenance?
        switch row.provenanceKind {
        case "textRange":
            if let s = row.textRangeStart, let e = row.textRangeEnd {
                provenance = .textRange(start: s, end: e)
            } else { provenance = nil }
        case "ocrBox":
            if let x = row.ocrX, let y = row.ocrY, let w = row.ocrWidth, let h = row.ocrHeight {
                provenance = .ocrBoundingBox(x: x, y: y, width: w, height: h)
            } else { provenance = nil }
        default:
            provenance = nil
        }
        return ExtractedEntity(kind: kind, value: row.value, provenance: provenance)
    }

    // MARK: - ImageRef encoding

    private static func decode(imageRef row: RealmImageRef) -> ImageRef {
        return ImageRef(
            id: UUID(uuidString: row.id) ?? UUID(),
            relativePath: row.relativePath,
            mimeType: row.mimeType,
            byteSize: row.byteSize,
            sha256: row.sha256,
            objectKey: row.objectKey
        )
    }

    // MARK: - ActionCandidate encoding

    private static func encode(actionCandidate: MochiItemAnalysis.ActionCandidate) -> RealmActionCandidate {
        let row = RealmActionCandidate()
        switch actionCandidate {
        case let .createCalendarEvent(title, start, end):
            row.kind = "calendar"
            row.title = title
            row.startISO8601 = start
            row.endISO8601 = end
        case let .createReminder(title, due):
            row.kind = "reminder"
            row.title = title
            row.startISO8601 = due
        case let .openURL(url):
            row.kind = "openURL"
            row.urlString = url.absoluteString
        case let .followUpSearch(query):
            row.kind = "followUp"
            row.query = query
        }
        return row
    }

    private static func decode(actionCandidate row: RealmActionCandidate) -> MochiItemAnalysis.ActionCandidate? {
        switch row.kind {
        case "calendar":
            guard let title = row.title, let start = row.startISO8601 else { return nil }
            return .createCalendarEvent(title: title, startISO8601: start, endISO8601: row.endISO8601)
        case "reminder":
            guard let title = row.title else { return nil }
            return .createReminder(title: title, dueISO8601: row.startISO8601)
        case "openURL":
            guard let str = row.urlString, let url = URL(string: str) else { return nil }
            return .openURL(url)
        case "followUp":
            guard let q = row.query else { return nil }
            return .followUpSearch(query: q)
        default:
            return nil
        }
    }

    // MARK: - IntentInstance / ReviewOption encoding

    private static func encode(intentInstance instance: IntentInstance) -> RealmIntentInstance {
        let row = RealmIntentInstance()
        row.instanceID = instance.id.uuidString
        row.intentRawValue = instance.intentType.rawValue
        row.label = instance.label
        row.reasoning = instance.reasoning
        let encoded = encodeInstanceLifecycle(instance.lifecycle)
        row.lifecycleKindRawValue = encoded.kind
        row.archiveReasonRawValue = encoded.reason
        row.payloadTitle = instance.payload.title
        row.payloadDate = instance.payload.date
        row.payloadTime = instance.payload.time
        row.payloadDeadline = instance.payload.deadline
        row.payloadPerson = instance.payload.person
        row.payloadTopic = instance.payload.topic
        row.payloadURL = instance.payload.url
        row.payloadNote = instance.payload.note
        return row
    }

    private static func decode(intentInstance row: RealmIntentInstance) -> IntentInstance? {
        guard let intent = Intent(rawValue: row.intentRawValue),
              let lifecycle = decodeInstanceLifecycle(kind: row.lifecycleKindRawValue, reason: row.archiveReasonRawValue)
        else { return nil }
        let payload = IntentPayload(
            title: row.payloadTitle,
            date: row.payloadDate,
            time: row.payloadTime,
            deadline: row.payloadDeadline,
            person: row.payloadPerson,
            topic: row.payloadTopic,
            url: row.payloadURL,
            note: row.payloadNote
        )
        return IntentInstance(
            id: UUID(uuidString: row.instanceID) ?? UUID(),
            intentType: intent,
            payload: payload,
            label: row.label,
            reasoning: row.reasoning,
            lifecycle: lifecycle
        )
    }

    private static func encode(reviewOption option: ReviewOption) -> RealmReviewOption {
        let row = RealmReviewOption()
        row.intentRawValue = option.intentType.rawValue
        row.label = option.label
        row.reasoning = option.reasoning
        return row
    }

    private static func decode(reviewOption row: RealmReviewOption) -> ReviewOption? {
        guard let intent = Intent(rawValue: row.intentRawValue) else { return nil }
        return ReviewOption(intentType: intent, label: row.label, reasoning: row.reasoning)
    }

    private static func encodeInstanceLifecycle(_ lifecycle: InstanceLifecycle) -> (kind: String, reason: String?) {
        switch lifecycle {
        case .active:               return ("active", nil)
        case .decaying:             return ("decaying", nil)
        case .reviewRequested:      return ("reviewRequested", nil)
        case let .archived(reason): return ("archived", reason.rawValue)
        }
    }

    private static func decodeInstanceLifecycle(kind: String, reason: String?) -> InstanceLifecycle? {
        switch kind {
        case "active":          return .active
        case "decaying":        return .decaying
        case "reviewRequested": return .reviewRequested
        case "archived":
            guard let reason, let r = InstanceLifecycle.ArchiveReason(rawValue: reason) else { return nil }
            return .archived(reason: r)
        default:
            return nil
        }
    }

    // MARK: - Lifecycle / Sync raw encoding

    static func lifecycleStateRaw(_ state: ProcessingState) -> String {
        switch state {
        case .ingested:           return "ingested"
        case .analyzing:          return "analyzing"
        case .analyzed:           return "analyzed"
        case let .failed(reason): return "failed:\(reason)"
        }
    }

    private static func decodeLifecycle(raw: String) -> ProcessingState? {
        switch raw {
        case "ingested":  return .ingested
        case "analyzing": return .analyzing
        case "analyzed":  return .analyzed
        default:
            if let failedRange = raw.range(of: "failed:") {
                return .failed(reason: String(raw[failedRange.upperBound...]))
            }
            // 구 의미상태(active/decaying/...)는 v5 재생성(deleteRealmIfMigrationNeeded)으로 폐기 — 만날 일 없음.
            return nil
        }
    }

    static func syncStateRaw(_ state: SyncState) -> String {
        switch state {
        case .pendingUpload:                            return "pendingUpload"
        case .uploading:                                return "uploading"
        case let .uploaded(serverID, at):               return "uploaded:\(serverID.uuidString):\(at.timeIntervalSince1970)"
        case let .calendarSynced(identifier):           return "calendarSynced:\(identifier)"
        case let .reminderSynced(identifier):           return "reminderSynced:\(identifier)"
        case let .syncFailed(reason, retryAfter):
            let ts = retryAfter.map { String($0.timeIntervalSince1970) } ?? ""
            return "syncFailed:\(ts):\(reason)"
        }
    }

    private static func syncStateFromRaw(_ raw: String) -> SyncState {
        if raw == "pendingUpload" { return .pendingUpload }
        if raw == "uploading"     { return .uploading }
        if let range = raw.range(of: "uploaded:") {
            let rest = raw[range.upperBound...]
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let serverID = UUID(uuidString: String(parts[0])),
               let ts = TimeInterval(parts[1]) {
                return .uploaded(serverID: serverID, at: Date(timeIntervalSince1970: ts))
            }
        }
        if let range = raw.range(of: "calendarSynced:") {
            return .calendarSynced(eventIdentifier: String(raw[range.upperBound...]))
        }
        if let range = raw.range(of: "reminderSynced:") {
            return .reminderSynced(reminderIdentifier: String(raw[range.upperBound...]))
        }
        if let range = raw.range(of: "syncFailed:") {
            let rest = raw[range.upperBound...]
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let retryAfter = TimeInterval(parts[0]).map { Date(timeIntervalSince1970: $0) }
                return .syncFailed(reason: String(parts[1]), retryAfter: retryAfter)
            }
        }
        return .pendingUpload
    }
}
