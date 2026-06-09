import ActivityKit
import Foundation

/// 캡처 → 분석 → 결과/선택 흐름의 Live Activity attributes.
///
/// App 타겟에서 `Activity<MochiLiveActivityAttributes>.request(...)` 로 시작하고,
/// `MochiWidgets` 확장이 이 attributes 의 type identity 를 공유해 Lock Screen / Dynamic
/// Island UI 를 렌더한다.
///
/// **content-state 계약**: ``ContentState`` 의 필드는 백엔드 LA push payload 의 `aps.content-state`
/// (notifications 모듈 `_build_live_activity`) 와 **정확히 일치**해야 한다. background LA 갱신은
/// 시스템이 push payload 를 ``ContentState`` 로 직접 decode 하므로, 키가 어긋나면 갱신이 무음 실패한다.
/// camelCase(`needsReview`/`intentType`)로 통일 — 백엔드도 camelCase 로 보낸다.
///
/// **4KB 한도**: ActivityKit 의 attributes + ContentState 합쳐 4KB 이내. 썸네일은 payload 가 아니라
/// 디스크(App Group)에서 직접 읽으므로 한도에 안 잡힌다 — 후보 3개 + 짧은 reasoning 이면 여유.
public struct MochiLiveActivityAttributes: ActivityAttributes {
    /// 분석 진행 / 완료 / 사용자 선택 단계별 상태. 백엔드 push 와 키 일치.
    public struct ContentState: Codable, Hashable {
        public var phase: Phase
        /// 모찌가 분류를 확신 못 해 후보 선택을 요청하는지 — 백엔드 `needs_review` 미러.
        public var needsReview: Bool
        /// 1줄 요약 ("이렇게 저장했어요 — …" / 헷갈려요 본문).
        public var summary: String
        public var candidates: [Candidate]
        /// 로컬 선택 상태 — 백엔드 push payload 엔 없다. 합성 Codable 이 missing key 를 nil 로 decode.
        public var selectedLabel: String?

        public init(
            phase: Phase,
            needsReview: Bool = false,
            summary: String = "",
            candidates: [Candidate] = [],
            selectedLabel: String? = nil
        ) {
            self.phase = phase
            self.needsReview = needsReview
            self.summary = summary
            self.candidates = candidates
            self.selectedLabel = selectedLabel
        }
    }

    /// LA phase. 모찌는 needs_review=true 분석완료에서만 LA 를 띄운다(팀 결정 2026-06-09) —
    /// 백엔드 push-to-start 가 `ready` 로 시작하고, 사용자가 후보를 고르면 로컬에서 `confirmed` 로 전이.
    /// (구 `analyzing`/완료 표시 phase 는 폐기 — 진행중/완료 LA 제거.)
    public enum Phase: String, Codable, Hashable {
        case ready      // 백엔드 push-to-start 로 시작 — needsReview 후보 선택 대기
        case confirmed  // 사용자가 후보 선택 완료(로컬) — 잠시 후 dismiss
    }

    /// 헷갈려요 후보 한 건. 백엔드 `review_options` 직렬화와 키 일치(`intentType`/`label`/`reasoning`).
    ///
    /// **non-null 계약**: `label`/`reasoning` 은 비옵셔널이다 — push payload 에 null 이 오면 시스템의
    /// content-state 자동 decode 가 throw 해 background LA 갱신이 무음 드롭된다. 백엔드
    /// `_build_live_activity` 가 `label = r.label or r.intent_type.value` 로 non-null 을 보장한다.
    public struct Candidate: Codable, Hashable, Identifiable {
        public var id: String { label }
        public var intentType: String       // schedule / todo / knowledge / memo
        public var label: String
        public var reasoning: String        // 구 applicability(점수) 대체 — 2026-06-04 빅뱅으로 점수 폐기

        public init(intentType: String, label: String, reasoning: String) {
            self.intentType = intentType
            self.label = label
            self.reasoning = reasoning
        }
    }

    /// 이 Activity 가 점유하는 mochiItem 의 로컬 식별자 — `findActivity(for:)` 정확 매칭의 1급 키.
    /// (구 `captureCaption` 8-char prefix hack 대체.)
    public var mochiItemID: UUID

    /// Activity 식별용 짧은 캡션. Lock Screen 헤더에 표시.
    public var captureCaption: String

    /// App Group container 기준 상대 경로 (예: `captures/<filename>.png`). 좌측 column 의
    /// 썸네일 렌더에 사용. nil 이면 placeholder. 디스크에서 직접 읽으므로 4KB payload 한도 안 거침.
    public var thumbnailRelativePath: String?

    public init(mochiItemID: UUID, captureCaption: String, thumbnailRelativePath: String? = nil) {
        self.mochiItemID = mochiItemID
        self.captureCaption = captureCaption
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}
