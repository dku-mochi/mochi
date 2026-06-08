import ComposableArchitecture
import SwiftUI

/// 2페이지 — 백탭 설정 3-스텝 체크리스트.
///
/// 백탭은 단축어 *추가* 와 뒷면 탭 *연결* 이라는 분리된 두 행동이 모두 끝나야 살아난다.
/// 어느 하나만 해도 "두 번 탭해도 반응 없는" 상태가 되므로, 두 단계를 명시적 체크리스트로
/// 드러내고 마지막에 **실제 백탭이 모찌에 도달하는지 검증**한다 (`OnboardingFeature` ③).
/// 단순 안내 애니메이션이 "완료!" 라고 거짓말하던 이전 버전을 대체한다.
struct BackTapPage: View {
    @Bindable var store: StoreOf<OnboardingFeature>
    @Environment(\.openURL) private var openURL

    /// iCloud Shortcuts 갤러리의 모찌 단축어 (`Take Screenshot → 모찌 화면 캡쳐`).
    private static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/e24ac8bf17ef45a088e4b3cdc76aa44b")

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            heading
            Spacer(minLength: 24)
            checklist
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: settingsGuideBinding) {
            BackTapSettingsGuideSheet(
                onOpenSettings: openSettingsBestEffort,
                onBound: { store.send(.bindingAcknowledged) },
                onClose: { store.send(.settingsGuideDismissed) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var settingsGuideBinding: Binding<Bool> {
        Binding(
            get: { store.showSettingsGuide },
            set: { if !$0 { store.send(.settingsGuideDismissed) } }
        )
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(spacing: 12) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)

            Text(OnboardingPage.backTap.title)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(OnboardingTheme.titleColor)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = OnboardingPage.backTap.subtitle {
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(OnboardingTheme.subtitleColor)
            }
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(spacing: 14) {
            stepOne
            stepTwo
            stepThree
        }
    }

    /// ① 단축어 추가 — iCloud 링크를 갔다오면 ack (import 성공은 ③ 검증이 증명).
    private var stepOne: some View {
        BackTapStepCard(
            index: 1,
            status: store.shortcutAdded ? .done : .active,
            title: "단축어 추가하기",
            detail: store.shortcutAdded ? "추가했어요" : "모찌 단축어를 가져와요"
        ) {
            if !store.shortcutAdded {
                BackTapStepButton(title: "추가하기") {
                    guard let url = Self.shortcutURL else {
                        store.send(.shortcutAddAcknowledged)
                        return
                    }
                    openURL(url) { _ in store.send(.shortcutAddAcknowledged) }
                }
            }
        }
    }

    /// ② 뒷면 탭 연결 — 가이드 시트로 설정 경로를 안내한다 (① 완료 후 활성).
    private var stepTwo: some View {
        let status: BackTapStepStatus =
            store.backTapBound ? .done : (store.shortcutAdded ? .active : .locked)
        return BackTapStepCard(
            index: 2,
            status: status,
            title: "뒷면 탭에 연결하기",
            detail: stepTwoDetail(status)
        ) {
            if status == .active {
                BackTapStepButton(title: "설정 열기") {
                    store.send(.openSettingsTapped)
                }
            }
        }
    }

    private func stepTwoDetail(_ status: BackTapStepStatus) -> String {
        switch status {
        case .locked: return "먼저 단축어를 추가해주세요"
        case .active: return "설정에서 두 번 탭에 모찌를 연결해요"
        case .done:   return "연결했어요"
        }
    }

    /// ③ 검증 — 실제 백탭이 모찌 intent 에 도달하는지 확인한다 (② 완료 후 활성).
    private var stepThree: some View {
        let status: BackTapStepStatus = {
            if store.verifyPhase == .detected { return .done }
            return store.backTapBound ? .active : .locked
        }()
        return BackTapStepCard(
            index: 3,
            status: status,
            title: stepThreeTitle,
            detail: stepThreeDetail
        ) {
            stepThreeAccessory(status)
        }
    }

    private var stepThreeTitle: String {
        switch store.verifyPhase {
        case .detected: return "백탭이 작동해요!"
        case .waiting:  return "뒷면을 두 번 탭해보세요"
        case .timedOut: return "아직 반응이 없어요"
        case .idle, .skipped: return "백탭 테스트"
        }
    }

    private var stepThreeDetail: String {
        if !store.backTapBound { return "연결한 뒤 시험해봐요" }
        switch store.verifyPhase {
        case .idle:     return "잘 되는지 한번 해볼까요?"
        case .waiting:  return "기다리고 있어요…"
        case .detected: return "준비 끝!"
        case .timedOut: return "단축어와 연결을 다시 확인해보세요"
        case .skipped:  return "나중에 다시 해도 돼요"
        }
    }

    @ViewBuilder
    private func stepThreeAccessory(_ status: BackTapStepStatus) -> some View {
        switch store.verifyPhase {
        case .idle where status == .active:
            BackTapStepButton(title: "지금 해보세요") {
                store.send(.startVerificationTapped)
            }
        case .waiting:
            BackTapPulseIndicator()
        case .timedOut:
            BackTapStepButton(title: "다시 시도") {
                store.send(.startVerificationTapped)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Deep link (best-effort)

    /// `App-Prefs:` 딥링크는 iOS 17/18 에서 동작하지 않고 심사 리스크가 있다(확정 결정으로
    /// 유지 — 미래 iOS 복구 대비 방어 코드). 가이드 시트가 *이미* 떠 있는 위에서 best-effort
    /// 로 시도하므로, 열리지 않아도 화면은 그대로다. `canOpenURL` 선체크는 Info.plist 에
    /// query scheme 이 없어 무조건 false 라 의미가 없어 쓰지 않는다 (codex P2).
    private func openSettingsBestEffort() {
        guard let url = URL(string: "App-Prefs:root=ACCESSIBILITY") else { return }
        openURL(url) { _ in }
    }
}

// MARK: - Step Card

/// 체크리스트 단계 상태 — locked(이전 단계 미완) / active(현재) / done(완료).
/// 제네릭 ``BackTapStepCard`` 의 nested 타입이면 `BackTapStepStatus` 참조가 제네릭
/// 인자를 요구하므로 top-level 로 둔다.
enum BackTapStepStatus { case locked, active, done }

/// 체크리스트 한 줄 — 좌측 배지(번호/체크), 제목·설명, 우측 액션 슬롯.
struct BackTapStepCard<Accessory: View>: View {
    let index: Int
    let status: BackTapStepStatus
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            badge
                .accessibilityHidden(true)   // 번호/체크는 장식 — 상태는 텍스트 라벨이 전달
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(status == .locked ? OnboardingTheme.mutedTextColor : OnboardingTheme.titleColor)
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(OnboardingTheme.mutedTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // [P2] 정보(제목·설명)만 한 요소로 합치고, 우측 accessory 버튼은 별도 요소로
            // 남겨 VoiceOver 가 "추가하기/설정 열기/다시 시도" 를 따로 탭할 수 있게 한다.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(index)단계 \(title), \(accessibilityStatus)"))
            .accessibilityHint(Text(detail))

            Spacer(minLength: 8)
            accessory()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .shadow(
                    color: Color.black.opacity(status == .locked ? 0.03 : 0.07),
                    radius: status == .active ? 14 : 8,
                    x: 0, y: status == .active ? 8 : 4
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OnboardingTheme.primary.opacity(status == .active ? 0.35 : 0), lineWidth: 1.5)
        )
        .opacity(status == .locked ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var accessibilityStatus: String {
        switch status {
        case .locked: return "잠김"
        case .active: return "진행 중"
        case .done:   return "완료"
        }
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(status == .locked ? OnboardingTheme.indicatorOff : OnboardingTheme.primary)
                .frame(width: 30, height: 30)
            if status == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            } else {
                Text("\(index)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(status == .locked ? OnboardingTheme.mutedTextColor : .white)
            }
        }
        .shadow(
            color: status == .locked ? .clear : OnboardingTheme.primaryShadow,
            radius: 5, x: 0, y: 3
        )
    }
}

// MARK: - Step Button

/// 카드 우측의 작은 채움 액션 버튼.
struct BackTapStepButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(OnboardingTheme.primary)
                        .shadow(color: OnboardingTheme.primaryShadow, radius: 6, x: 0, y: 3)
                )
        }
        .buttonStyle(PressableScale())
        .accessibilityLabel(Text(title))
    }
}

