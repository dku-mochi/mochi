import ComposableArchitecture
import Foundation

/// 가입 직후 노출되는 4단계 튜토리얼.
///
/// 시안 (`docs/UX_SPEC.md §3.3`) 의 4 페이지를 순서대로 보여주고, 마지막 페이지에서
/// 사용자가 "다음" 을 누르면 ``Delegate.finished`` 를 발행해 부모 (App 또는 RootFeature)
/// 가 메인 흐름으로 전이하도록 한다.
///
/// **백탭 페이지(마지막)는 단순 안내가 아니라 설정을 끝까지 끌고 가는 3-스텝 체크리스트다.**
/// 백탭은 모찌의 1순위 입력 경로(`PRODUCT.md §7`)인데, 단축어를 라이브러리에 추가하는 것과
/// 그 단축어를 *뒷면 탭에 연결* 하는 것은 분리된 두 행동이라, 어느 하나라도 빠지면 백탭이
/// 죽은 채 홈에 도착한다. 그래서:
///   ① 단축어 추가 → ② 뒷면 탭 연결(설정 가이드) → ③ **실제로 백탭이 도달하는지 검증**.
/// ①② 는 사용자 ack 로 진행하고(시스템이 import/바인딩 성공을 알려주는 API 가 없음),
/// 진짜 증명은 ③ 검증이 전담한다 — "떠올린다" 가 아니라 모찌가 "됐어요" 라고 떠올려 준다.
@Reducer
public struct OnboardingFeature: Sendable {

    public init() {}

    /// 백탭 검증 폴링 타임아웃. `AppGroup.backTapVerificationTTL`(120s) 보다 짧게 둬,
    /// 검증 창이 살아있는 동안 타임아웃 처리가 끝나게 한다. (모듈 경계로 상수는 복제)
    static let verificationTimeout: TimeInterval = 90

    @ObservableState
    public struct State: Equatable, Sendable {
        public var currentPage: Int
        /// 마지막 페이지의 CTA 가 눌리면 true. 부모 View 가 `onChange` 로 감시해
        /// 메인 흐름으로 전이한다.
        public var isFinished: Bool

        // MARK: 백탭 페이지(마지막) 3-스텝 체크리스트 상태
        /// ① "단축어를 추가했어요" ack.
        public var shortcutAdded: Bool
        /// ② "뒷면 탭에 연결했어요" ack.
        public var backTapBound: Bool
        /// ③ 백탭 실동작 검증 단계.
        public var verifyPhase: VerifyPhase
        /// ② 설정 경로 가이드 시트 표시 여부.
        public var showSettingsGuide: Bool

        public enum VerifyPhase: Equatable, Sendable {
            case idle       // 아직 시작 안 함
            case waiting    // "뒷면을 두 번 탭해보세요" — 폴링 중
            case detected   // 백탭이 intent 에 도달 — 성공
            case timedOut   // 제한 시간 내 미감지
            case skipped    // 사용자가 나중에 하기로
        }

        public init(
            currentPage: Int = 0,
            isFinished: Bool = false,
            shortcutAdded: Bool = false,
            backTapBound: Bool = false,
            verifyPhase: VerifyPhase = .idle,
            showSettingsGuide: Bool = false
        ) {
            self.currentPage = currentPage
            self.isFinished = isFinished
            self.shortcutAdded = shortcutAdded
            self.backTapBound = backTapBound
            self.verifyPhase = verifyPhase
            self.showSettingsGuide = showSettingsGuide
        }

        public var isLastPage: Bool { currentPage >= OnboardingPage.allCases.count - 1 }

        public var currentSpec: OnboardingPage { OnboardingPage.allCases[currentPage] }

        /// 백탭 페이지에서 "다음" 으로 넘어갈 자격 — 검증 성공 또는 사용자가 건너뜀.
        public var backTapStepResolved: Bool {
            verifyPhase == .detected || verifyPhase == .skipped
        }
    }

    public enum Action: Sendable {
        case nextTapped
        case pageChanged(Int)

        // 백탭 ① 단축어 추가
        /// 사용자가 "추가하기" → iCloud Shortcuts 링크를 갔다온 직후. View 가 openURL
        /// completion 에서 보낸다 (import 성공 여부는 시스템이 알려주지 않으므로 ③ 검증이 증명).
        case shortcutAddAcknowledged

        // 백탭 ② 뒷면 탭 연결
        /// "설정 열기" — 가이드 시트를 띄운다 (그 위에서 View 가 best-effort 딥링크 시도).
        case openSettingsTapped
        case settingsGuideDismissed
        /// "연결했어요" — 사용자 ack.
        case bindingAcknowledged

