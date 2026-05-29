import Foundation

/// Gemini 멀티모달 분석 결과.
///
/// `confidence`는 0.0–1.0 범위, 사용자 메모 동반 시 백엔드에서 상향 보정.
public struct MochiItemAnalysis: Equatable, Sendable, Hashable, Codable {
    public let summary: String
    public let intent: Intent
    public let entities: [ExtractedEntity]
    public let actionCandidates: [ActionCandidate]
    public let tags: [String]
    public let importance: Importance
    public let confidence: Double
    public let modelVersion: String
    public let analyzedAt: Date

    public init(
        summary: String,
        intent: Intent,
        entities: [ExtractedEntity],
        actionCandidates: [ActionCandidate],
        tags: [String],
        importance: Importance,
        confidence: Double,
        modelVersion: String,
        analyzedAt: Date
    ) {
        self.summary = summary
        self.intent = intent
        self.entities = entities
        self.actionCandidates = actionCandidates
        self.tags = tags
        self.importance = importance
        self.confidence = confidence
        self.modelVersion = modelVersion
        self.analyzedAt = analyzedAt
    }

    public enum Importance: Int, Codable, Sendable, CaseIterable, Comparable {
        case low = 1
        case mediumLow = 2
        case medium = 3
        case mediumHigh = 4
        case high = 5

        public static func < (lhs: Importance, rhs: Importance) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Agent가 제안한 후속 액션 — 사용자 확인 후 실제 수행.
    public enum ActionCandidate: Equatable, Sendable, Hashable, Codable {
        case createCalendarEvent(title: String, startISO8601: String, endISO8601: String?)
        case createReminder(title: String, dueISO8601: String?)
        case openURL(URL)
        case followUpSearch(query: String)
    }
}
