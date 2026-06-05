import Foundation
import CoreDomain

/// `MochiItemDTO`(분석 응답) → 도메인 `MochiItemAnalysis` 매핑 — **단일 원천**.
///
/// 폴링(`MochiItemSyncWorker.pollAnalysisOnce`)과 SSE(`LiveAgentStreamClient`)가 둘 다 `final`
/// 시점에 `GET /mochi_items/{id}` 응답을 분석 도메인으로 변환한다. 두 경로가 따로 매핑하면 계약이
/// 갈라지므로 여기 한 곳에 둔다. **`lifecycleKind == "analyzed"` 인 DTO 에만 의미가 있다**(호출부가 보장).
public extension MochiItemDTO {
    func toMochiItemAnalysis() -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: summary ?? "",
            instances: intentInstances.map { i in
                IntentInstance(
                    intentType: i.intentType,
                    payload: Self.payload(from: i.payload),
                    label: i.label,
                    reasoning: i.reasoning,
                    lifecycle: Self.instanceLifecycle(from: i.lifecycleKind)
                )
            },
            needsReview: needsReview,
            reviewOptions: reviewOptions.map {
                ReviewOption(intentType: $0.intentType, label: $0.label, reasoning: $0.reasoning)
            },
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: MochiItemAnalysis.Importance(rawValue: importance) ?? .medium,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date()
        )
    }

    private static func payload(from dto: IntentPayloadDTO?) -> IntentPayload {
        guard let dto else { return IntentPayload() }
        return IntentPayload(
            title: dto.title, date: dto.date, time: dto.time, deadline: dto.deadline,
            person: dto.person, topic: dto.topic, url: dto.url, note: dto.note
        )
    }

    /// 응답 instance 의 의미상태 문자열을 도메인으로. 새로 적재된 instance 는 대개 `active`.
    /// 응답엔 archive reason 이 없어 archived 는 `userManual` 로 기본 매핑(새 적재엔 거의 없음).
    private static func instanceLifecycle(from raw: String) -> InstanceLifecycle {
        switch raw {
        case "decaying":        return .decaying
        case "reviewRequested": return .reviewRequested
        case "archived":        return .archived(reason: .userManual)
        default:                return .active
        }
    }
}