/// 누름 시 살짝 축소 — 순수 시각 피드백.
struct PressableScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Pulse Indicator (검증 대기 중)

/// "뒷면을 두 번 탭" 을 기다리는 동안 도는 펄스 점 3개 (typing-indicator 스타일).
struct BackTapPulseIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(OnboardingTheme.primary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(phase == i ? 1.0 : 0.55)
                    .opacity(phase == i ? 1.0 : 0.4)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityLabel(Text("백탭을 기다리는 중"))
    }
}

// MARK: - Settings Guide Sheet

/// ② "설정 열기" 가 띄우는 가이드 — 뒷면 탭 설정 경로를 큰 글씨로 안내한다.
///
/// 공식 딥링크가 없어(`§2`) 마지막 구간은 사용자가 직접 이동해야 하므로, 경로를 단계로
/// 분명히 보여주고 "설정 열기" 는 best-effort 로만 시도한다. 진짜 완료는 ③ 검증이 증명.
struct BackTapSettingsGuideSheet: View {
    let onOpenSettings: () -> Void
    let onBound: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 드래그 인디케이터에 제목이 붙지 않도록 상단 여백 확보 (카루셀이 maxHeight 라
            // 이 Spacer 는 minLength 만큼만 차지한다).
            Spacer(minLength: 28)

            Text("백탭에 연결하기")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(OnboardingTheme.titleColor)

            Text("옆으로 넘기며 순서대로 따라 해보세요")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OnboardingTheme.subtitleColor)
                .padding(.top, 6)

