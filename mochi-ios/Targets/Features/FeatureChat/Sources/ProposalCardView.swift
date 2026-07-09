import CoreAgentClient
import DesignSystem
import SwiftUI

/// proposal 확인 카드 — "모찌가 준비한 행동"을 사용자가 탭으로 확정/취소한다.
///
/// 카드가 곧 휴먼인더루프: LLM 루프는 read-only 라 이 카드의 확인 탭 전까지 아무 일도
/// 일어나지 않았다(서버 설계). 파괴적 행동(삭제)은 확인 버튼을 경고색으로 구분한다.
struct ProposalCardView: View {
    let card: ChatFeature.ProposalCard
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
                Image(systemName: style.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(style.tint.opacity(0.13)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.proposal.title.isEmpty ? style.fallbackTitle : card.proposal.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = card.proposal.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            footer
        }
        .padding(HomeDesign.Spacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(HomeDesign.Color.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: card.status)
    }

    // MARK: - 상태 footer

    @ViewBuilder
    private var footer: some View {
        switch card.status {
        case .pending:
            HStack(spacing: HomeDesign.Spacing.sm) {
                Button(action: onCancel) {
                    Text("그만두기")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                        .padding(.horizontal, HomeDesign.Spacing.lg)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(HomeDesign.Color.surface))
                        .overlay(Capsule().stroke(HomeDesign.Color.border, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())

                Button(action: onConfirm) {
                    Text(card.proposal.kind == .deleteItem ? "네, 지워주세요" : "좋아요, 해주세요")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, HomeDesign.Spacing.lg)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(
                                card.proposal.kind == .deleteItem
                                    ? AnyShapeStyle(HomeDesign.Color.blush400)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                        )
                }
                .buttonStyle(PressableStyle())
            }

        case .confirming:
            statusLine(icon: "sparkles", text: "하고 있어요…", tint: HomeDesign.Color.purple500)

        case .confirmed:
            statusLine(icon: "checkmark.circle.fill", text: "완료했어요", tint: HomeDesign.Color.mint400)

        case .cancelled:
            statusLine(icon: "slash.circle", text: "그만뒀어요", tint: HomeDesign.Color.textFaint)

        case .expired:
            statusLine(
                icon: "questionmark.circle",
                text: "기록이 이미 없어요 — 카드가 만료됐어요",
                tint: HomeDesign.Color.textFaint
            )

        case let .failed(reason, needsPermission):
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs + 2) {
                statusLine(icon: "exclamationmark.circle", text: reason, tint: HomeDesign.Color.blush400)
                if needsPermission {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("설정에서 권한 켜기")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.purple600)
                            .padding(.horizontal, HomeDesign.Spacing.md)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(HomeDesign.Color.purple100.opacity(0.6)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private func statusLine(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: HomeDesign.Spacing.xs + 2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.top, 2)
    }

    private var borderColor: Color {
        switch card.status {
        case .pending, .confirming: HomeDesign.Color.purple100
        case .confirmed: HomeDesign.Color.mint400.opacity(0.35)
        case .failed: HomeDesign.Color.blush100
        case .cancelled, .expired: HomeDesign.Color.border
        }
    }

    // MARK: - kind 별 비주얼

    private var style: (icon: String, tint: Color, fallbackTitle: String) {
        switch card.proposal.kind {
        case .updateItem: ("pencil.line", HomeDesign.Color.butter400, "기록을 이렇게 바꿀까요?")
        case .deleteItem: ("trash", HomeDesign.Color.blush400, "이 기록을 지울까요?")
        case .createSchedule: ("calendar.badge.plus", HomeDesign.Color.mint400, "일정을 추가할까요?")
        case .createMemo: ("square.and.pencil", HomeDesign.Color.sky400, "이 내용을 기록해둘까요?")
        case .reminder: ("bell.badge", HomeDesign.Color.purple500, "알림을 맞출까요?")
        case .rescheduleNotification:
            ("clock.arrow.circlepath", HomeDesign.Color.purple500, "알림 시각을 바꿀까요?")
        case .cancelNotification: ("bell.slash", HomeDesign.Color.blush400, "이 알림을 끌까요?")
        }
    }
}

#Preview("상태별 카드") {
    let proposal = ChatProposal(
        id: UUID(),
        title: "회의 메모를 지울까요?",
        detail: "6월 3일에 저장한 메모예요",
        action: .deleteItem(mochiItemID: UUID())
    )
    return ScrollView {
        VStack(spacing: 12) {
            ProposalCardView(card: .init(proposal: proposal), onConfirm: {}, onCancel: {})
            ProposalCardView(card: .init(proposal: proposal, status: .confirming), onConfirm: {}, onCancel: {})
            ProposalCardView(card: .init(proposal: proposal, status: .confirmed), onConfirm: {}, onCancel: {})
            ProposalCardView(
                card: .init(
                    proposal: proposal,
                    status: .failed(reason: "알림 권한이 꺼져 있어요", needsNotificationPermission: true)
                ),
                onConfirm: {}, onCancel: {}
            )
            ProposalCardView(card: .init(proposal: proposal, status: .expired), onConfirm: {}, onCancel: {})
        }
        .padding(20)
    }
    .background(HomeDesign.Color.surface)
}
