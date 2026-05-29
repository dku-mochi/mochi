import Foundation
import RealmSwift

/// Realm 1급 객체. 도메인 객체 ``MochiItem`` 와 동치이지만 Realm 직렬화에 맞춰 평탄화.
///
/// Mapper(`RealmMochiItemMapper`)가 양방향 변환을 책임진다.
public final class RealmMochiItem: Object, Identifiable {
    @Persisted(primaryKey: true) public var id: String
    @Persisted public var channelRawValue: String
    @Persisted public var urlString: String?
    @Persisted public var text: String?
    @Persisted public var userMemo: String?
    @Persisted public var lifecycleStateRawValue: String
    @Persisted public var syncStateRawValue: String
    @Persisted public var intentRawValue: String?
    @Persisted public var summary: String?
    @Persisted public var importance: Int = 3
    @Persisted public var confidence: Double = 0
    @Persisted public var modelVersion: String?
    @Persisted public var capturedAt: Date
    @Persisted public var analyzedAt: Date?
    @Persisted public var createdAt: Date
    @Persisted public var updatedAt: Date

    /// LLM 의도 후보 (헷갈려요 카드 버튼·복수 의도 derive 의 원천). 미분석/단일확신 시 비어 있을 수 있다.
    @Persisted public var intentCandidates: List<RealmIntentCandidate>

    @Persisted public var imageRefs: List<RealmImageRef>
    @Persisted public var entities: List<RealmExtractedEntity>
    @Persisted public var tags: List<String>
    @Persisted public var actionCandidates: List<RealmActionCandidate>

    public override class func primaryKey() -> String? { "id" }
}

public final class RealmIntentCandidate: EmbeddedObject {
    @Persisted public var label: String?
    @Persisted public var intentRawValue: String
    @Persisted public var applicability: Double
}

public final class RealmImageRef: EmbeddedObject {
    @Persisted public var id: String
    @Persisted public var relativePath: String
    @Persisted public var mimeType: String
    @Persisted public var byteSize: Int
    @Persisted public var sha256: String
    @Persisted public var objectKey: String?
}

public final class RealmExtractedEntity: EmbeddedObject {
    @Persisted public var kindRawValue: String
    @Persisted public var value: String
    /// "textRange" | "ocrBox" | "" (empty when no provenance)
    @Persisted public var provenanceKind: String = ""
    @Persisted public var textRangeStart: Int?
    @Persisted public var textRangeEnd: Int?
    @Persisted public var ocrX: Double?
    @Persisted public var ocrY: Double?
    @Persisted public var ocrWidth: Double?
    @Persisted public var ocrHeight: Double?
}

public final class RealmActionCandidate: EmbeddedObject {
    /// "calendar" | "reminder" | "openURL" | "followUp"
    @Persisted public var kind: String
    @Persisted public var title: String?
    @Persisted public var startISO8601: String?
    @Persisted public var endISO8601: String?
    @Persisted public var urlString: String?
    @Persisted public var query: String?
}
