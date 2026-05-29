import ActivityKit
import Foundation

/// 백탭 캡쳐 → use case 분석 → 결과 선택 흐름의 Live Activity attributes.
///
/// App 타겟에서 `Activity<MockUseCaseActivityAttributes>.request(...)` 로 시작하고,
/// `MochiWidgets` 확장이 이 attributes 의 type identity 를 공유해 Lock Screen / Dynamic
/// Island UI 를 렌더한다.
///
/// **prototype 한정**: 본 attributes 는 mock 흐름 ("앱 launch → 10초 후 결과") 만
/// 표현한다. production 에는 실제 캡쳐 ID, 백엔드 분석 상태, 타임스탬프 등으로 확장된다.
///
/// **4KB 한도**: ActivityKit 의 attributes + ContentState 합쳐 4KB 이내. 본 prototype 은
/// 후보 3개 + thumbnail 미참조라 100B 수준으로 여유.
public struct MockUseCaseActivityAttributes: ActivityAttributes {
    /// 분석 진행 / 완료 / 사용자 선택 단계별 상태.
    public struct ContentState: Codable, Hashable {
        public var phase: Phase
        public var candidates: [Candidate]
        public var selectedLabel: String?

        public init(phase: Phase, candidates: [Candidate], selectedLabel: String? = nil) {
            self.phase = phase
            self.candidates = candidates
            self.selectedLabel = selectedLabel
        }
    }

    /// 분석 흐름의 phase. UI 가 phase 별로 다르게 표현한다.
    public enum Phase: String, Codable, Hashable {
        case analyzing  // 분석 중 (spinner)
        case ready      // 결과 도착 — 후보 노출 (사용자 선택 대기)
        case confirmed  // 사용자가 선택 완료 — 잠시 후 dismiss
    }

    /// LLM 출력의 use case 후보. `lab/intent_v6_compressed_results.json` schema 와 동일.
    public struct Candidate: Codable, Hashable, Identifiable {
        public var id: String { label }
        public var label: String
        public var intent: String       // schedule / todo / knowledge / memo
        public var applicability: Double

        public init(label: String, intent: String, applicability: Double) {
            self.label = label
            self.intent = intent
            self.applicability = applicability
        }
    }

    /// Activity 식별용 짧은 캡션. Lock Screen 헤더에 표시.
    public var captureCaption: String

    /// App Group container 기준 상대 경로 (예: `captures/<filename>.png`). 좌측 column 의
    /// 스크린샷 썸네일 렌더에 사용. nil 이면 placeholder. 디스크에서 직접 읽으므로 4KB payload 한도 안 거침.
    public var thumbnailRelativePath: String?

    public init(captureCaption: String, thumbnailRelativePath: String? = nil) {
        self.captureCaption = captureCaption
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}
