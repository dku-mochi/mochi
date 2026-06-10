import CoreAgentClient
import DesignSystem
import SwiftUI

/// 대화 버블 — user 는 퍼플 그라데이션, assistant 는 화이트 카드.
/// (미니 모찌 아바타는 26pt 로 뭉개져 보여 제거 — 2026-06-10 피드백.)
/// 스트리밍 중에는 텍스트 대신 툴 상태 pill / 타이핑 점이 같은 버블 자리에서 숨 쉰다.
struct ChatBubbleView: View {
    let message: ChatFeature.ChatMessage
    var onCitationTap: (ChatCitation) -> Void = { _ in }
    var onProposalConfirm: (UUID) -> Void = { _ in }
    var onProposalCancel: (UUID) -> Void = { _ in }

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
        // HStack 은 trailing Spacer(36)로 버블 최대폭을 잡는 용도로만 남는다 (아바타 제거 후).
        HStack(spacing: HomeDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                if let label = message.activeToolLabel {
                    ToolStatusPill(label: label)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                } else if message.isStreaming, message.text.isEmpty {
                    TypingDots()
                        .transition(.opacity)
                }

                // 완료된 턴의 접힌 "과정 보기" — 스트리밍 중에는 pill 이 그 역할을 한다.
                if !message.isStreaming, !message.toolSteps.isEmpty {
                    ProcessDisclosure(steps: message.toolSteps)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }

                if !message.text.isEmpty {
                    let blocks = ChatMarkup.blocks(
                        raw: message.text,
                        citations: message.citations,
                        isStreaming: message.isStreaming
                    )
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case let .paragraph(text):
                            Text(text)
                                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textPrimary)
                                .lineSpacing(3.5)
                        case let .table(header, rows):
                            ChatTableView(header: header, rows: rows)
                        }
                    }
                    .transition(.opacity)
                }

                if !message.citations.isEmpty {
                    CitationCardsRow(citations: message.citations, onTap: onCitationTap)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }

                ForEach(message.proposals) { card in
                    ProposalCardView(
                        card: card,
                        onConfirm: { onProposalConfirm(card.id) },
                        onCancel: { onProposalCancel(card.id) }
                    )
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
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
        // 스트림 이벤트는 reducer 에 애니메이션 없이 들어온다 — 구조 변화(pill 교체·과정·
        // 출처·proposal 등장)만 여기서 implicit 스프링으로 받아 transition 을 발동시킨다.
        // 본문 text 는 delta 마다 바뀌므로 키에서 제외(타이핑마다 레이아웃 스프링 금지).
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: structure)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 구조 등장 애니메이션 키 — "무엇이 보이는가"만 추린 스냅샷.
    private var structure: Structure {
        Structure(
            toolLabel: message.activeToolLabel,
            isStreaming: message.isStreaming,
            hasText: !message.text.isEmpty,
            citationCount: message.citations.count,
            proposalCount: message.proposals.count
        )
    }

    private struct Structure: Equatable {
        let toolLabel: String?
        let isStreaming: Bool
        let hasText: Bool
        let citationCount: Int
        let proposalCount: Int
    }
}

/// 답변 근거 미니카드 행 — 본문 위첨자 번호(¹²)와 짝을 이루는 출처 스냅샷.
/// 탭 → 상세 zoom (item 이 삭제됐어도 카드 자체는 출처 스냅샷으로 남는다 — 서버 설계와 동일).
struct CitationCardsRow: View {
    let citations: [ChatCitation]
    let onTap: (ChatCitation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(citations) { citation in
                    card(citation)
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
            }
            // 버블 콘텐츠 패딩(lg)을 콘텐츠 inset 으로 옮기고, 아래 음수 패딩으로 클립
            // 경계를 버블 가장자리까지 넓힌다 — scrollClipDisabled 는 카드가 여러 장일 때
            // 말풍선 밖까지 그려지는 문제가 있어 제거.
            .padding(.horizontal, HomeDesign.Spacing.lg)
        }
        .padding(.horizontal, -HomeDesign.Spacing.lg)
    }

    private func card(_ citation: ChatCitation) -> some View {
        Button {
            onTap(citation)
        } label: {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
                Text("\(citation.index)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(HomeDesign.Color.purple100.opacity(0.8)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.title?.isEmpty == false ? citation.title! : "저장한 기록")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                    if let snippet = citation.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
                    .padding(.top, 4)
            }
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .frame(maxWidth: 230, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(HomeDesign.Color.purple50.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HomeDesign.Color.purple100.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("근거 \(citation.index)번, \(citation.title ?? "저장한 기록")")
    }
}

/// 완료된 턴의 접힌 "과정 보기" — 모찌가 거친 툴 스텝을 1줄로 접어두고 탭으로 펼친다.
/// 펼침 상태는 view-local — 대화를 떠나면 다시 접히는 게 자연스럽다(과정은 부차 정보).
struct ProcessDisclosure: View {
    let steps: [ChatFeature.ToolStep]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs + 2) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: HomeDesign.Spacing.xs) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("과정 보기 · \(steps.count)단계")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "과정 접기" : "과정 보기, \(steps.count)단계")

            if isExpanded {
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: HomeDesign.Spacing.xs + 2) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(HomeDesign.Color.mint400)
                            // 스냅샷 복원 턴은 label 이 비어 있다(서버 미영속) — 빈 조각은 건너뛴다.
                            Text(
                                [step.label, step.summary ?? ""]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " → ")
                            )
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                // 다음 툴로 라벨이 바뀔 때 글자가 크로스페이드 — 버블의 structure 키
                // (toolLabel 포함) 가 애니메이션 transaction 을 공급한다.
                .contentTransition(.opacity)
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
