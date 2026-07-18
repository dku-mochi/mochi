import ComposableArchitecture
import SwiftUI

/// 온보딩 진입 화면 — 5개 페이지를 **콘텐츠 크로스페이드**로 한 방향 진행.
///
/// **전환**: 모든 페이지가 같은 라벤더 그라데이션을 공유하므로 배경은 한 번만 깔아 고정하고,
/// 그 위에서 콘텐츠(글씨·히어로)만 크로스페이드한다. 화면이 통째로 슬라이드하지 않아
/// "같은 캔버스에서 내용이 바뀌는" 매끄러움이 나온다. 글씨·히어로는 페이지가 바뀔 때마다
/// stagger 로 다시 떠오른다(`onboardingEnter`).
///
/// **게이트 유지**: 전진은 footer CTA 로만 일어나고(리듀서 가드), 스와이프 surface 자체가 없어
/// 백탭 미해결 시 단계를 건너뛸 수 없다 — NavigationStack 이 주던 게이트 불변식을 그대로,
/// back-swipe desync 위험 없이 지킨다. 직전 단계로의 복귀만 좌상단 back 으로 제공.
///
/// **레이아웃**: 각 페이지 = (콘텐츠 + 하단 동적 CTA). 콘텐츠 뷰(`IntroPage` 등)는 일러스트만
/// 담당하고, footer CTA 는 페이지 종류에 따라 본 뷰가 결정한다.
public struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingFeature>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 드래그 중 현재 페이지의 수평 오프셋(손가락 추종). 커밋 시 0, 미달 시 스프링백.
    @State private var dragOffset: CGFloat = 0

    public init(store: StoreOf<OnboardingFeature>) {
        self.store = store
    }

    private var lastPageIndex: Int { OnboardingPage.allCases.count - 1 }

    public var body: some View {
        ZStack {
            OnboardingTheme.backgroundGradient.ignoresSafeArea()

            // 콘텐츠만 크로스페이드 — 동일한 배경은 고정이라 화면이 미끄러지지 않고
            // 글씨·히어로만 부드럽게 교체된다.
            ZStack {
                ForEach(OnboardingPage.allCases, id: \.self) { spec in
                    if spec.rawValue == store.currentPage {
                        PageScreen(content: { content(spec) }, footer: { footer(spec) })
                            // 들어올 땐 blanket 페이드 없이(identity) 각 요소가 stagger 로 차례로
                            // 등장하고, 나갈 땐 통째로 페이드 아웃. blanket 페이드가 글씨를 한꺼번에
                            // 띄워 stagger 를 가리던 문제를 없앤다.
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: store.currentPage)
            // 드래그 동안 현재 페이지가 손가락을 따라 미끄러진다(배경은 고정). `.animation(value:
            // currentPage)` 뒤에 둬서 드래그는 1:1 추종, 커밋 스냅은 크로스페이드가 가린다.
            .offset(x: dragOffset)
            .opacity(1.0 - min(Double(abs(dragOffset)) / 700.0, 0.18))
        }
        .overlay(alignment: .topLeading) { backButton }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.currentPage > 0)
        .gesture(pageDrag)
        .sensoryFeedback(.selection, trigger: store.currentPage)
        .tint(OnboardingTheme.primary)
    }

    /// 양방향 인터랙티브 페이지 드래그 — 왼쪽=앞으로, 오른쪽=뒤로. 현재 페이지가 손가락을
    /// 따라 미끄러지고, 거리(80pt) **또는** 빠른 플릭(예측 이동량 200pt)이면 커밋, 아니면 스프링백.
    /// 갈 곳 없는 끝(첫·마지막 페이지)에선 rubber-band 로 저항한다. `minimumDistance` 12 라
    /// 탭은 트리거하지 않아 카드 안 버튼과 충돌하지 않는다.
    ///
    /// **게이트 유지**(2026-07-14, 동기화 선택 페이지가 백탭 뒤에 붙으며 재설계): 미해결 백탭에서의
    /// 전진 드래그는 여기(커밋 억제 + rubber-band)와 리듀서 `pageChanged` 가드가 이중으로 막는다 —
    /// "검증 성공 or 명시 스킵 전엔 전진 불가". 홈으로 나가는 `finished` 는 마지막 페이지 CTA 만
    /// 발행하므로 드래그로 미설정 채 빠져나갈 수 없다. ⇒ "완료는 CTA만" 불변식 유지.
    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = rubberBanded(value.translation.width)
            }
            .onEnded { value in
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let horizontal = abs(dx) > abs(value.translation.height)
                let committed = horizontal && (abs(dx) > 80 || abs(predicted) > 200)

                var target: Int?
                if committed {
                    if dx < 0, store.currentPage < lastPageIndex, !forwardGated {
                        target = store.currentPage + 1          // 왼쪽 = 앞으로
                    } else if dx > 0, store.currentPage > 0 {
                        target = store.currentPage - 1          // 오른쪽 = 뒤로
                    }
                }

                if let target {
                    dragOffset = 0   // 커밋: 스냅(크로스페이드가 가림) 후 페이지 전환
                    store.send(.pageChanged(target))
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }

    /// 미해결 백탭에서의 전진 여부 — 게이트에 막힌 방향(리듀서 가드와 동일 조건).
    private var forwardGated: Bool {
        store.currentSpec == .backTap && !store.backTapStepResolved
    }

    /// 갈 곳 없는 방향(첫 페이지에서 뒤로 / 마지막·게이트에서 앞으로)으로 끌면 0.3배로 저항(rubber-band).
    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw > 0, store.currentPage == 0 { return raw * 0.3 }
        if raw < 0, store.currentPage == lastPageIndex || forwardGated { return raw * 0.3 }
        return raw
    }

    /// 직전 단계로만 돌아가는 작은 back — 전진은 CTA 로만(게이트 유지), 스와이프 surface 없음.
    @ViewBuilder
    private var backButton: some View {
        if store.currentPage > 0 {
            Button {
                store.send(.pageChanged(store.currentPage - 1))
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.mutedTextColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 8)
            .padding(.top, 4)
            .transition(.opacity)
            .accessibilityLabel(Text("이전"))
        }
    }

    @ViewBuilder
    private func content(_ spec: OnboardingPage) -> some View {
        switch spec {
        case .intro:        IntroPage()
        case .backTap:      BackTapPage(store: store)
        case .share:        SharePage()
        case .autoSort:     AutoSortPage()
        case .calendarSync: CalendarSyncPage(store: store)
        }
    }

    // MARK: - Footer CTA

    @ViewBuilder
    private func footer(_ spec: OnboardingPage) -> some View {
        Group {
            if spec == .backTap && store.verifyPhase != .detected {
                // 백탭 미해결: 약한 "나중에 할게요" 만. 단계 진행은 카드 내부 버튼이 담당.
                // skip 은 다음 페이지(동기화 선택)로 넘어간다 — 온보딩 완료는 마지막 페이지 CTA 만.
                Button("나중에 할게요") {
                    store.send(.skipVerificationTapped)
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(OnboardingTheme.mutedTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityHint(Text("백탭 설정을 건너뛰고 다음으로 넘어갑니다"))
            } else if spec == .calendarSync {
                calendarSyncFooter
            } else {
                OnboardingButton(title: spec.primaryCTA) {
                    if spec == .backTap {
                        store.send(.backTapStepCompleted)
                    } else {
                        store.send(.nextTapped)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    /// 동기화 선택(마지막) footer — 수락이 primary, "나중에" 는 약한 보조. 전부 거부 후에는
    /// 안내(페이지 본문)와 함께 "시작하기"로 종료만 남긴다(재프롬프트는 iOS 규격상 불가 —
    /// iOS 설정 + 모찌 설정 §3.4d 경로 안내가 담당).
    @ViewBuilder
    private var calendarSyncFooter: some View {
        if store.calendarSyncPhase == .denied {
            OnboardingButton(title: "시작하기") {
                store.send(.nextTapped)
            }
        } else {
            VStack(spacing: 4) {
                OnboardingButton(title: OnboardingPage.calendarSync.primaryCTA) {
                    store.send(.calendarSyncAccepted)
                }
                .disabled(store.calendarSyncPhase == .requesting)
                .opacity(store.calendarSyncPhase == .requesting ? 0.6 : 1)
                .accessibilityHint(Text("캘린더와 미리알림 권한을 요청합니다"))

                Button("나중에 할게요") {
                    store.send(.calendarSyncDeclined)
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(OnboardingTheme.mutedTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .disabled(store.calendarSyncPhase == .requesting)
                .accessibilityHint(Text("자동 등록 없이 시작합니다. 설정에서 언제든 켤 수 있어요"))
            }
        }
    }
}

/// 한 페이지 화면 — 들어올 때 콘텐츠(글씨·히어로)에 이어 footer CTA 까지 stagger 로 차례로
/// 등장시킨다. footer 가 마지막(index 3)이라 "내용 먼저, 행동 버튼은 그다음" 으로 시선을 이끈다.
/// `appeared` 는 페이지가 마운트될 때마다 false→true 라, 페이지를 바꿀 때마다 reveal 이 재생된다.
private struct PageScreen<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
                .onboardingEnter(3, appeared, reduceMotion: reduceMotion)
        }
        .onAppear { appeared = true }
    }
}

#if DEBUG
#Preview {
    OnboardingView(
        store: Store(initialState: OnboardingFeature.State()) {
            OnboardingFeature()
        }
    )
}
#endif