            BackTapGuideCarousel()
                .frame(maxHeight: .infinity)
                .padding(.top, 16)

            VStack(spacing: 12) {
                // 설정 열기 = 먼저 할 액션이지만 외부(설정)로 나가는 길이라 outlined,
                // 연결했어요 = 돌아와 누르는 완료 액션이라 solid. 두 단계를 시각으로 구분.
                Button(action: onOpenSettings) {
                    Label("설정 열기", systemImage: "gearshape.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(OnboardingTheme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(OnboardingTheme.primary, lineWidth: 1.5)
                        )
                }
                .buttonStyle(PressableScale())

                Button(action: onBound) {
                    Text("연결했어요")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(OnboardingTheme.primary)
                                .shadow(color: OnboardingTheme.primaryShadow, radius: 12, x: 0, y: 6)
                        )
                }
                .buttonStyle(PressableScale())

                Button("나중에 할게요", action: onClose)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OnboardingTheme.mutedTextColor)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .presentationBackground(OnboardingTheme.backgroundGradient)
    }

}

// MARK: - Settings Guide Carousel

/// ② "설정 열기" 가이드의 핵심 — 실제 설정 화면 스크린샷 5컷을 세로로 크게 넘기며,
/// 탭할 항목만 스포트라이트(주변 dim + 펄스 테두리)로 띄워 "여기" 를 즉시 보여준다.
///
/// 스크린샷은 강조 없는 깨끗본(에셋, 세로 0.82 portrait 비율)이고 강조는 런타임 오버레이다.
/// 강조 항목 위치는 컷별 `ringY`(대부분 중앙, 화면 상단 항목 '두 번 탭'만 위쪽).
/// 텍스트 칩·말풍선을 모두 대체 — 글 경로는 따라가기 어려웠고 말풍선은 어색했다
/// (gemini/codex 디자인 리뷰로 9.4·9.0 확정한 안).
private struct BackTapGuideCarousel: View {
    @State private var page = 0

