import Foundation

/// 온보딩 5페이지의 데이터 정의.
///
/// 페이지 순서는 가치(저장·정리·회수)를 먼저 보여준 뒤 가장 무거운 설정(백탭)을 뒤에 두고,
/// **마지막에 동기화 선택(캘린더·미리알림 자동 등록)** 을 둔다 — 동기가 마찰보다 앞서게 하고,
/// 시스템 권한 프롬프트 2종이 뜨는 유일하게 무거운 동의를 피날레 한 곳에 모은다(2026-07-14).
/// 백탭 게이트("검증 성공 or 명시 스킵 전 전진 불가")는 리듀서 `pageChanged` 가드가 승계한다.
/// 페이지 인덱스는 0-based 이며 ``OnboardingFeature.State.currentPage`` 와 1:1 매칭.
public enum OnboardingPage: Int, CaseIterable, Sendable {
    case intro
    case share
    case autoSort
    case backTap
    case calendarSync

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
        case .calendarSync:
            return "일정은 캘린더에,\n할 일은 미리알림에"
        }
    }

    /// 부제 (선택). intro·autoSort·backTap·calendarSync 페이지에서 보조 카피로 사용.
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
        case .calendarSync:
            return "저장만 하면 모찌가 바로 등록해 둘게요"
        }
    }

    /// 일반 페이지의 footer CTA. 백탭 페이지는 검증 상태에 따라 View 가 동적으로 라벨을
    /// 결정하므로 (`OnboardingView.footer`) 이 값은 fallback 으로만 쓰인다.
    /// 동기화 선택이 마지막 페이지라 수락 CTA 가 곧 온보딩 완료로 이어진다.
    public var primaryCTA: String {
        switch self {
        case .intro, .share, .autoSort, .backTap: return "다음"
        case .calendarSync: return "자동으로 챙길게요"
        }
    }
}