        // 백탭 ③ 검증
        /// "지금 해보세요" / 타임아웃 후 "다시 시도" — 검증 폴링 시작.
        case startVerificationTapped
        case verificationDidHit
        case verificationTimedOut
        /// "나중에 할게요" — 검증 건너뛰고 진행.
        case skipVerificationTapped
        /// 검증 성공/건너뜀 후 다음 페이지로.
        case backTapStepCompleted

        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case finished
        }
    }

    private enum CancelID { case verify }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            @Dependency(\.backTapVerification) var verification
            @Dependency(\.continuousClock) var clock

            switch action {
            case .nextTapped:
                // [P2] 백탭 페이지는 검증/skip 으로 해결되기 전엔 nextTapped 로 전진하지 않는다.
                // 정상 경로는 `backTapStepCompleted` 경유(resolved 보장)이고, 이 가드는 직접
                // 호출에 대한 reducer 자체 방어다.
                if state.currentSpec == .backTap && !state.backTapStepResolved {
                    return .none
                }
                if state.isLastPage {
                    state.isFinished = true
                    return .send(.delegate(.finished))
                }
                state.currentPage += 1
                return .none

            case let .pageChanged(index):
                let clamped = max(0, min(index, OnboardingPage.allCases.count - 1))
                let backTapIndex = OnboardingPage.backTap.rawValue
                // [P1] 백탭 미해결 시 전진 차단은 크로스페이드에 forward 스와이프 surface 가
                // 없다는 것 + `nextTapped`/`backTapStepCompleted` reducer 가드가 담당한다.
                // `pageChanged` 는 좌상단 back(직전 단계로만) 을 반영한다.
                // 검증 진행 중 백탭 페이지를 떠나면 폴링/창을 정리한다.
                let leavingMidVerify = state.currentPage == backTapIndex
                    && clamped != backTapIndex
                    && state.verifyPhase == .waiting
                state.currentPage = clamped
                if leavingMidVerify {
                    state.verifyPhase = .idle
                    verification.end()
                    return .cancel(id: CancelID.verify)
                }
                return .none

            case .shortcutAddAcknowledged:
                state.shortcutAdded = true
                return .none

            case .openSettingsTapped:
                // [P2] ① 단축어 추가 후에만 ② 연결 가이드를 연다.
                guard state.shortcutAdded else { return .none }
                state.showSettingsGuide = true
                return .none

            case .settingsGuideDismissed:
                state.showSettingsGuide = false
                return .none

            case .bindingAcknowledged:
                // [P2] ① 단축어 추가 후에만 ② 연결을 완료로 표시한다 (단계 순서 강제).
                guard state.shortcutAdded else { return .none }
                state.backTapBound = true
                state.showSettingsGuide = false  // 가이드 시트의 "연결했어요" 가 시트를 닫는다
                return .none

            case .startVerificationTapped:
                // [P2] reducer 가 자기 invariant 를 강제 — ② 연결 전엔 검증을 시작하지 않는다.
                guard state.backTapBound else { return .none }
                state.verifyPhase = .waiting
                verification.begin()
                return .merge(
                    .run { send in
                        // 0.5s 폴링. `clock.timer` 는 Clocks 모듈 의존이 필요하므로 표준
                        // `Clock.sleep` 루프로 대신한다 (의존성·공유표면 추가 회피). 취소 시
                        // sleep 이 CancellationError 를 던져 루프가 정상 종료된다.
                        while true {
                            try await clock.sleep(for: .milliseconds(500))
                            if verification.didHit() {
                                await send(.verificationDidHit)
                                return
                            }
                        }
                    },
                    .run { send in
                        try await clock.sleep(for: .seconds(Self.verificationTimeout))
                        await send(.verificationTimedOut)
                    }
                )
                .cancellable(id: CancelID.verify, cancelInFlight: true)

            case .verificationDidHit:
                // [P2] 취소 레이스 방지 — 대기 중일 때만 성공으로 전이한다 (타임아웃/이탈 후
                // 늦게 도착한 hit 이 detected 를 덮어쓰지 않게).
                guard state.verifyPhase == .waiting else { return .none }
                state.verifyPhase = .detected
                verification.end()
                return .cancel(id: CancelID.verify)

            case .verificationTimedOut:
                guard state.verifyPhase == .waiting else { return .none }
                state.verifyPhase = .timedOut
                verification.end()
                return .cancel(id: CancelID.verify)

            case .skipVerificationTapped:
                state.verifyPhase = .skipped
                verification.end()
                return .merge(
                    .cancel(id: CancelID.verify),
                    .send(.backTapStepCompleted)
                )

            case .backTapStepCompleted:
                // [P2] 검증 성공 또는 명시적 skip 으로 해결됐을 때만 전진한다.
                guard state.backTapStepResolved else { return .none }
                return .send(.nextTapped)

            case .delegate:
                return .none
            }
        }
    }
}
