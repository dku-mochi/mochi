import ComposableArchitecture
import CoreAgentClient
import DesignSystem
import SwiftUI

/// 채팅 탭 — 모찌에게 묻는 메신저형 대화 화면.
///
/// 탭 진입 = 곧장 대화(세션 리스트 아님). 빈 상태는 모찌 캐릭터 인사 + 능력 칩 4종,
/// 입력바는 홈 회수 진입점과 같은 문법(sparkles 리딩 + 퍼플 그라데이션 전송)을 써서
/// "홈에서 본 그 입력"이 여기로 이어진다는 감각을 만든다. 자동 포커스는 걸지 않는다 —
/// 키보드가 인사·칩을 가리면 첫 진입에서 채팅의 능력 폭을 배울 기회가 사라진다.
public struct ChatView: View {
    @Bindable var store: StoreOf<ChatFeature>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<ChatFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if store.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { inputDock }
        .onAppear { store.send(.appeared) }
        .onChange(of: scenePhase) { _, newPhase in
            // 백그라운드에서 SSE 가 끊겨도 run 은 서버에서 완주 — 복귀 시 스냅샷이 정본.
            if newPhase == .active { store.send(.sceneActivated) }
        }
        .sheet(item: $store.scope(state: \.history, action: \.history)) { historyStore in
            ChatHistoryView(store: historyStore)
        }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("모찌와 대화")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("남겨둔 기억으로 답해드려요")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            Spacer()
            HStack(spacing: HomeDesign.Spacing.sm) {
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

                Button {
                    store.send(.newConversationTapped, animation: .spring(response: 0.4, dampingFraction: 0.85))
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.purple600)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(HomeDesign.Color.purple100.opacity(0.7)))
                }
                .buttonStyle(PressableStyle())
                .opacity(store.isEmpty ? 0 : 1)
                .disabled(store.isEmpty)
                .accessibilityHidden(store.isEmpty)
                .accessibilityLabel("새 대화")
            }
        }
        .padding(.horizontal, HomeDesign.Spacing.xl)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.xs)
    }

    // MARK: - 빈 상태 (첫 진입)

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: HomeDesign.Spacing.xl)

            MochiGreeting()

            Spacer(minLength: HomeDesign.Spacing.lg)

            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { _, chip in
                    suggestionRow(icon: chip.icon, tint: chip.tint, text: chip.text)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)

            Spacer(minLength: HomeDesign.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    /// 찾기·추천·요약·수정 — 홈 칩과 동일 문구로 채팅의 능력 폭을 일관되게 가르친다.
    private static let suggestions: [(icon: String, tint: Color, text: String)] = [
        ("heart.fill", HomeDesign.Color.blush400, "오늘 데이트 어디서 갈까?"),
        ("book.fill", HomeDesign.Color.sky400, "이번주 공부하려고 남긴 기록 알려줘"),
        ("calendar", HomeDesign.Color.mint400, "민수랑 언제 만나기로 했지?"),
        ("pencil.line", HomeDesign.Color.butter400, "방금 남긴 메모 수정해줘"),
    ]

    private func suggestionRow(icon: String, tint: Color, text: String) -> some View {
        Button {
            store.send(.chipTapped(text), animation: .spring(response: 0.45, dampingFraction: 0.85))
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

    // MARK: - 메시지 리스트

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: HomeDesign.Spacing.md) {
                    ForEach(store.messages) { message in
                        ChatBubbleView(
                            message: message,
                            onCitationTap: { store.send(.citationTapped($0)) },
                            onProposalConfirm: { proposalID in
                                store.send(
                                    .proposalConfirmTapped(messageID: message.id, proposalID: proposalID),
                                    animation: .spring(response: 0.35, dampingFraction: 0.85)
                                )
                            },
                            onProposalCancel: { proposalID in
                                store.send(
                                    .proposalCancelTapped(messageID: message.id, proposalID: proposalID),
                                    animation: .spring(response: 0.35, dampingFraction: 0.85)
                                )
                            }
                        )
                        .id(message.id)
                    }
                    if case let .failed(reason) = store.runPhase {
                        ChatErrorBanner(reason: reason)
                    }
                    // 키보드/입력바 위 여백 + 스크롤 anchor.
                    Color.clear.frame(height: 4).id(Self.bottomAnchor)
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.sm)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"

    // MARK: - 입력 독

    /// 탭바 위에 얹히는 **플랫 독** — 탭바와 같은 불투명 흰색 풀폭 바 + 상단 헤어라인.
    /// 떠 있는 캡슐(그림자·페이드)은 탭바와 이중 레이어로 읽혀 폐기(2026-06-10 피드백) —
    /// 메신저 표준(X DM·카카오톡)처럼 입력 독과 탭바가 한 덩어리의 바 스택으로 읽히게 한다.
    /// 키보드가 올라오면 탭바는 가려지고 독만 키보드에 붙어 같은 문법이 유지된다.
    private var inputDock: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                    .accessibilityHidden(true)

                TextField("무엇이든 편하게 물어보세요", text: $store.draft, axis: .vertical)
                    .font(.system(size: 14.5, weight: .medium, design: .rounded))
                    .lineLimit(1...4)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .tint(HomeDesign.Color.purple500)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(HomeDesign.Color.bg)
            )

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
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
            }
            .buttonStyle(PressableStyle())
            .disabled(!store.canSubmit)
            .opacity(store.canSubmit ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: store.canSubmit)
            .accessibilityLabel("보내기")
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            // 탭바와 동일한 불투명 흰색 + 상단 1px 헤어라인 — 탭바 appearance(0.82 white)와 톤 일치.
            HomeDesign.Color.surface
                .overlay(alignment: .top) {
                    SwiftUI.Color(white: 0.82).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func submit() {
        guard store.canSubmit else { return }
        store.send(.sendTapped, animation: .spring(response: 0.45, dampingFraction: 0.85))
    }
}

/// 빈 상태 시그니처 — 둥실 떠 있는 모찌가 말풍선으로 먼저 인사한다.
private struct MochiGreeting: View {
    @State private var floating = false

    var body: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(height: 116)
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

/// 스트림 실패 안내 — 재시도 배선(타임아웃 워치독 포함)은 live 배선 PR 에서.
private struct ChatErrorBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
            Text("답변을 가져오지 못했어요. 잠시 후 다시 보내주세요.")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
        }
        .foregroundStyle(HomeDesign.Color.blush400)
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, HomeDesign.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HomeDesign.Color.blush100.opacity(0.5))
        )
        // VoiceOver 도 시각 카피와 동일 문구 — 기술 에러 원문(reason)을 읽히지 않는다.
        .accessibilityLabel("답변을 가져오지 못했어요. 잠시 후 다시 보내주세요.")
    }
}

#Preview("빈 상태") {
    ChatView(
        store: Store(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.chatStreamClient = MockChatStreamClient()
        }
    )
}
