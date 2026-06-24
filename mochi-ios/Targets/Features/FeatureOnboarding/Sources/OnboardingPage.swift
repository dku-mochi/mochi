import Foundation

/// 온보딩 4페이지의 데이터 정의.
///
/// 페이지 순서는 가치(저장·정리·회수)를 먼저 보여준 뒤 가장 무거운 설정(백탭)을 **맨 끝**에 둔다 —
/// 동기가 마찰보다 앞서게 하고, 마지막 단계라 "다음 페이지로의 전진 차단" 게이트가 자연히
/// "완료 vs 나중에" 선택으로 풀린다. 페이지 인덱스는 0-based 이며 ``OnboardingFeature.State.currentPage`` 와 1:1 매칭.
public enum OnboardingPage: Int, CaseIterable, Sendable {
    case intro
    case share
    case autoSort
    case backTap

    public var title: String {
        switch self {
        case .intro:
            return "남기는 건 한 번이면 돼요"
        case .share:
            return "다른 앱에서도\n공유 버튼으로 보내세요"
        case .autoSort:
            return "무엇을 저장하든\n알아서 정리해 둘게요"
        case .backTap:
            return "뒷면을 두 번 두드리면\n바로 저장돼요"
        }
    }

    /// 부제 (선택). intro·autoSort·backTap 페이지에서 보조 카피로 사용.
    public var subtitle: String? {
        switch self {
        case .intro:
            return "정리하고 꺼내두는 건 모찌가 할게요"
        case .share:
            return nil
        case .autoSort:
            return "필요할 때 바로 꺼내볼 수 있게요"
        case .backTap:
            return "한 번만 설정하면, 어디서든 가장 빠른 길이에요"
        }
    }

    /// 일반 페이지의 footer CTA. 백탭 페이지는 검증 상태에 따라 View 가 동적으로 라벨을
    /// 결정하므로 (`OnboardingView.footer`) 이 값은 fallback 으로만 쓰인다. 백탭은 마지막
    /// 페이지라 해결 시 CTA 가 "시작하기"(온보딩 완료)다.
    public var primaryCTA: String {
        switch self {
        case .intro, .share, .autoSort: return "다음"
        case .backTap: return "시작하기"
        }
    }
}
