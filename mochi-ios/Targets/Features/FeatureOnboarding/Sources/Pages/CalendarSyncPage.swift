import ComposableArchitecture
import DesignSystem
import SwiftUI

/// 5페이지(피날레) — 캘린더·미리알림 자동 등록 선택.
///
/// 히어로: 캡처에서 나온 일정·할 일 조각(pill)이 캘린더·미리알림 카드 속으로 떠올라 안착하고,
/// 할 일엔 체크가 채워진다 — "저장만 하면 시스템 앱에 선다"가 카피 없이 한눈에 읽히게.
/// 카드는 AutoSortPage 의 raised 아이콘 셀과 같은 시각 언어(흰 카드 + inner highlight +
/// 드롭섀도)이고 자산도 같은 clay 3D(cat-calendar/cat-checklist)를 재사용한다 — 3페이지에서
/// "분류 결과"로 보였던 아이콘이 여기서 "목적지 앱"으로 승격되는 서사를 잇는다. 아래엔
/// mochi-jump-shadow — 조각을 올려보낸 주체. pill 틴트는 HomeDesign 팔레트(일정=퍼플,
/// 할 일=버터)로 앱 본편의 상세·캘린더 행 시각 언어와 연결한다.
///
/// 연출은 진입 시 1회(반복 루프 없음 — 선택을 방해하지 않는 절제): 제목→부제→히어로 stagger
/// (`onboardingEnter`) 뒤에 pill 이 카드로 안착 → 체크가 스프링으로 채워진다.
/// Reduce Motion 은 안착 완료 상태로 정적 표시. 전부 거부 시 히어로 아래에 안내 한 줄.
struct CalendarSyncPage: View {
    @Bindable var store: StoreOf<OnboardingFeature>
    /// pill 안착 트리거 — 페이지 마운트마다 재생(크로스페이드 재진입 포함).
    @State private var landed = false
    /// 할 일 체크 채움 — 안착보다 한 박자 늦게.
    @State private var checked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.calendarSync.title,
            subtitle: OnboardingPage.calendarSync.subtitle
        ) {
            hero
        }
        .onAppear {
            guard !reduceMotion else {
                landed = true
                checked = true
                return
            }
            // 글씨 stagger(0.2/0.4)·히어로 등장(0.6) 뒤에 pill 이 떠올라 안착하고 체크가 채워진다.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(1.0)) { landed = true }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(1.55)) { checked = true }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 18) {
            // 일러스트만 접근성에서 하나로 묶는다 — 아래 거부 안내는 별도 요소로 남겨
            // VoiceOver 가 상태 변화를 읽게 한다(안내까지 묶으면 라벨과 모순, codex P2).
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    destinationCard(asset: "cat-calendar", caption: "캘린더") {
                        schedulePill
                    }
                    destinationCard(asset: "cat-checklist", caption: "미리알림") {
                        todoPill
                    }
                }
                .frame(maxWidth: .infinity)

                Image("mochi-jump-shadow")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 185)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("저장한 일정은 캘린더에, 할 일은 미리알림에 자동으로 등록돼요"))

            // 전부 거부 시 안내 — 오해 방지(자동 등록은 꺼진 상태로 시작한다).
            if store.calendarSyncPhase == .denied {
                Text("권한이 꺼져 있어요. 설정에서 언제든 켤 수 있어요")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(OnboardingTheme.mutedTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.calendarSyncPhase)
    }

    /// 목적지 앱 카드 — AutoSortPage 아이콘 셀과 같은 raised 흰 카드 문법. 아이콘 아래에
    /// 실사용 조각(pill)이 안착해 "여기에 이렇게 선다"를 보여준다.
    private func destinationCard(
        asset: String, caption: String, @ViewBuilder pill: () -> some View
    ) -> some View {
        VStack(spacing: 10) {
            Image(asset)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 76)

            pill()
                .opacity(landed ? 1 : 0)
                .offset(y: landed ? 0 : 46)   // 아래(모찌 쪽)에서 떠올라 안착
                .scaleEffect(landed ? 1 : 0.9)

            Text(caption)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(OnboardingTheme.mutedTextColor)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    Color.white
                        // AutoSortPage 아이콘 셀과 동일한 raised 효과(위 highlight + 아래 inner shadow).
                        .shadow(.inner(color: .white.opacity(0.95), radius: 2, x: 0, y: 1.5))
                        .shadow(.inner(color: .black.opacity(0.12), radius: 2, x: 0, y: -1.5))
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        )
    }

    /// 일정 조각 — 상세·캘린더 탭의 일정 행과 같은 퍼플 틴트.
    private var schedulePill: some View {
        Text("저녁 7시 회식")
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundStyle(HomeDesign.Color.purple600)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(HomeDesign.Color.purple50))
    }

    /// 할 일 조각 — 완료 체크가 채워지는 순간이 이 페이지의 마침표. 체크 컬러는 앱 본편
    /// 완료 토글과 같은 버터.
    private var todoPill: some View {
        HStack(spacing: 5) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.butter400)
                .scaleEffect(checked ? 1 : 0.7)
            Text("우유 사기")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
                .strikethrough(checked, color: HomeDesign.Color.textFaint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(HomeDesign.Color.butter50))
    }
}

#if DEBUG
#Preview {
    CalendarSyncPage(
        store: Store(initialState: OnboardingFeature.State(currentPage: OnboardingPage.calendarSync.rawValue)) {
            OnboardingFeature()
        }
    )
    .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
