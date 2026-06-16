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
    /// 스크롤 컨테이너의 실측 높이. 키보드가 `safeAreaInset` 입력독을 밀어올리면 이 높이가
    /// 줄어든다. bottom anchored 채팅에서는 이 값으로 "바닥 근처"와 키보드 resize follow 만 판단한다.
    @State private var containerHeight: CGFloat = 0
    /// 전송 햅틱 트리거 — submit 마다 +1.
    @State private var sendPulse = 0

    public init(store: StoreOf<ChatFeature>) {
        self.store = store
    }

    public var body: some View {
        content
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

    @ViewBuilder
    private var content: some View {
        if store.isEmpty {
            emptyHint
        } else {
            messageList
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
                        .id(message.id)
                    }
                    if case let .failed(reason) = store.runPhase {
                        ChatErrorBanner(reason: reason)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
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
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(.named(Self.scrollSpace))
            .scrollDismissesKeyboard(.interactively)
            // 메시지 영역 탭 = 키보드 내림. simultaneous 라 버블 내부 버튼(출처·proposal)도 그대로 동작한다.
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .background(
                GeometryReader { geo in
                    SwiftUI.Color.clear
                        .onAppear { containerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in containerHeight = h }
                }
            )
            .onPreferenceChange(ContentBottomKey.self) { contentBottom in
                // iOS 18 은 ChatGeometryFollow(onScrollGeometryChange) 가 near-bottom 을 전담한다.
                // preference 기반 판정은 iOS 18 에서 named-coordinate-space 회귀로 어긋나므로 끈다.
                guard !usesGeometryFollow else { return }
                // withAnimation 으로 감싸지 않는다 — 스크롤 도중 near 가 바뀌면 그 전역
                // transaction 이 진행 중인 scrollTo settle 에 끼어들어 마지막에 미세하게
                // 버벅인다. 버튼 등장만 애니메이션하면 되므로 overlay 의 .animation 으로 격리.
                isNearBottom = contentBottom - containerHeight < 72
            }
            // iOS 18 전용: ScrollGeometry 단일 원천으로 near-bottom·스트리밍 따라가기를 처리.
            .modifier(ChatGeometryFollow(isNearBottom: $isNearBottom, proxy: proxy, anchorID: Self.bottomAnchor))
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom {
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
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.last?.text) {
                guard !usesGeometryFollow, isNearBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) {
                guard !usesGeometryFollow, isNearBottom else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.runPhase) { _, phase in
                // iOS 18: 따라가기는 ChatGeometryFollow 가 콘텐츠 성장으로 처리한다. 여기선 새 턴
                // 시작 시 따라가기 의사만 켜준다 — 작성 중 위로 올라가 있었어도 전송하면 바닥으로 복귀.
                // 불변식: `.streaming` 전이는 사용자 전송(ChatFeature.sendMessage) 단일 경로뿐이다.
                // 비전송 진입점에서 streaming 으로 가게 되면 이 강제 복귀는 회수 능동 주체 원칙과
                // 충돌하므로 그땐 조건을 좁혀야 한다.
                if usesGeometryFollow {
                    if phase == .streaming { isNearBottom = true }
                    return
                }
                guard isNearBottom || phase == .streaming else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .onChange(of: containerHeight) { _, _ in
                guard !usesGeometryFollow, isNearBottom else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: store.conversationID) { old, new in
                guard old != nil, old != new else { return }
                isNearBottom = true   // 새 대화 로드 — 바닥부터 보여주고 따라가기 재개
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: lastMessageStructure) {
                guard !usesGeometryFollow, isNearBottom else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"
    /// 콘텐츠 바닥 모서리(maxY)를 재는 좌표계 — near-bottom 판정의 기준.
    private static let scrollSpace = "chat-scroll"

    /// iOS 18+ 에서는 ``ChatGeometryFollow`` 가 near-bottom 판정과 스트리밍 따라가기를 전담한다.
    /// preference 기반 판정·onChange→scrollTo 따라가기(iOS 17 경로)는 그때 비활성화해 이중 추종을 막는다.
    private var usesGeometryFollow: Bool {
        if #available(iOS 18.0, *) { true } else { false }
    }

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
        // 메신저식 bottom anchored 흐름에서는 전송 후에도 키보드를 유지한다.
        // 키보드 내림/올림과 강제 스크롤이 경합하던 구조를 없애기 위함.
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

/// iOS 18 전용 견고 스크롤 추종 — `ScrollGeometry` 단일 원천.
///
/// iOS 18(Xcode 16 빌드)에서 named-coordinate-space `GeometryReader` preference 기반 near-bottom
/// 판정과 `ScrollViewReader.scrollTo` 가 스트리밍 중 불안정해, LLM 응답이 와도 자동 따라가기가
/// 멈추는 회귀가 있다. `onScrollGeometryChange`(WWDC24)로 콘텐츠 성장·입력독/키보드 inset 증가를
/// 직접 감지해 바닥 근처일 때만 바닥 앵커로 즉시 따라간다 — 위로 올라가 읽는 중이면 끌어내리지 않는다.
/// iOS 17 에서는 아무 것도 하지 않고 기존(preference + onChange) 경로가 그대로 동작한다.
private struct ChatGeometryFollow: ViewModifier {
    @Binding var isNearBottom: Bool
    let proxy: ScrollViewProxy
    let anchorID: String

    /// "바닥 근처" 임계값(pt) — 기존 preference 경로와 동일.
    private static let nearBottomThreshold: CGFloat = 72
    /// 부동소수 노이즈를 성장으로 오인하지 않기 위한 최소 증가폭(pt).
    private static let growEpsilon: CGFloat = 0.5

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Snapshot.self) { geo in
                Snapshot(
                    contentHeight: geo.contentSize.height,
                    bottomInset: geo.contentInsets.bottom,
                    // visibleRect 는 inset/offset 을 반영한 실제 가시 영역 — 바닥까지 남은 거리.
                    distanceFromBottom: geo.contentSize.height - geo.visibleRect.maxY
                )
            } action: { old, new in
                let contentGrew = new.contentHeight > old.contentHeight + Self.growEpsilon
                let insetGrew = new.bottomInset > old.bottomInset + Self.growEpsilon   // 키보드·입력독 등장
                if (contentGrew || insetGrew) && isNearBottom {
                    // 스트리밍 델타·키보드 — 바닥 추종. 빠른 델타에 애니메이션이 쌓이지 않도록 즉시 이동.
                    proxy.scrollTo(anchorID, anchor: .bottom)
                } else if !contentGrew && !insetGrew {
                    // 사용자 스크롤(또는 추종 settle) — 콘텐츠는 그대로, 위치만 바뀐 경우에만 갱신.
                    isNearBottom = new.distanceFromBottom < Self.nearBottomThreshold
                }
            }
        } else {
            content
        }
    }

    private struct Snapshot: Equatable {
        var contentHeight: CGFloat
        var bottomInset: CGFloat
        var distanceFromBottom: CGFloat
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
