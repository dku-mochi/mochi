import ComposableArchitecture
import CoreAgentClient
import DesignSystem
import SwiftUI

/// 대화 풀스크린 — 모찌에게 묻는 메신저형 화면. NavigationStack push 로 열린다.
///
/// 탭 콘텐츠가 아니라 push 인 이유(2026-06-10 구조 전환): 입력 독이 탭바 위에 상주하면
/// 이중 바로 읽히고, TabView 안 `safeAreaInset(.bottom)` 은 키보드 inset 이 어긋나는
/// 고질 버그가 있다. push 풀스크린에선 탭바가 없어 입력 독이 키보드에 정확히 붙는다.
/// 빈 상태 인사·능력 칩은 랜딩(``ChatLandingView``)의 몫 — 여기는 대화에만 집중한다.
public struct ChatView: View {
    @Bindable var store: StoreOf<ChatFeature>
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool

    public init(store: StoreOf<ChatFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.isEmpty {
                emptyHint
            } else {
                messageList
            }
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { inputDock }
        .navigationTitle("모찌와 대화")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.send(.historyButtonTapped)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("지난 대화")

                Button {
                    store.send(.newConversationTapped, animation: .spring(response: 0.4, dampingFraction: 0.85))
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .disabled(store.isEmpty)
                .accessibilityLabel("새 대화")
            }
        }
        .onAppear { store.send(.appeared) }
        .task {
            // 입력바 탭(blank) 진입은 곧장 타이핑이 목적 — push 전환이 끝난 뒤 포커스해
            // 전환 애니메이션과 키보드 등장이 겹쳐 덜컹대지 않게 한다.
            guard case .blank = store.entry, store.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }   // 450ms 내 pop — 포커스 무의미
            composerFocused = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 백그라운드에서 SSE 가 끊겨도 run 은 서버에서 완주 — 복귀 시 스냅샷이 정본.
            if newPhase == .active { store.send(.sceneActivated) }
        }
        .sheet(item: $store.scope(state: \.history, action: \.history)) { historyStore in
            ChatHistoryView(store: historyStore)
        }
    }

    // MARK: - 빈 상태 (blank 진입 직후, 첫 전송 전)

    /// 키보드가 이미 올라온 상태라 공간이 좁다 — 인사는 랜딩이 했으니 한 줄 힌트만.
    private var emptyHint: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Spacer()
            Image("mochi-chat")
                .resizable()
                .scaledToFit()
                .frame(height: 84)
                .accessibilityHidden(true)
            Text("남겨둔 기억으로 답해드려요")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
            // 출처·proposal 카드와 "과정 보기"는 본문 delta 이후(턴 종료 무렵)에 붙는다 —
            // 위 두 onChange 가 못 잡으므로 구조 변화에도 바닥을 따라간다.
            .onChange(of: lastMessageStructure) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"

    /// 마지막 버블의 구조 스냅샷 — 카드 등장·스트림 종료 시 스크롤 추적용.
    private var lastMessageStructure: [Int] {
        guard let last = store.messages.last else { return [] }
        return [last.citations.count, last.proposals.count, last.isStreaming ? 1 : 0]
    }

    // MARK: - 입력 독

    /// 키보드 위에 붙는 **플랫 독** — 불투명 흰색 풀폭 바 + 상단 헤어라인 (메신저 표준).
    /// push 풀스크린이라 아래에 탭바가 없다 — 키보드가 내려가면 홈 인디케이터 영역까지
    /// 배경이 이어진다(ignoresSafeArea).
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
                    .focused($composerFocused)
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

#Preview("대화") {
    NavigationStack {
        ChatView(
            store: Store(initialState: ChatFeature.State()) {
                ChatFeature()
            } withDependencies: {
                $0.chatStreamClient = MockChatStreamClient()
            }
        )
    }
}
