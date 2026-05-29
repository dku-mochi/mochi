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
        row.intentRawValue = mochiItem.analysis?.intent.rawValue
        row.summary = mochiItem.analysis?.summary
        row.importance = mochiItem.analysis?.importance.rawValue ?? 3
        row.confidence = mochiItem.analysis?.confidence ?? 0
        row.modelVersion = mochiItem.analysis?.modelVersion
        row.lifecycleStateRawValue = lifecycleStateRaw(mochiItem.lifecycleState)
        row.syncStateRawValue = syncStateRaw(mochiItem.syncState)
        row.capturedAt = mochiItem.source.capturedAt
        row.analyzedAt = mochiItem.analysis?.analyzedAt
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

        row.intentCandidates.removeAll()
        for candidate in mochiItem.analysis?.candidates ?? [] {
            row.intentCandidates.append(encode(intentCandidate: candidate))
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
        if let intentRaw = row.intentRawValue,
           let intent = Intent(rawValue: intentRaw),
           let analyzedAt = row.analyzedAt {
            analysis = MochiItemAnalysis(
                summary: row.summary ?? "",
                intent: intent,
                entities: row.entities.compactMap(decode(entity:)),
                actionCandidates: row.actionCandidates.compactMap(decode(actionCandidate:)),
                tags: Array(row.tags),
                importance: MochiItemAnalysis.Importance(rawValue: row.importance) ?? .medium,
                confidence: row.confidence,
                modelVersion: row.modelVersion ?? "unknown",
                analyzedAt: analyzedAt,
                candidates: row.intentCandidates.compactMap(decode(intentCandidate:))
            )
        }

        return MochiItem(
            source: source,
            analysis: analysis,
            lifecycleState: lifecycleState(from: row),
            syncState: syncStateFromRaw(row.syncStateRawValue),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    public static func lifecycleState(from row: RealmMochiItem) -> LifecycleState {
        return decodeLifecycle(raw: row.lifecycleStateRawValue) ?? .ingested
    }

    public static func apply(lifecycleState: LifecycleState, to row: RealmMochiItem) {
        row.lifecycleStateRawValue = lifecycleStateRaw(lifecycleState)
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

    // MARK: - IntentCandidate encoding

    private static func encode(intentCandidate: IntentCandidate) -> RealmIntentCandidate {
        let row = RealmIntentCandidate()
        row.label = intentCandidate.label
        row.intentRawValue = intentCandidate.intent.rawValue
        row.applicability = intentCandidate.applicability
        return row
    }

    private static func decode(intentCandidate row: RealmIntentCandidate) -> IntentCandidate? {
        guard let intent = Intent(rawValue: row.intentRawValue) else { return nil }
        return IntentCandidate(label: row.label, intent: intent, applicability: row.applicability)
    }

    // MARK: - Lifecycle / Sync raw encoding

    static func lifecycleStateRaw(_ state: LifecycleState) -> String {
        switch state {
        case .ingested:                       return "ingested"
        case .analyzing:                      return "analyzing"
        case .active:                         return "active"
        case .decaying:                       return "decaying"
        case .reviewRequested:                return "reviewRequested"
        case let .archived(reason):           return "archived:\(reason.rawValue)"
        case let .failed(reason):             return "failed:\(reason)"
        }
    }

    private static func decodeLifecycle(raw: String) -> LifecycleState? {
        switch raw {
        case "ingested":        return .ingested
        case "analyzing":       return .analyzing
        case "active":          return .active
        case "decaying":        return .decaying
        case "reviewRequested": return .reviewRequested
        default:
            if let archivedRange = raw.range(of: "archived:") {
                let reasonRaw = String(raw[archivedRange.upperBound...])
                if let reason = LifecycleState.ArchiveReason(rawValue: reasonRaw) {
                    return .archived(reason: reason)
                }
            }
            if let failedRange = raw.range(of: "failed:") {
                return .failed(reason: String(raw[failedRange.upperBound...]))
            }
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
