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

    /// 스크롤이 콘텐츠 바닥 근처인가 — 자동 따라가기(스트리밍·키보드 재앵커)의 게이트.
    /// 위로 올라가 읽는 중인 사용자를 delta 마다 끌어내리지 않기 위한 상태다.
    @State private var isNearBottom = true
    @State private var containerHeight: CGFloat = 0
    /// 전송 햅틱 트리거 — submit 마다 +1.
    @State private var sendPulse = 0

    /// 방금 전송한 turn 의 user 메시지 — 화면 top 에 고정할 대상(ChatGPT/Claude 식).
    /// nil 이면 spacer 없음(복원·전환 직후엔 기존처럼 바닥에서 시작).
    @State private var activeUserTurnID: UUID?
    /// 마지막 user 버블 top · 자연 콘텐츠(바닥 spacer 제외) 끝 — 둘 다 ``scrollSpace`` 좌표.
    /// 같은 좌표계라 둘의 *차이* = "질문 top→답변 끝" 높이가 스크롤에 불변이다.
    @State private var lastUserBubbleTop: CGFloat = 0
    @State private var naturalContentBottom: CGFloat = 0

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
                        .background {
                            // 상단 고정 중인 user 버블의 top 만 추적(활성 턴 1개 → 측정뷰 1개).
                            if message.id == activeUserTurnID {
                                GeometryReader { geo in
                                    SwiftUI.Color.clear.preference(
                                        key: LastUserTopKey.self,
                                        value: geo.frame(in: .named(Self.scrollSpace)).minY
                                    )
                                }
                            }
                        }
                        // 상단 고정 대상 위 숨 쉴 여백 — nav 바에 딱 붙지 않게.
                        // `.id` 를 inset 바깥에 둬 scrollTo(.top) 이 이 여백 위에 정렬되게 한다.
                        .padding(.top, message.id == activeUserTurnID ? Self.turnTopInset : 0)
                        .id(message.id)
                    }
                    if case let .failed(reason) = store.runPhase {
                        ChatErrorBanner(reason: reason)
                    }
                    // 자연 콘텐츠 끝(아래 spacer 제외) — "질문 top→답변 끝" 높이의 기준점.
                    SwiftUI.Color.clear.frame(height: 0).background(
                        GeometryReader { geo in
                            SwiftUI.Color.clear.preference(
                                key: NaturalContentBottomKey.self,
                                value: geo.frame(in: .named(Self.scrollSpace)).maxY
                            )
                        }
                    )
                    // 마지막 질문을 화면 top 까지 올리기 위한 동적 여백(ChatGPT/Claude 식).
                    Color.clear.frame(height: bottomSpacerHeight)
                    // 키보드/입력바 위 여백 + 스크롤 anchor.
                    Color.clear.frame(height: 4).id(Self.bottomAnchor)
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.sm)
                .background(
                    // 콘텐츠 바닥 모서리(스크롤 좌표계 maxY) 추적 — "바닥 근처" 판정의 원천.
                    GeometryReader { geo in
                        SwiftUI.Color.clear.preference(
                            key: ContentBottomKey.self,
                            value: geo.frame(in: .named(Self.scrollSpace)).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            .scrollDismissesKeyboard(.interactively)
            .background(
                GeometryReader { geo in
                    SwiftUI.Color.clear
                        .onAppear { containerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { oldHeight, newHeight in
                            containerHeight = newHeight
                            // 키보드 등장 = 컨테이너 축소. 바닥을 보고 있었다면 바닥을
                            // 유지하고, 위로 올라가 읽는 중이면 오프셋을 건드리지 않는다
                            // (메신저 표준 — 키보드가 마지막 메시지를 가리지 않게).
                            // 바닥을 보고 있었으면 키보드 높이만큼 따라 올리고, 위로 올라가
                            // 읽는 중이면 오프셋을 건드리지 않는다(상단 고정 중엔 near=false 라
                            // 자연히 그대로 — 질문이 top 에 유지된다).
                            if newHeight < oldHeight, isNearBottom {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                                }
                            }
                        }
                }
            )
            .onPreferenceChange(ContentBottomKey.self) { contentBottom in
                let near = contentBottom - containerHeight < 72
                if near != isNearBottom {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isNearBottom = near
                    }
                }
            }
            .onPreferenceChange(LastUserTopKey.self) { lastUserBubbleTop = $0 }
            .onPreferenceChange(NaturalContentBottomKey.self) { naturalContentBottom = $0 }
            .overlay(alignment: .bottomTrailing) {
                // 생성 중엔 spacer 로 near=false 가 되고 "맨 아래"도 빈 캔버스라 버튼이
                // 무의미 — 깜빡임만 생기므로 숨긴다. 완료 후엔 정상 동작.
                if !isNearBottom, !store.isStreaming {
                    ScrollToBottomButton {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                    .padding(.trailing, HomeDesign.Spacing.lg)
                    .padding(.bottom, HomeDesign.Spacing.md)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                // 첫 마운트가 곧 첫 전송이면(idle→streaming 직후 messageList 가 처음 뜸)
                // 내 질문을 top 에 고정하고, 아니면(복원·전환) 기존처럼 바닥에서 시작한다.
                // (트리거를 onAppear 에 두는 이유: 빈 상태→messageList 첫 마운트 시점에는
                //  onChange 가 발화하지 못한다 — 마운트 전의 상태 전이를 못 보기 때문.)
                if store.runPhase == .streaming, let id = lastUserMessageID {
                    activeUserTurnID = id
                    scrollToActiveTurn(proxy)
                } else {
                    activeUserTurnID = nil
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.last?.text) {
                // 상단 고정 중엔 답변 delta 를 따라 내려가지 않는다 — 질문을 top 에 유지.
                guard isNearBottom, activeUserTurnID == nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) {
                guard isNearBottom, activeUserTurnID == nil else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            // 전송 = runPhase idle→streaming. 내 질문을 화면 top 으로(그 아래 빈 캔버스에
            // 답변이 펼쳐진다). runPhase 트리거라 submit()·firstMessage 두 진입을 다 잡고,
            // 복원 awaitingRemote 와도 구별된다.
            .onChange(of: store.runPhase) { _, phase in
                guard phase == .streaming, let id = lastUserMessageID else { return }
                activeUserTurnID = id
                scrollToActiveTurn(proxy)
                // spacer 확장은 다음 레이아웃 패스에 반영된다 — 짧은 대화에서 질문을
                // top 까지 올리려면 그 다음 프레임에 한 번 더 앵커한다(1 프레임 ≈ 16ms,
                // 사실상 즉시 — 버블 등장과 이어져 보인다).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    scrollToActiveTurn(proxy)
                }
            }
            // 키보드 등장 시 바닥을 보고 있었으면 키보드 높이만큼 따라 올린다.
            // (ScrollView+safeAreaInset 조합은 키보드를 contentInset 으로만 흡수해
            //  컨테이너 높이 onChange 가 안 터지므로, 포커스 변화로 직접 잡는다.
            //  생성 중엔 spacer 로 near=false 라 자연히 스킵 — 질문 top 이 유지된다.)
            .onChange(of: composerFocused) { _, focused in
                guard focused, isNearBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            // 대화 전환(history 열기·새 대화)에선 spacer 회수 후 바닥에서 시작 —
            // 첫 전송(nil→값)은 건드리지 않는다.
            .onChange(of: store.conversationID) { old, new in
                if old != nil, old != new {
                    activeUserTurnID = nil
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            // 출처·proposal 카드와 "과정 보기"는 본문 delta 이후(턴 종료 무렵)에 붙는다 —
            // 위 두 onChange 가 못 잡으므로 구조 변화에도 바닥을 따라간다(상단 고정 중엔 제외).
            .onChange(of: lastMessageStructure) {
                guard isNearBottom, activeUserTurnID == nil else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"
    private static let scrollSpace = "chat-scroll"
    /// 상단 고정된 질문과 nav 바 사이 여백.
    private static let turnTopInset = HomeDesign.Spacing.md

    /// 마지막 버블의 구조 스냅샷 — 카드 등장·스트림 종료 시 스크롤 추적용.
    private var lastMessageStructure: [Int] {
        guard let last = store.messages.last else { return [] }
        return [last.citations.count, last.proposals.count, last.isStreaming ? 1 : 0]
    }

    /// 상단 고정 대상 — 가장 최근 user 메시지(assistant placeholder 보다 위).
    private var lastUserMessageID: UUID? {
        store.messages.last(where: { $0.role == .user })?.id
    }

    /// 마지막 질문을 화면 top 까지 올리기 위해 채워야 할 바닥 여백.
    /// `naturalContentBottom - lastUserBubbleTop` = 질문 top→답변 끝 높이(스크롤 불변).
    /// 그 높이가 한 화면보다 작은 만큼만 채운다 — 답변이 길어지면 0 으로 수렴.
    ///
    /// **생성 중에만** 존재한다 — 답변이 끝나면(`isStreaming=false`) 0 으로 회수해
    /// 바닥에 빈 공간이 남지 않게 한다(질문은 이미 top 에 있어 점프는 없다).
    private var bottomSpacerHeight: CGFloat {
        guard activeUserTurnID != nil, store.isStreaming else { return 0 }
        let turnHeight = naturalContentBottom - lastUserBubbleTop
        // 질문 위 여백(turnTopInset)도 viewport 를 차지하므로 함께 차감 — 바닥이 정확히 맞는다.
        return max(0, containerHeight - turnHeight - Self.turnTopInset)
    }

    private func scrollToActiveTurn(_ proxy: ScrollViewProxy) {
        guard let id = activeUserTurnID else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            proxy.scrollTo(id, anchor: .top)
        }
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
        .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
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
        sendPulse += 1
        store.send(.sendTapped, animation: .spring(response: 0.45, dampingFraction: 0.85))
    }
}

/// 콘텐츠 바닥 모서리의 스크롤 좌표계 maxY — 컨테이너 높이와 비교해 "바닥 근처"를 판정.
private struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 마지막 user 버블 top(scrollSpace minY) — 상단 고정 spacer 계산의 한 축.
private struct LastUserTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 바닥 spacer 를 뺀 자연 콘텐츠 끝(scrollSpace maxY) — 상단 고정 spacer 계산의 다른 축.
private struct NaturalContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 위로 올라가 읽는 중일 때 우하단에 뜨는 복귀 버튼 — 스트리밍 따라가기로 돌아가는 동선.
private struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
                .frame(width: 36, height: 36)
                .background(Circle().fill(HomeDesign.Color.surface))
                .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
                .shadow(color: HomeDesign.Color.ink900.opacity(0.1), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("맨 아래로")
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
