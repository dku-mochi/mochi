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

    /// 스크롤이 콘텐츠 바닥 근처인가 — 자동 따라가기(스트리밍 재앵커)의 게이트.
    /// 위로 올라가 읽는 중인 사용자를 delta 마다 끌어내리지 않기 위한 상태다.
    @State private var isNearBottom = true
    /// 스크롤 컨테이너의 *실측* 높이 = 보이는 콘텐츠 영역(viewport). `safeAreaInset(.bottom)` 의
    /// 입력 독은 SwiftUI 자동 키보드 회피로 키보드 위에 붙으므로, 키보드가 올라오면 이 높이가
    /// 그만큼 자동으로 줄어든다 — 즉 키보드를 이미 반영한 값이다. NotificationCenter·좌표 측정
    /// 없이 이 한 값이 viewport 의 단일 진실(spacer 기준 + near-bottom 판정 겸용).
    @State private var containerHeight: CGFloat = 0
    /// 전송 햅틱 트리거 — submit 마다 +1.
    @State private var sendPulse = 0

    /// 방금 전송한 turn 의 user 메시지 — 화면 top 에 고정할 대상(ChatGPT/Claude 식).
    /// nil 이면 spacer 없음(복원·전환 직후엔 기존처럼 바닥에서 시작).
    @State private var activeUserTurnID: UUID?
    /// 활성 턴 질문 버블·마지막 답변 버블의 *고유 높이*(`geo.size.height`). 위치(scrollSpace)가
    /// 아니라 높이라 스크롤에 무관하고, 마크다운/카드 등 렌더가 끝나면 자동 갱신된다. 위치
    /// 기반은 스크롤 도중 두 preference 가 다른 패스에서 갱신돼 turnHeight 가 출렁이고
    /// spacer→콘텐츠→스크롤 피드백으로 버벅였다(2026-06-13). 높이 합은 그런 피드백이 없다.
    @State private var activeUserHeight: CGFloat = 0
    @State private var lastAssistantHeight: CGFloat = 0

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
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = false }
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
                            // 활성 턴 질문·마지막 답변 버블의 *고유 높이*를 잰다(turnTopInset 패딩
                            // 밖이라 순수 버블 높이). spacer 계산의 입력 — 위치가 아닌 높이라
                            // 스크롤·렌더 타이밍에 흔들리지 않는다.
                            GeometryReader { geo in
                                SwiftUI.Color.clear
                                    .preference(
                                        key: ActiveUserHeightKey.self,
                                        value: message.id == activeUserTurnID ? geo.size.height : 0
                                    )
                                    .preference(
                                        key: LastAssistantHeightKey.self,
                                        value: (message.id == store.messages.last?.id && message.role == .assistant)
                                            ? geo.size.height : 0
                                    )
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
                    // 질문을 top 에 두고 "질문+답변+여백 = 한 화면" 이 되게 채우는 동적 바닥 여백
                    // (ChatGPT 식) + 스크롤 anchor. 마지막 요소라 뒤에 추가 간격이 없다.
                    Color.clear.frame(height: bottomSpacerHeight).id(Self.bottomAnchor)
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
            // 스크롤 anchor — OS 버전별 분리(아래 ``AdaptiveScrollAnchor``):
            // - iOS 18+: `.initialOffset=.bottom`(복원 대화는 최신이 바닥) + `.sizeChanges=.top`.
            //   답변 스트리밍·키보드로 content/viewport 가 변해도 SwiftUI 가 *네이티브로* top 위치를
            //   유지한다 → spacer 를 답변높이에 연동(매 프레임 변동)하거나 매번 scrollTo 할 필요가
            //   없어, "content size 와 offset 동시 조절" 경합이 원천 사라진다.
            // - iOS 17: role 분리가 없어 `.bottom` 단일 + spacer 보정 + 명시 scrollTo 로 흉내낸다.
            .modifier(AdaptiveScrollAnchor(pinnedToTop: activeUserTurnID != nil))
            .coordinateSpace(.named(Self.scrollSpace))
            .scrollDismissesKeyboard(.interactively)
            // 메시지 영역 탭 = 키보드 내림(ChatGPT 식). simultaneous 라 버블 내부 버튼
            // (출처·proposal)도 그대로 동작한다.
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            // 스크롤 컨테이너 실측 높이 = viewport. 키보드가 safeAreaInset 독을 밀어올리면 이
            // 높이가 자동으로 줄어 키보드를 반영한다(추측으로 inset 을 빼지 않으니 정확).
            .background(
                GeometryReader { geo in
                    SwiftUI.Color.clear
                        .onAppear { containerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in containerHeight = h }
                }
            )
            .onPreferenceChange(ContentBottomKey.self) { contentBottom in
                // withAnimation 으로 감싸지 않는다 — 스크롤 도중 near 가 바뀌면 그 전역
                // transaction 이 진행 중인 scrollTo settle 에 끼어들어 마지막에 미세하게
                // 버벅인다. 버튼 등장만 애니메이션하면 되므로 overlay 의 .animation 으로 격리.
                isNearBottom = contentBottom - containerHeight < 72
            }
            .onPreferenceChange(ActiveUserHeightKey.self) { activeUserHeight = $0 }
            .onPreferenceChange(LastAssistantHeightKey.self) { lastAssistantHeight = $0 }
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
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isNearBottom)
            .onAppear {
                // 첫 마운트가 곧 첫 전송이면(idle→streaming 직후 messageList 가 처음 뜸)
                // 내 질문을 top 에 고정하고, 아니면(복원·전환) 기존처럼 바닥에서 시작한다.
                // (트리거를 onAppear 에 두는 이유: 빈 상태→messageList 첫 마운트 시점에는
                //  onChange 가 발화하지 못한다 — 마운트 전의 상태 전이를 못 보기 때문.)
                if store.runPhase == .streaming, let id = lastUserMessageID {
                    activeUserTurnID = id
                    // runPhase 경로와 동일하게 한 프레임 뒤 앵커 — activeUserTurnID 반영으로
                    // spacer 가 확장된 *다음* 레이아웃에서 scrollTo 가 질문을 top 까지 올린다.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(16))
                        scrollToActiveTurn(proxy)
                    }
                } else {
                    activeUserTurnID = nil
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.last?.text) {
                // 스트리밍 중엔 스크롤하지 않는다 — 답변이 통째로 떠올라 H_a 가 커지면 spacer 가
                // 같은 만큼 줄어 "질문 top→콘텐츠 끝" 이 한 화면으로 유지되므로(보정), 스크롤
                // 오프셋이 그대로라 질문이 top 에 *저절로* 머문다. 여기서 재앵커하면 오히려
                // 불필요한 스크롤이 겹쳐 버벅인다(2026-06-13). 복원/전환 등 비-스트리밍에서만 따라간다.
                guard isNearBottom, activeUserTurnID == nil, store.runPhase != .streaming else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) {
                guard isNearBottom, activeUserTurnID == nil, store.runPhase != .streaming else { return }
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
                // activeUserTurnID 반영으로 spacer 가 확장된 *다음* 레이아웃에서 앵커해야 질문이
                // top 까지 올라간다 — 한 프레임 양보. (키보드가 떠 있다 전송으로 내려가는 중이면
                // viewport 가 계속 커지는데, 그 추적은 아래 onChange(containerHeight) 가 맡는다.)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    scrollToActiveTurn(proxy)
                }
            }
            // [iOS 17 전용] 키보드가 내려가는 동안 viewport(containerHeight)가 단계적으로 커진다 —
            // 활성 턴이 있으면 그 변화를 따라 질문을 top 에 다시 정렬해 *움직이는 viewport* 위에서도
            // 안착시킨다. iOS 18+ 은 `.sizeChanges` anchor 가 이 위치 유지를 네이티브로 하므로 수동
            // follow 가 불필요하고, 겹치면 오히려 경합·점프가 난다 → 게이트로 막는다.
            // - `isNearBottom` 가드: 위로 올라가 읽는 중(near=false)이면 따라가지 않는다 — 키보드를
            //   다시 올리거나 drag dismiss 해도 질문으로 yank 하지 않게(전송 직후 정착은 near=true 통과).
            // - `animated: false`: 키보드 inset 변화는 SwiftUI 자체 transaction 에 묻어가게 둔다.
            //   여기서 또 spring 을 두르면 매 resize 틱마다 새 애니메이션이 쌓여 jitter 가 난다.
            .onChange(of: containerHeight) { _, _ in
                if #available(iOS 18, *) { return }
                guard activeUserTurnID != nil, store.isStreaming, isNearBottom else { return }
                scrollToActiveTurn(proxy, animated: false)
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
                // 스트리밍 중엔 스크롤 고정(위 text follower 와 동일 원칙) — 카드도 질문 아래에
                // 떠오를 뿐 따라 내려가지 않는다. 비-스트리밍 복원 시에만 바닥 근처면 따라간다.
                guard isNearBottom, activeUserTurnID == nil, store.runPhase != .streaming else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"
    /// 콘텐츠 바닥 모서리(maxY)를 재는 좌표계 — near-bottom 판정의 기준.
    private static let scrollSpace = "chat-scroll"
    /// 상단 고정된 질문과 nav 바 사이 여백.
    private static let turnTopInset = HomeDesign.Spacing.md
    /// `.top` 앵커의 zero-margin 회피 여유 — content-below-question 을 viewport 보다 살짝 크게 둬
    /// 서브픽셀·측정오차에도 질문이 확실히 top 까지 닿게 한다.
    private static let pinSlack = HomeDesign.Spacing.sm

    /// 마지막 버블의 구조 스냅샷 — 카드 등장·스트림 종료 시 스크롤 추적용.
    private var lastMessageStructure: [Int] {
        guard let last = store.messages.last else { return [] }
        return [last.citations.count, last.proposals.count, last.isStreaming ? 1 : 0]
    }

    /// 상단 고정 대상 — 가장 최근 user 메시지(assistant placeholder 보다 위).
    private var lastUserMessageID: UUID? {
        store.messages.last(where: { $0.role == .user })?.id
    }

    /// 보이는 콘텐츠 영역 높이 = 스크롤 컨테이너 실측 높이(``containerHeight``). safeAreaInset
    /// 독이 키보드 위로 붙으므로 키보드를 이미 반영한 값이라, 별도 보정 없이 그대로 viewport 다.
    private var spacerViewport: CGFloat { containerHeight }

    /// 활성 턴의 질문을 top 에 두고 `질문 + 답변 + spacer = 한 화면(spacerViewport)` 이 되게
    /// 채우는 바닥 여백(ChatGPT 식).
    ///
    /// 높이는 모두 *고유 높이* — `turnTopInset`(질문 위 여백) + `activeUserHeight`(질문 버블)
    /// + `lastAssistantHeight`(답변 버블, 마크다운·카드 포함 실제 렌더 높이) + LazyVStack 간격
    /// 2개(질문↔답변, 답변↔spacer). 답변이 길어 합이 viewport 를 넘으면 0(자연 스크롤).
    /// 답변 렌더로 `lastAssistantHeight` 가 커지면 spacer 가 같은 만큼 줄어 총합이 한 화면으로
    /// 유지되므로(스크롤 오프셋 불변) 질문이 top 에 머문다.
    ///
    /// **생성이 끝나도 유지된다** — `isStreaming` 으로 회수하면 완료 순간 spacer 가 사라지며
    /// 스크롤이 다시 내려오는 버그가 있었다. 활성 턴이 바뀌거나 대화 전환 시(`=nil`)만 풀린다.
    /// 측정 전(높이 0)엔 자연히 큰 spacer 가 되어 첫 scrollTo 가 질문을 top 까지 올릴 수 있다.
    private var bottomSpacerHeight: CGFloat {
        guard activeUserTurnID != nil, spacerViewport > 0 else { return 0 }
        if #available(iOS 18, *) {
            // iOS 18+: `.sizeChanges=.top` anchor 가 답변 자람을 흡수해 질문 top 을 유지하므로,
            // spacer 를 답변높이에 *연동하지 않는다*(content size 가 매 프레임 흔들리던 원인 제거).
            // 질문 위로 한 화면(여백)만 확보해 질문이 top 까지 갈 스크롤 여지를 준다 — 답변이 이
            // 여백을 넘으면 자연 스크롤된다(ChatGPT 동일). gap 1개(질문↔답변)만 차감.
            return max(0, spacerViewport + Self.pinSlack - Self.turnTopInset - activeUserHeight - HomeDesign.Spacing.md)
        }
        // iOS 17: 답변높이까지 빼 content 총합을 한 화면으로 고정(크기 불변→offset 불변)해 질문
        // top 을 흉내낸다. `.top` 앵커가 질문을 정렬하려면 *아래 공간 ≥ viewport* 여야 하므로
        // pinSlack 을 더해 측정오차에도 질문이 확실히 top 까지 닿게 한다.
        let gaps = HomeDesign.Spacing.md * 2   // 질문↔답변, 답변↔spacer (LazyVStack spacing)
        return max(0, spacerViewport + Self.pinSlack - Self.turnTopInset - activeUserHeight - lastAssistantHeight - gaps)
    }

    /// 활성 턴 질문을 화면 top 으로 올린다. spacer 가 `질문 아래로 한 화면`을 확보하므로 `.top`
    /// 앵커가 질문을 viewport 최상단(navbar 아래)에 정렬한다. (바닥 anchor 도 썼으나 viewport
    /// 측정이 정확해야만 질문이 정확히 top 에 와, 측정이 조금만 작아도 질문이 top 에 못 닿았다
    /// — `.top` 은 아래 공간만 충분하면 앵커가 위치를 직접 맞춰 더 견고하다.)
    ///
    /// `animated`: 전송 직후 첫 핀은 spring 으로 부드럽게 올린다(response 0.55 — 0.4 는 "슉"
    /// 하고 너무 빨랐다). 키보드 resize 추적(`onChange(containerHeight)`)은 false 로 호출해
    /// 키보드 자체 애니메이션에 묻어가게 한다(이중 spring jitter 방지).
    private func scrollToActiveTurn(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id = activeUserTurnID else { return }
        guard animated else {
            proxy.scrollTo(id, anchor: .top)
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
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
        // 전송 시 키보드를 내린다 — 내려가며 *커지는* viewport(containerHeight)를
        // onChange(containerHeight)가 따라가 질문을 top 에 부드럽게 안착시킨다. 핀 대상은
        // runPhase 의 idle→streaming 전이가 정한다(submit·firstMessage 두 진입을 다 포착).
        composerFocused = false
        store.send(.sendTapped, animation: .spring(response: 0.45, dampingFraction: 0.85))
    }
}

