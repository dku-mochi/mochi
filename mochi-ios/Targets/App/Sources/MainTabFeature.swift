import ComposableArchitecture
import CoreNetworking
import CorePersistence
import DesignSystem
import Foundation
import FeatureChat
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 reducer.
///
/// 시안에 따라 4개 탭(홈/채팅/캘린더/검색) 구조. 캘린더 탭은 월간 캘린더 화면.
/// 기존 InboxFeature 는 설정 화면의 디버그 항목에서만 접근 가능하도록 보존.
@Reducer
struct MainTabFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var selectedTab: Tab = .home
        var home = MochiHomeFeature.State()
        var inbox = InboxFeature.State()    // dev debug 접근용 (설정 → 디버그)
        var chatLanding = ChatLandingFeature.State()
        var mochiCalendar = MochiCalendarFeature.State()
        var search = SearchFeature.State()

        /// 디버그용 InboxView 모달 — 설정 화면 안에서 sheet 로 띄우지만 reducer 차원에선 flag 만.
        var isDebugInboxPresented: Bool = false

        /// 상세·설정 네비게이션 스택 — 카드 탭 시 detail, 톱니바퀴 탭 시 settings 를 push.
        /// App 레이어 StackState 로 둬 Feature 간 직접 의존(아키텍처 위반) 없이 보유한다.
        /// TabView 가 바깥 단일 NavigationStack 안에 있어, push 시 탭바를 포함한 전체가
        /// 함께 슬라이드되므로 탭과 무관한 단일 스택으로 충분하다.
        /// 설정을 sheet 가 아닌 push 로 둬, 설정 위에 온보딩 fullScreenCover 를 띄울 때 "single sheet" 충돌을 피한다.
        var path = StackState<Path.State>()
        @Presents var mochiItem: MochiItemFeature.State?

        /// 기록 카드 → 상세: UIKit 커스텀 zoom present (path push 가 아님).
        /// push 에는 UIKit 전환을 입힐 수 없어, 상세만 별도 custom presentation 으로 띄워
        /// 카드 frame 에서 확대되는 전환을 직접 제어한다. 설정은 그대로 path 에 push.
        @Presents var detail: DetailFeature.State?
        /// 카드 탭 시 캡처한 hero frame 묶음(카드·이미지·제목). nil 이면 중앙 scale 폴백(예: 캘린더 진입).
        var detailHero: HeroSourceFrames?
        /// 회수 히어로 카드에서 연 상세의 server PK — 닫힐 때 그 카드만 정확히 피드에서 빼도록 추적한다.
        /// nil = 회수 외 진입(최근·검색·캘린더·알림). 닫는 사이 다른 회수 카드를 열어도 캡처값으로 특정해
        /// 엉뚱한 카드가 빠지지 않는다(이 itemID 를 `recallDetailClosed` 신호에 실어 보낸다).
        var detailFromRecallItemID: UUID?
    }

    enum Tab: String, CaseIterable, Sendable {
        case home, chat, mochis, search

        var title: String {
            switch self {
            case .home:   return "홈"
            case .chat:   return "질문"
            case .mochis: return "캘린더"
            case .search: return "검색"
            }
        }
    }

    enum Action: Sendable {
        case tabSelected(Tab)
        case searchTabReselected            // 검색 탭이 이미 선택된 상태에서 다시 탭 → 시작 화면으로 복귀
        case home(MochiHomeFeature.Action)
        case inbox(InboxFeature.Action)
        case chatLanding(ChatLandingFeature.Action)
        case mochiCalendar(MochiCalendarFeature.Action)
        case search(SearchFeature.Action)
        case path(StackActionOf<Path>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
        case detail(PresentationAction<DetailFeature.Action>)
        /// 분석완료 알림 탭 → server PK 를 로컬 id 로 역매핑(effect, RootFeature 가 위임).
        /// `hero` 는 회수·턴테이블 카드처럼 출발 frame 이 있을 때만 비고, 알림 진입은 nil(중앙 scale).
        case openDetailFromNotification(serverID: UUID, hero: HeroSourceFrames?)
        /// 역매핑된 로컬 id 로 상세 present — 같은 항목이면 무시, 다른 상세가 떠 있으면 닫고 재open.
        case presentDetailFromNotification(localID: UUID, hero: HeroSourceFrames?)
        /// 회수 알림 탭 → recallEventID 로 단건 entry 를 서버 fetch(effect, RootFeature 가 위임).
        case openRecallLandingFromNotification(recallEventID: UUID)
        /// fetch 된 entry 로 ③ 회수 상세를 push. fetch 실패(404·네트워크)면 조용히 포기(홈 한 칸 fallback).
        case pushRecallDetailFromNotification(RecallFeedEntryDTO)
        case debugInboxChanged(Bool)
        case delegate(Delegate)

        enum Delegate: Sendable {
            case logoutRequested
            case onboardingRequested
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient

    private enum CancelID: Hashable { case notificationOpen, recallLandingOpen, recallRemoval }

    var body: some ReducerOf<Self> {
        Scope(state: \.home,     action: \.home)     { MochiHomeFeature() }
        Scope(state: \.inbox,    action: \.inbox)    { InboxFeature() }
        Scope(state: \.chatLanding, action: \.chatLanding) { ChatLandingFeature() }
        Scope(state: \.mochiCalendar, action: \.mochiCalendar) { MochiCalendarFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            case .searchTabReselected:
                return .send(.search(.clearFiltersTapped))

            case let .home(.mochiItemTapped(mochiItemID, hero)):
                // 이미 상세가 떠 있으면(또는 present 애니메이션 진행 중) 재진입 무시 —
                // presenter 가 중복 present 를 막으므로 state 만 바꾸면 state↔화면이 어긋난다.
                guard state.detail == nil else { return .none }
                // 탭한 카드의 hero frame 을 기억해 거기서 날아오는 hero 전환.
                state.detailHero = hero
                // 이미지 비행이 있으면 상세 hero 이미지를 숨긴 채 시작 — 비행 스냅샷과 이중 노출 방지.
                state.detail = DetailFeature.State(
                    mochiItemID: mochiItemID,
                    heroImageHidden: hero.cardImage != nil
                )
                return .none

            case .home(.openSettingsTapped):
                state.path.append(.settings(SettingsFeature.State()))
                return .none

            case .home(.delegate(.weeklyDigestRequested)):
                state.path.append(.weeklyDigest(WeeklyDigestFeature.State()))
                return .none

            case .home(.delegate(.favoritesRequested)):
                state.path.append(.favorites(FavoritesFeature.State()))
                return .none

            case .home(.delegate(.notificationsPageRequested)):
                // 홈 상단 bell 버튼 → 알림 페이지(예정/지난 2탭) push. 설정·즐겨찾기와 같은 path push.
                state.path.append(.notifications(NotificationsPageFeature.State()))
                return .none

            case .home(.delegate(.searchTabRequested)):
                // 홈 상단 검색 아이콘 → 검색 탭으로 전환(query 없이, 깨끗한 시작). 홈은 회수·큐레이션,
                // 탐색은 검색 탭으로 역할을 분리한다(회의 결정). 재진입 시 이전 필터를 비운다.
                state.selectedTab = .search
                return .send(.search(.clearFiltersTapped))

            case let .chatLanding(.delegate(.conversationRequested(entry))):
                // 랜딩(입력바 모양 버튼·칩·지난 대화) → 대화 풀스크린 push.
                state.path.append(.chat(ChatFeature.State(entry: entry)))
                return .none

            case let .home(.delegate(.recallListRequested(entries))):
                // 회수 히어로 "모두 보기" → ② 자세히(통일 카드 목록) push. 홈이 들고 있던 피드를 그대로 넘겨
                // 즉시 그린다(목록 화면 onAppear 가 백그라운드 최신화).
                state.path.append(.recallList(RecallListFeature.State(entries: entries)))
                return .none

            case let .home(.delegate(.recallItemOpened(itemID, hero))):
                // 회수 히어로 카드 탭 → 그 기록의 원본 상세로 hero zoom 직행(최근 카드와 같은 확대 전환).
                // itemID 는 server PK — 기존 알림 경로(로컬 역매핑 + 미존재 시 pullRemote 재시도)에 hero 를
                // 실어 보존한다. 역매핑이 끝날 때까지 카드는 화면에 남아(즉시 제거 안 함) 비행 출발점이 유효하다.
                // 닫힐 때 이 카드만 정확히 빼도록 server PK 를 기억해 둔다.
                state.detailFromRecallItemID = itemID
                return .send(.openDetailFromNotification(serverID: itemID, hero: hero))

            case let .home(.delegate(.categoryCarouselRequested(bucket))):
                // 카테고리 카드 탭 → 그 서랍을 3D 턴테이블로 push. 홈이 집계한 묶음을 그대로 넘겨 즉시 그린다.
                state.path.append(.categoryCarousel(CategoryCarouselFeature.State(bucket: bucket)))
                return .none

            case let .path(.element(id: _, action: .categoryCarousel(.delegate(.openItem(itemID, hero))))):
                // 턴테이블 초점 커버 탭 → 그 커버 frame 에서 상세로 hero 확대(홈 카드와 같은 zoom present).
                // itemID 는 로컬 id 라 server PK 역매핑 불필요. hero 없으면(드물게) 중앙 scale 폴백.
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(
                    mochiItemID: itemID,
                    heroImageHidden: hero?.cardImage != nil
                )
                return .none

            case let .path(.element(id: _, action: .recallList(.delegate(.openDetail(entry))))):
                // 통일 카드 탭 → ③ 회수 상세 push.
                state.path.append(.recallDetail(RecallDetailFeature.State(entry: entry)))
                return .none

            case let .path(.element(id: _, action: .recallDetail(.delegate(.openOriginal(itemID))))):
                // 회수 상세 "원본 보기" → 원본 mochiItem 상세 present(server PK 역매핑은 기존 경로 재사용).
                // 카드 frame 출처가 없어 hero nil → 중앙 scale 폴백.
                return .send(.openDetailFromNotification(serverID: itemID, hero: nil))

            case let .path(.element(id: _, action: .recallDetail(.delegate(.openRelated(itemID))))):
                // 회수 상세 "관련 기억" 카드 탭 → 그 항목 상세 present(원본 보기와 같은 server PK 역매핑 경로).
                return .send(.openDetailFromNotification(serverID: itemID, hero: nil))

            case let .path(.element(id: _, action: .weeklyDigest(.delegate(.mochiItemTapped(mochiItemID, hero))))):
                // 정리 화면의 항목 탭 → 상세 present (캘린더처럼 hero 없으면 중앙 scale 폴백).
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .path(.element(id: _, action: .weeklyDigest(.delegate(.categoryViewAllRequested(category))))):
                // 리포트 카테고리 레일 "전체 보기" → 정리 화면을 닫고 검색 탭을 그 카테고리로 필터해 연다
                // (회수 "찾기"는 검색이 담당 — seeAllRecentRequested 와 같은 위임 패턴).
                state.path.removeAll()
                state.selectedTab = .search
                state.search.query = ""
                state.search.selectedCategory = category
                return .none

            case let .path(.element(id: _, action: .favorites(.delegate(.mochiItemTapped(mochiItemID, hero))))):
                // 즐겨찾기 화면의 항목 탭 → 상세 present (정리 화면과 같은 경로).
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(
                    mochiItemID: mochiItemID,
                    heroImageHidden: hero?.cardImage != nil
                )
                return .none

            case .inbox(.mochiItemTapped):
                // dev 디버그 인박스 — push 전환 범위에서 제외(상세 진입 비활성).
                return .none

            case let .mochiCalendar(.mochiItemTapped(mochiItemID, hero)):
                guard state.detail == nil else { return .none }
                // DaySheet 는 열어둔 채 그 위로 상세를 hero present — presenter 가 최상단
                // presented VC 위에서 띄우므로 sheet 와 충돌하지 않고, 상세를 닫으면
                // 보던 날짜 목록으로 그대로 돌아온다. hero 없으면 중앙 scale 폴백.
                state.detailHero = hero
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .search(.recentTapped(mochiItemID, hero)):
                // 홈 카드와 동일한 hero present — 검색 카드 frame 에서 확대.
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(
                    mochiItemID: mochiItemID,
                    heroImageHidden: hero?.cardImage != nil
                )
                return .none

            case let .search(.delegate(.askChatRequested(query))):
                // 검색 빈 결과 "모찌에게 물어보기" — 채팅을 query 첫 메시지로 push (홈 입력바와 동일 패턴).
                state.path.append(.chat(ChatFeature.State(entry: .firstMessage(query))))
                return .none

            case let .path(.element(id: _, action: .chat(.delegate(.openItemRequested(mochiItemID))))):
                // 채팅 근거 미니카드 탭 — hero frame 이 없어 중앙 scale 폴백 (캘린더와 동일).
                guard state.detail == nil else { return .none }
                state.detailHero = nil
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .debugInboxChanged(isOn):
                state.isDebugInboxPresented = isOn
                return .none

            case .path(.element(id: _, action: .settings(.delegate(.logoutRequested)))):
                // 설정 화면을 닫고 로그아웃을 상위(RootFeature.requestSignOut)로 위임.
                state.path.removeAll()
                return .send(.delegate(.logoutRequested))

            case .home(.delegate(.onboardingRequested)),
                 .path(.element(id: _, action: .settings(.delegate(.onboardingRequested)))):
                return .send(.delegate(.onboardingRequested))

            case .detail(.presented(.delegate(.deleted))),
                 .detail(.presented(.delegate(.closeRequested))):
                // 상세에서 삭제 완료 / 닫기 → custom present 를 닫는다 (state nil → presenter dismiss).
                // 여기서 nil 로 두는 시점이 dismiss 비행 **시작** — 비행(~0.45s)이 카드 자리에 착지할 시간을
                // 준 뒤 그 회수 카드를 뺀다(돌아왔다 사라진다). 닫는 itemID 를 캡처해 보내므로 480ms 사이
                // 다른 회수 카드를 열어도 그 카드는 안 빠진다. 회수 아닌 상세면 recallID nil → no-op.
                state.detail = nil
                guard let recallID = state.detailFromRecallItemID else { return .none }
                state.detailFromRecallItemID = nil
                return .run { send in
                    try? await Task.sleep(for: .milliseconds(480))
                    await send(.home(.recallDetailClosed(itemID: recallID)), animation: .spring(response: 0.45, dampingFraction: 0.85))
                }
                .cancellable(id: CancelID.recallRemoval, cancelInFlight: true)

            case .detail(.dismiss):
                // 드래그로 닫음 — ZoomDetailPresentation 이 비행을 먼저 끝낸 뒤 binding 을 비웠다(카드 자리에
                // 이미 착지). 곧바로 그 회수 카드를 뺀다(닫은 itemID 캡처). 회수 아닌 상세면 recallID nil → no-op.
                guard let recallID = state.detailFromRecallItemID else { return .none }
                state.detailFromRecallItemID = nil
                return .send(.home(.recallDetailClosed(itemID: recallID)), animation: .spring(response: 0.45, dampingFraction: 0.85))

            case let .detail(.presented(.delegate(.openSimilar(localID)))):
                // 비슷한 기록 탭(root 상세) → 닫지 않고 같은 상세의 push 스택에 그 항목을 쌓는다(앞으로 push).
                // 오른쪽에서 밀려 들어오고, 시스템 back/엣지 스와이프로 이전 상세에 복귀한다(A→B→C 재귀).
                // 자손 상세에서의 탭은 DetailFeature 가 자기 path 로 직접 흡수해 여기까지 오지 않는다.
                state.detail?.path.append(DetailFeature.State(mochiItemID: localID))
                return .none

            case let .openDetailFromNotification(serverID, hero):
                // 알림 페이로드는 server PK — 로컬 행으로 역매핑한 뒤 present 한다. 보통 로컬에 이미
                // 있어 즉시 열리지만, 재설치 직후·타기기 생성 항목이면 RootFeature 의 pullRemote 가
                // 항목을 끌어올 때까지 짧게(최대 ~2.5s) 재시도한다. 끝내 없으면 조용히 포기 —
                // 홈 버킷이 always-on fallback. 연속 탭은 cancelInFlight 로 마지막 탭만 연다.
                return .run { send in
                    for attempt in 0..<6 {
                        if let item = try? await repository.find(serverID: serverID) {
                            await send(.presentDetailFromNotification(localID: item.id, hero: hero))
                            return
                        }
                        if attempt < 5 { try? await Task.sleep(for: .milliseconds(500)) }
                    }
                }
                .cancellable(id: CancelID.notificationOpen, cancelInFlight: true)

            case let .presentDetailFromNotification(localID, hero):
                // 같은 항목 상세가 이미 떠 있으면 그대로 둔다(재present 시 화면 깜빡임만 생긴다).
                if state.detail?.mochiItemID == localID { return .none }
                // 다른 상세가 떠 있으면 닫고, dismiss 가 끝난 뒤 그 항목으로 새로 연다. 새 State 라 push 스택도
                // 깨끗이 리셋된다. 교체 중 dismiss/present 경합은 ZoomDetailPresentation 이 finishPendingDismiss
                // 로 흡수한다. 360ms 슬립 사이 사용자가 또 다른 카드를 열면 그 탭을 존중해 알림 항목은
                // 양보한다(cancelInFlight, 알림 직후 앱 전환 중이라 드문 경합).
                if state.detail != nil {
                    state.detail = nil
                    state.detailHero = nil
                    return .run { send in
                        try? await Task.sleep(for: .milliseconds(360))
                        await send(.presentDetailFromNotification(localID: localID, hero: hero))
                    }
                    .cancellable(id: CancelID.notificationOpen, cancelInFlight: true)
                }
                // 회수·턴테이블 카드는 hero 를 실어 hero zoom(이미지 비행이 있으면 상세 hero 이미지를 숨긴 채
                // 시작 — 이중 노출 방지). 알림 진입처럼 hero 가 nil 이면 중앙 scale 폴백.
                state.detailHero = hero
                state.detail = DetailFeature.State(
                    mochiItemID: localID,
                    heroImageHidden: hero?.cardImage != nil
                )
                return .none

            case let .openRecallLandingFromNotification(recallEventID):
                // 회수 알림 landing — recallEventID 로 단건 entry 를 서버 fetch 해 ③ 상세를 push 한다
                // (로컬 피드에 없을 수 있어 항상 fetch — 빈 상세 금지, codex-2). 404·네트워크 실패면
                // 조용히 포기(홈 한 칸이 always-on fallback). 연속 탭은 cancelInFlight 로 마지막만.
                // 알림 탭 = opened(양성)는 fetch·effect 취소 둘 다와 분리한다 — 별도 비취소
                // fire-and-forget effect 라 다음 알림 탭의 cancelInFlight 가 이전 opened POST 를
                // in-flight 중 취소하지 못한다. landing push 는 alreadyReportedOpen:true 라 이 보고가
                // 그 알림의 유일한 opened 경로 → 취소로 유실되면 복구 불가(codex). best-effort(try?)
                // 라 네트워크 실패엔 양보하되 취소로는 유실되지 않는다(reaction 1:1 정확도).
                let reportOpened = Effect<Action>.run { _ in
                    try? await apiClient.recordRecallReaction(eventID: recallEventID, reaction: .opened)
                }
                let fetchLanding = Effect<Action>.run { send in
                    if let entry = try? await apiClient.recallLanding(eventID: recallEventID) {
                        await send(.pushRecallDetailFromNotification(entry))
                    }
                }
                .cancellable(id: CancelID.recallLandingOpen, cancelInFlight: true)
                return .merge(reportOpened, fetchLanding)

            case let .pushRecallDetailFromNotification(entry):
                // 이미 같은 회수 event 상세가 최상단이면 재push 안 함(중복 방지). 같은 item 이라도 다른
                // recallEventID(새 알림)면 교체해 최신 event 를 띄운다.
                if case .recallDetail(let top) = state.path.last,
                   top.entry.recallEventID == entry.recallEventID,
                   top.entry.itemID == entry.itemID {
                    return .none
                }
                // opened 는 위 landing effect 에서 이미 보고했으니 상세 onAppear 의 중복 보고는 건너뛴다.
                state.path.append(.recallDetail(RecallDetailFeature.State(entry: entry, alreadyReportedOpen: true)))
                return .none

            case .home, .inbox, .chatLanding, .mochiCalendar, .search, .path, .mochiItem, .detail, .delegate:
                return .none

            case .tabSelected, .searchTabReselected:
                // 위에서 명시 처리됨 — Swift exhaustive 매칭 만족용 (실제 도달 X).
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
        .ifLet(\.$detail, action: \.detail) { DetailFeature() }
    }
}

extension MainTabFeature {
    /// 네비게이션 destination — 설정·이번주 정리·대화. 설정을 sheet 가 아닌 push 로 둬,
    /// 설정 위에 온보딩 fullScreenCover 를 띄울 때 "single sheet" 충돌을 피한다.
    /// (상세는 path 가 아니라 `@Presents var detail` 로 별도 custom present.)
    @Reducer
    enum Path {
        case settings(SettingsFeature)
        case weeklyDigest(WeeklyDigestFeature)
        case favorites(FavoritesFeature)
        /// 대화 풀스크린 — 탭바를 덮는 push (랜딩·홈 입력바가 Entry 를 들고 연다).
        case chat(ChatFeature)
        /// 능동 회수 ② 자세히(통일 카드 목록) — 홈 "한 칸"에서 push.
        case recallList(RecallListFeature)
        /// 능동 회수 ③ 기록 상세 — 목록 탭 / 알림 landing 직행.
        case recallDetail(RecallDetailFeature)
        /// 카테고리 3D 턴테이블 — 홈 "이런 걸 모아두셨어요" 카드에서 push.
        case categoryCarousel(CategoryCarouselFeature)
        /// 알림 페이지(예정/지난 2탭) — 홈 상단 bell 버튼에서 push.
        case notifications(NotificationsPageFeature)
    }
}

// @Reducer enum 이 합성하는 Path.State 는 Equatable 을 자동 부여하지 않으므로 명시한다.
// (associated value 인 DetailFeature.State·SettingsFeature.State 가 모두 Equatable 이라 합성 가능)
extension MainTabFeature.Path.State: Equatable {}
