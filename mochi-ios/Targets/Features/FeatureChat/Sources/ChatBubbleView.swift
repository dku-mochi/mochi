import CoreAgentClient
import DesignSystem
import SwiftUI

/// 대화 버블 — user 는 퍼플 그라데이션, assistant 는 미니 모찌 아바타가 붙은 화이트 카드.
/// 스트리밍 중에는 텍스트 대신 툴 상태 pill / 타이핑 점이 같은 버블 자리에서 숨 쉰다.
struct ChatBubbleView: View {
    let message: ChatFeature.ChatMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBubble
        }
    }

    // MARK: - User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineSpacing(3)
                .padding(.horizontal, HomeDesign.Spacing.lg)
                .padding(.vertical, HomeDesign.Spacing.sm + 2)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 20,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .shadow(color: HomeDesign.Color.purple500.opacity(0.22), radius: 10, x: 0, y: 5)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Assistant

    private var assistantBubble: some View {
        HStack(alignment: .bottom, spacing: HomeDesign.Spacing.sm) {
            Image("mochi2")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                if let label = message.activeToolLabel {
                    ToolStatusPill(label: label)
                } else if message.isStreaming, message.text.isEmpty {
                    TypingDots()
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineSpacing(3.5)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.vertical, HomeDesign.Spacing.sm + 2)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 6,
                    bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: 20,
                    style: .continuous
                )
                .fill(HomeDesign.Color.surface)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 12, x: 0, y: 6)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 지금 도는 툴의 동사형 카피 — sparkles 가 호흡하며 "모찌가 일하는 중"을 보여준다.
/// 스피너 금지(캐릭터 제품) — 과정의 주어는 항상 모찌다.
struct ToolStatusPill: View {
    let label: String
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.xs + 2) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.purple500)
                .scaleEffect(pulsing ? 1.25 : 0.9)
                .opacity(pulsing ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            Text(label + "…")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.purple600)
        }
        .padding(.horizontal, HomeDesign.Spacing.sm + 2)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(HomeDesign.Color.purple50))
        .onAppear { pulsing = true }
    }
}

/// 답변 첫 글자 전 타이핑 점 3개 — 순차 바운스.
struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(HomeDesign.Color.purple400)
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -3 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.14),
                        value: animating
                    )
            }
        }
        .padding(.vertical, 6)
        .onAppear { animating = true }
        .accessibilityLabel("모찌가 답변을 쓰는 중")
    }
}