/// 스크롤 anchor 를 OS 버전별로 분리한다.
/// - iOS 18+: `.initialOffset=.bottom`(첫 진입은 바닥) + `.sizeChanges`(크기 변화 시 anchor).
///   **함정**: `.sizeChanges` 는 container 축소(키보드 등장)와 content 증가(답변 스트리밍)를
///   *구분하지 못한다* — 둘 다 "size change". 그래서 정적 `.top` 으로 두면 키보드 등장에도 top 을
///   유지해 콘텐츠가 키보드 위로 안 밀리고 가려진다. 의도를 `pinnedToTop` 으로 나눈다:
///   - 핀 중(전송 후 질문 top-pin): `.top` → 답변이 자라도 질문 top 유지.
///   - 평소: `.bottom` → 키보드 등장 시 콘텐츠가 키보드 위로 밀려 올라간다(메신저 기본 동작).
/// - iOS 17: role 분리 API 가 없어 `.bottom` 단일(위치 유지는 spacer 보정 + 명시 scrollTo 가 흉내).
private struct AdaptiveScrollAnchor: ViewModifier {
    let pinnedToTop: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(pinnedToTop ? .top : .bottom, for: .sizeChanges)
        } else {
            content
                .defaultScrollAnchor(.bottom)
        }
    }
}

/// 콘텐츠 바닥 모서리의 스크롤 좌표계 maxY — 컨테이너 높이와 비교해 "바닥 근처"를 판정.
private struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 활성 턴 질문 버블의 고유 높이 — spacer 계산의 한 축(매칭 버블만 값>0, 나머지 0).
private struct ActiveUserHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 마지막 답변(assistant) 버블의 고유 높이 — 마크다운·카드 포함 실제 렌더 높이. spacer 의 다른 축.
private struct LastAssistantHeightKey: PreferenceKey {
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
