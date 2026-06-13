import ComposableArchitecture
import DesignSystem
import SwiftUI

/// 채팅 탭 랜딩 — 모찌 인사 + 능력 칩 + 입력바 모양 버튼.
///
/// 진짜 TextField 는 두지 않는다 — 탭바 위에 입력 독이 상주하면 이중 바로 읽히고
/// (2026-06-10 피드백), TabView 안 키보드 inset 버그까지 끌어안는다. 입력바 *모양*의
/// 버튼만 두고, 탭하면 대화 풀스크린(push)에서 키보드가 열린다 — 홈 입력바와 같은 문법.
public struct ChatLandingView: View {
    @Bindable var store: StoreOf<ChatLandingFeature>

    public init(store: StoreOf<ChatLandingFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: HomeDesign.Spacing.xl)

            MochiGreeting()

            Spacer(minLength: HomeDesign.Spacing.lg)

            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { _, chip in
                    suggestionRow(icon: chip.icon, tint: chip.tint, text: chip.text)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)

            Spacer(minLength: HomeDesign.Spacing.lg)

            composerButton
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.bottom, HomeDesign.Spacing.md)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .sheet(item: $store.scope(state: \.history, action: \.history)) { historyStore in
            ChatHistoryView(store: historyStore)
        }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(alignment: .center) {
            Spacer()
            Button {
                store.send(.historyButtonTapped)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(HomeDesign.Color.surface))
                    .overlay(Circle().stroke(HomeDesign.Color.border.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("지난 대화")
        }
        .padding(.horizontal, HomeDesign.Spacing.xl)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.xs)
    }

    // MARK: - 추천 칩

    /// 찾기·추천·요약·수정 — 홈 칩과 동일 문구로 채팅의 능력 폭을 일관되게 가르친다.
    private static let suggestions: [(icon: String, tint: Color, text: String)] = [
        ("heart.fill", HomeDesign.Color.blush400, "오늘 데이트 어디서 갈까?"),
        ("book.fill", HomeDesign.Color.sky400, "이번주 공부하려고 남긴 기록 알려줘"),
        ("calendar", HomeDesign.Color.mint400, "민수랑 언제 만나기로 했지?"),
        ("pencil.line", HomeDesign.Color.butter400, "방금 남긴 메모 수정해줘"),
    ]

    private func suggestionRow(icon: String, tint: Color, text: String) -> some View {
        Button {
            store.send(.chipTapped(text))
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.14)))
                Text(text)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.vertical, HomeDesign.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(HomeDesign.Color.border.opacity(0.8), lineWidth: 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.04), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - 입력바 모양 버튼

    /// 홈 입력바와 같은 캡슐 문법(sparkles + placeholder + 퍼플 그라데이션 전송) —
    /// 탭바와 한 덩어리가 아니라 콘텐츠 속에 떠 있는 카드로 읽힌다.
    private var composerButton: some View {
        Button {
            store.send(.composerTapped)
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    Circle().fill(HomeDesign.Color.purple100.opacity(0.7))
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.purple500)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                Text("무엇이든 편하게 물어보세요")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)

                Spacer()

                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .shadow(color: HomeDesign.Color.purple500.opacity(0.32), radius: 12, x: 0, y: 7)
            }
            .padding(.leading, HomeDesign.Spacing.lg)
            .padding(.trailing, HomeDesign.Spacing.sm)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .frame(minHeight: 48)
            .background(
                Capsule(style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(HomeDesign.Color.border.opacity(0.8), lineWidth: 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 14, x: 0, y: 7)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("모찌에게 물어보기")
    }
}

/// 랜딩 시그니처 — 둥실 떠 있는 모찌가 먼저 인사한다.
private struct MochiGreeting: View {
    @State private var floating = false

    var body: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image("mochi-chat")
                .resizable()
                .scaledToFit()
                .frame(height: 132)
                .offset(y: floating ? -7 : 5)
                .animation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true), value: floating)
                .onAppear { floating = true }
                .accessibilityHidden(true)

            VStack(spacing: HomeDesign.Spacing.xs) {
                Text("무엇이든 물어보세요")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("남겨둔 기록을 뒤져서 답하고,\n찾고, 정리하고, 고쳐드려요.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }
}

#Preview("랜딩") {
    ChatLandingView(
        store: Store(initialState: ChatLandingFeature.State()) {
            ChatLandingFeature()
        }
    )
}
