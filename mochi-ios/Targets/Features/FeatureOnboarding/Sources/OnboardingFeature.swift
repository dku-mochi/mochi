import ComposableArchitecture
import CoreIntegrations
import CorePersistence
import Foundation

/// 가입 직후 노출되는 5단계 튜토리얼.
///
/// 시안 (`docs/UX_SPEC.md §3.3`) 의 5 페이지를 순서대로 보여주고, 마지막 페이지(동기화 선택)의
/// CTA 로 ``Delegate.finished`` 를 발행해 부모 (App 또는 RootFeature) 가 메인 흐름으로 전이한다.
///
/// **동기화 선택(마지막, 2026-07-14)**: 캘린더·미리알림 자동 등록(`SystemCalendarSyncEngine`,
/// UX_SPEC §1.5)을 켤지 여기서 묻는다 — EK 권한 2종(이벤트/미리알림은 iOS 17+ 별개 권한)이
/// 한꺼번에 뜨는 유일한 온보딩 지점이라, 수락 시 하나라도 허용되면 로컬 밸브를 on(허용된 쪽만
/// 엔진이 동작), 전부 거부면 off + 안내. "나중에" 는 off — 설정 §3.4d 토글로 언제든 켠다.
/// 기존 유저(온보딩 기완료)는 이 페이지를 지나지 않으므로 현행 기본 on 이 그대로 유지된다.
///
/// **백탭 페이지(④)는 단순 안내가 아니라 설정을 끝까지 끌고 가는 3-스텝 체크리스트다.**
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

        // MARK: 동기화 선택 페이지(마지막) 상태
        /// 캘린더·미리알림 자동 등록 선택 단계.
        public var calendarSyncPhase: CalendarSyncPhase

        public enum CalendarSyncPhase: Equatable, Sendable {
            case idle        // 선택 대기
            case requesting  // EK 권한 프롬프트 진행 중 — CTA 재진입 차단
            case denied      // 둘 다 거부 — 안내 노출 후 "시작하기"로 종료
        }

        public init(
            currentPage: Int = 0,
            isFinished: Bool = false,
            shortcutAdded: Bool = false,
            backTapBound: Bool = false,
            verifyPhase: VerifyPhase = .idle,
            showSettingsGuide: Bool = false,
            calendarSyncPhase: CalendarSyncPhase = .idle
        ) {
            self.currentPage = currentPage
            self.isFinished = isFinished
            self.shortcutAdded = shortcutAdded
            self.backTapBound = backTapBound
            self.verifyPhase = verifyPhase
            self.showSettingsGuide = showSettingsGuide
            self.calendarSyncPhase = calendarSyncPhase
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

        // 동기화 선택(마지막 페이지)
        /// "자동으로 챙길게요" — EK 권한 2종을 각각 요청하고 결과로 분기한다.
        case calendarSyncAccepted
        case calendarSyncPermissionsResolved(eventGranted: Bool, reminderGranted: Bool)
        /// "나중에 할게요" — 자동 등록 off 로 두고 온보딩 종료 (설정 §3.4d 토글로 언제든 on).
        case calendarSyncDeclined

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
                // [P1] 게이트 승계(2026-07-14, 5페이지 확장): 백탭이 마지막 페이지였을 땐 "그 뒤에
                // 페이지가 없다"는 사실이 forward 스와이프 게이트를 대신했지만, 동기화 선택이 뒤에
                // 붙으면서 그 성질이 사라졌다 — 미해결 상태로 **백탭 경계를 넘는 전진**은 출발
                // 페이지와 무관하게 reducer 가 차단한다(검증 성공 or 명시 스킵 전엔 전진 불가 불변식.
                // View rubber-band 도 동일 방향 저항. 경계 기준이라 앞 페이지發 건너뛰기도 막힘 — codex P2).
                if !state.backTapStepResolved, state.currentPage <= backTapIndex, clamped > backTapIndex {
                    return .none
                }
                // 동기화 선택의 권한 프롬프트 진행 중엔 페이지 이동을 잠근다 — resolved 액션이
                // 다른 페이지 위에서 완료를 밀어붙이는 경합을 원천 차단(codex P2).
                if state.currentSpec == .calendarSync, state.calendarSyncPhase == .requesting {
                    return .none
                }
                // 검증 진행 중 백탭 페이지를 떠나면(뒤로) 폴링/창을 정리한다.
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

            case .calendarSyncAccepted:
                @Dependency(\.calendarSyncer) var calendarSyncer
                // [P2] 마지막 페이지에서만 + 프롬프트 진행 중 재진입 차단.
                guard state.currentSpec == .calendarSync, state.calendarSyncPhase != .requesting
                else { return .none }
                state.calendarSyncPhase = .requesting
                return .run { send in
                    // 이벤트/미리알림은 iOS 17+ 별개 권한 — **각각** 요청한다(한쪽만 허용도 유효).
                    // 이미 결정된 권한은 프롬프트 없이 즉시 반환되므로 재진입(다시 보기)에도 안전.
                    let eventGranted = (try? await calendarSyncer.requestEventAccess()) != nil
                    let reminderGranted = (try? await calendarSyncer.requestReminderAccess()) != nil
                    await send(.calendarSyncPermissionsResolved(
                        eventGranted: eventGranted, reminderGranted: reminderGranted
                    ))
                }

            case let .calendarSyncPermissionsResolved(eventGranted, reminderGranted):
                @Dependency(\.systemCalendarSyncEngine) var calendarSyncEngine
                guard state.calendarSyncPhase == .requesting else { return .none }
                if eventGranted || reminderGranted {
                    // 일부만 허용돼도 on — 엔진이 kind 별 권한 게이트라 허용된 쪽만 동작한다.
                    // (SettingsFeature 의 SensitiveCapturePreference.save 직접 호출 전례를 따른다.)
                    SystemCalendarAutoRegistrationPreference.save(true)
                    state.calendarSyncPhase = .idle
                    return .merge(
                        // 밀린 확정분 즉시 따라잡기 — best-effort. 온보딩 store 해제로 effect 가
                        // 끊겨도 scenePhase 복귀 백스톱(MochiApp)이 같은 syncNow 로 수렴한다.
                        .run { _ in await calendarSyncEngine.syncNow() },
                        .send(.nextTapped)   // 마지막 페이지 → isFinished + delegate(.finished)
                    )
                }
                // 전부 거부 — 켜져 있다고 오해하지 않게 off 로 명시하고 안내로 전환한다.
                SystemCalendarAutoRegistrationPreference.save(false)
                state.calendarSyncPhase = .denied
                return .none

            case .calendarSyncDeclined:
                guard state.currentSpec == .calendarSync, state.calendarSyncPhase != .requesting
                else { return .none }
                // off 명시 — 온보딩 재진입(설정 "다시 보기")에서 "나중에" 를 고르면 꺼진다는
                // 사용자 표현을 그대로 존중한다. 설정 §3.4d 토글이 언제든 되켠다.
                SystemCalendarAutoRegistrationPreference.save(false)
                return .send(.nextTapped)

            case .delegate:
                return .none
            }
        }
    }
}
