import SwiftUI

/// 3페이지 — 공유 시트 안내.
///
/// "공유 버튼으로 저장"의 *흐름*을 보여준다: 일반 콘텐츠 카드(공유 배지) → 아래로 흐르는
/// chevron + 글로우 빔 → 모찌가 받아 저장. 서드파티 브랜드 로고(YouTube·Instagram·Safari)는
/// 쓰지 않는다 — 상표/저작권·App Store 심사(5.2.1) 리스크 회피이자, "어디서(출처)"가 아니라
/// "모찌에 저장된다(결과)"를 보여주는 게 본질이기 때문 (검토·근거: docs/CHANGELOG 2026-06-07).
/// 카드·배지·chevron·빔·글로우는 모두 SwiftUI 로 그리고, 모찌(`mochi-share-base`, 누끼본)만
/// PNG 자산. 디자인 리뷰 통과본 (codex 9.1 · gemini 9.6 / 10).
struct SharePage: View {
    var body: some View {
        OnboardingPageScaffold(
            title: OnboardingPage.share.title,
            subtitle: OnboardingPage.share.subtitle
        ) {
            hero
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            contentCard
            chevrons
                .padding(.top, 5)
                .padding(.bottom, -26)
            Image("mochi-share-base")
                .resizable()
                .scaledToFit()
                // 캐릭터 몸통이 캔버스의 ~0.78 폭(팔까지 0.92)이라, intro(`mochi-hello`, 몸통 0.61)
                // 와 *몸통* 크기를 맞추려면 프레임을 줄여야 한다. 235 → 몸통 ~183pt (intro 300 과 동일).
                .frame(maxWidth: 235, maxHeight: 235)
        }
        // 카드+chevron 이 몸통 위에 쌓여 몸통이 hero 중앙보다 아래로 내려가므로 위로 올려
        // 몸통 세로 중심을 intro 캐릭터와 맞춘다.
        .offset(y: -44)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("어떤 앱에서든 공유 버튼을 누르면 모찌에 저장됩니다"))
    }

    // MARK: Content card — 공유될 콘텐츠를 상징하는 미니 링크-프리뷰
    private var contentCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.64, green: 0.56, blue: 0.95),
                             Color(red: 0.42, green: 0.28, blue: 0.86)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.78))
                        .frame(width: 20, height: 20)
                )

            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(Color(red: 0.61, green: 0.55, blue: 0.84))
                    .frame(height: 8).frame(maxWidth: .infinity)
                Capsule().fill(Color(red: 0.69, green: 0.64, blue: 0.89))
                    .frame(width: 84, height: 7)
                Capsule().fill(Color(red: 0.78, green: 0.74, blue: 0.93))
                    .frame(width: 52, height: 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [.white, Color(red: 0.95, green: 0.94, blue: 1.0)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 0.47, green: 0.39, blue: 0.71).opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color(red: 0.23, green: 0.16, blue: 0.47).opacity(0.26), radius: 20, x: 0, y: 14)
        )
        .overlay(alignment: .topTrailing) {
            shareBadge.offset(x: 9, y: -9)
        }
    }

    /// 카드 모서리의 공유 배지 — "공유 액션"이 이 콘텐츠를 모찌로 보낸다는 표식.
    private var shareBadge: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(
                Circle().fill(LinearGradient(
                    colors: [Color(red: 0.616, green: 0.533, blue: 0.95),
                             Color(red: 0.463, green: 0.341, blue: 0.855)],
                    startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: Color(red: 0.486, green: 0.388, blue: 0.878).opacity(0.5), radius: 4.5, x: 0, y: 4)
    }

    // MARK: Chevrons — 카드 → 모찌로 흐르는 모션 (위→아래 점강)
    private var chevrons: some View {
        VStack(spacing: 1) {
            chevron(opacity: 0.42)
            chevron(opacity: 0.72)
            chevron(opacity: 1.0)
        }
        .shadow(color: Color(red: 0.486, green: 0.388, blue: 0.878).opacity(0.32), radius: 1.2, x: 0, y: 1.5)
    }

    private func chevron(opacity: Double) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LinearGradient(
                colors: [Color(red: 0.74, green: 0.67, blue: 0.96),
                         Color(red: 0.48, green: 0.37, blue: 0.88)],
                startPoint: .top, endPoint: .bottom))
            .opacity(opacity)
    }
}

#if DEBUG
#Preview {
    SharePage()
        .background(OnboardingTheme.backgroundGradient.ignoresSafeArea())
}
#endif
