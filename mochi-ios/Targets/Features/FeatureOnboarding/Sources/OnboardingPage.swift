import Foundation

/// 온보딩 4페이지의 데이터 정의.
///
/// 카피는 시안 (`docs/UX_SPEC.md §3.3` + 디자인 mockup) 그대로 유지한다.
/// 페이지 인덱스는 0-based 이며 ``OnboardingFeature.State.currentPage`` 와 1:1 매칭.
public enum OnboardingPage: Int, CaseIterable, Sendable {
    case intro
    case backTap
    case share
    case autoSort

    public var title: String {
        switch self {
        case .intro:
            return "안녕하세요!\n만나서 반가워요."
        case .backTap:
            return "뒷면을 두 번 탭하면\n제가 나타날게요"
        case .share:
            return "공유 버튼으로도\n저장할 수 있어요!"
        case .autoSort:
            return "뭐든지 캡처만 하면\n제가 정리해드릴게요!"
        }
    }

    /// 부제 (선택). intro·backTap·autoSort 페이지에서 보조 카피로 사용.
    public var subtitle: String? {
        switch self {
        case .intro:
            return "제 이름은 모찌예요 😊"
        case .backTap:
            return "단축어를 추가하고 연결하면 끝나요"
        case .share:
            return nil
        case .autoSort:
            return "일정, 할 일, 지식, 기록으로\n자동으로 분류할게요."
        }
    }

    /// 일반 페이지의 footer CTA. 백탭 페이지는 검증 상태에 따라 View 가 동적으로 라벨을
    /// 결정하므로 (`OnboardingView.footer`) 이 값은 fallback 으로만 쓰인다.
    public var primaryCTA: String {
        switch self {
        case .intro, .share, .autoSort: return "다음"
        case .backTap: return "다음"
        }
    }
}