    private struct Step {
        let image: String
        let caption: String
        let ringY: CGFloat   // 강조 항목의 세로 위치 (0~1, 재크롭 기준)
    }

    private let steps: [Step] = [
        .init(image: "backtap-guide-1", caption: "‘손쉬운 사용’을 탭", ringY: 0.5),
        .init(image: "backtap-guide-2", caption: "‘터치’를 탭", ringY: 0.5),
        .init(image: "backtap-guide-3", caption: "‘뒷면 탭’을 탭", ringY: 0.522),
        .init(image: "backtap-guide-4", caption: "‘두 번 탭’을 탭", ringY: 0.301),
        .init(image: "backtap-guide-5", caption: "‘모찌 단축어’를 선택하면 끝!", ringY: 0.5),
    ]

    /// 재크롭한 스크린샷 비율 (1170 × 1427, portrait 0.82).
    private let aspect: CGFloat = 1170.0 / 1427.0

    var body: some View {
        GeometryReader { geo in
            // 카드는 가용 세로공간을 채우되 폭 비율을 상한으로 — 캡션·점 몫(96)을 빼고 cap.
            // 큰 Dynamic Type 으로 공간이 줄면 카드가 비례 축소(찌그러짐 방지).
            let cardH = max(220, min(geo.size.width / aspect, geo.size.height - 96))
            let cardW = cardH * aspect
            VStack(spacing: 0) {
                Text(steps[page].caption)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingTheme.titleColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                    .animation(.easeInOut(duration: 0.2), value: page)
                TabView(selection: $page) {
                    ForEach(Array(steps.enumerated()), id: \.element.image) { idx, step in
                        card(step, width: cardW, height: cardH, index: idx).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: cardH)
                dots.padding(.top, 14)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private func card(_ step: Step, width: CGFloat, height: CGFloat, index: Int) -> some View {
        ZStack {
            Image(step.image, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
            BackTapSpotlight(width: width, height: height, centerY: step.ringY)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        .frame(maxWidth: .infinity)
        // 캐러셀 한 컷을 단일 VoiceOver 요소로 — "3/5단계, ‘뒷면 탭’을 탭".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(index + 1)/\(steps.count)단계, \(step.caption)"))
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? OnboardingTheme.indicatorOn : OnboardingTheme.indicatorOff)
                    .frame(width: i == page ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: page)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 강조 항목만 스포트라이트 — 카드를 살짝(≈22%) 어둡게 덮되 강조 행만 뚫어 밝게 두고,
/// 그 위에 펄스 테두리 + 글로우를 얹는다. 주변 행과의 경쟁을 없애 "여기" 가 즉시 보인다.
/// dim 을 약하게 둬 설정 화면 컨텍스트는 살아있게 유지한다(codex 리뷰 반영).
private struct BackTapSpotlight: View {
    let width: CGFloat
    let height: CGFloat
    let centerY: CGFloat
    @State private var pulse = false

    var body: some View {
        let ringW = width * 0.92
        let ringH = height * 0.115
        let cx = width / 2
        let cy = height * centerY
        ZStack {
            // 주변 dim — 강조 행만 뚫어(destinationOut) 밝게 유지.
            Rectangle()
                .fill(Color.black.opacity(0.22))
                .mask {
                    ZStack {
                        Rectangle().fill(.white)
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .frame(width: ringW, height: ringH)
                            .position(x: cx, y: cy)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            // 펄스 테두리 + 글로우.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(OnboardingTheme.primary, lineWidth: 3)
                .frame(width: ringW, height: ringH)
                .position(x: cx, y: cy)
                .shadow(color: OnboardingTheme.primary.opacity(0.7), radius: pulse ? 9 : 4)
                .opacity(pulse ? 1.0 : 0.7)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    BackTapPage(
        store: Store(initialState: OnboardingFeature.State(currentPage: 1)) {
            OnboardingFeature()
        }
    )
    .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
