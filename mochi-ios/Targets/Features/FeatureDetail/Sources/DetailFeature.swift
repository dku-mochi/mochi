import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking

@Reducer
public struct DetailFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var mochiItemID: UUID
        public var mochiItem: MochiItem?
        /// "비슷한 기록" — 서버 cosine 이웃 중 로컬에 있는 항목만(카드 렌더용). 빈 배열이면 섹션 숨김.
        public var similar: [SimilarItemPreview] = []
        /// 제목 인라인 교정 중 여부 — RecallHeader 가 Text ↔ TextField 전환.
        public var isEditingTitle: Bool = false
        public var titleDraft: String = ""
        public var lastError: String?
        /// 이미지 저장 성공 후 잠깐 보이는 확인 메시지 — 2초 뒤 자동 사라짐.
        public var saveToast: String?
        /// 삭제 확인 alert — confirm 시 서버 soft delete + 로컬 hard delete 후 화면 pop.
        @Presents public var deleteAlert: AlertState<Action.Alert>?
        /// hero 전환 중 상세 hero 이미지를 숨긴다 — 비행 중인 스냅샷과 이중으로 겹쳐 보이지 않게.
        /// 비행이 있는 진입은 true 로 시작 → 비행 스냅샷이 사라질 때 App 이 false 로 켠다.
        public var heroImageHidden: Bool = false

        public init(mochiItemID: UUID, heroImageHidden: Bool = false) {
            self.mochiItemID = mochiItemID
            self.heroImageHidden = heroImageHidden
        }
    }

    public enum Action: Sendable {
        case onAppear
        case loaded(MochiItem?)
        /// 비슷한 기록 로드 완료 — 빈 배열이면 뷰가 섹션을 렌더하지 않는다.
        /// 첫 인자는 요청 시점의 mochiItemID — 같은 present 슬롯이 다른 항목으로 갈아끼워졌을 때
        /// stale 결과가 적용되지 않게 가드한다.
        case similarLoaded(UUID, [SimilarItemPreview])
        /// 비슷한 기록 카드 탭 — 그 항목의 상세로 이동(부모가 present 소유라 위임).
        case similarItemTapped(UUID)
        /// 할 일 완료↔미완료 토글 — 캘린더 탭과 같은 경로(낙관적 로컬 + 서버 push + 치유/롤백).
        case todoToggled(IntentInstance)
        /// 즐겨찾기 토글 — 낙관적 로컬 전이 + 서버 push(실패 시 롤백). 완료 토글과 같은 경로.
        case favoriteToggled
        // 제목 인라인 교정 — 로컬 userTitle 오버라이드 (백엔드 재추론 아님).
        case titleTapped
        case titleDraftChanged(String)
        case titleCommitted
        case titleEditCancelled
        case operationFailed(String)
        // 이미지 저장 — 더보기 메뉴 → 사진 앱에 원본 풀해상도 저장(권한 거부·소스 없음은 operationFailed).
        case saveImageButtonTapped
        case imageSaved
        case dismissSaveToast
        // 삭제 — 더보기 메뉴 → 확인 alert → 서버 soft delete + 로컬 hard delete → 화면 닫힘.
        case deleteButtonTapped
        case deleteAlert(PresentationAction<Alert>)
        // 닫기(X) 버튼 — custom present 를 닫도록 상위에 위임.
        case closeButtonTapped
        // hero 전환 중 상세 이미지 표시/숨김 — App(ZoomDetailPresentation)이 비행 타이밍에 맞춰 토글.
        case setHeroImageHidden(Bool)
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete
        }
        public enum Delegate: Equatable, Sendable {
            case deleted
            case closeRequested
            /// 비슷한 기록 카드 탭 → 부모가 그 항목으로 새 상세를 present (재귀 present 회피).
            case openSimilar(UUID)
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient

    private enum CancelID: Hashable { case favorite(UUID) }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { [id = state.mochiItemID] send in
                    let mochiItem = try await repository.find(id: id)
                    await send(.loaded(mochiItem))

                    // 비슷한 기록 — 업로드된(서버 id 있는) 항목만 조회한다. 미업로드 로컬 항목은
                    // 서버 embedding 이 없어 호출을 생략한다. 실패·빈 결과 → 섹션 숨김(no-op).
                    guard let mochiItem, case let .uploaded(serverID, _) = mochiItem.syncState else { return }
                    let refs = (try? await apiClient.similarItems(serverID: serverID, limit: 6)) ?? []
                    guard !refs.isEmpty else { return }
                    // 서버 id → 로컬 MochiItem 매핑(로컬에 있는 항목만 카드로 렌더 — 응답은 id+score+reasons
                    // 만 주므로). 다른 기기에서만 만든 항목은 로컬에 없어 스킵된다.
                    let locals = (try? await repository.listRecent(limit: 2000)) ?? []
                    var byServer: [UUID: MochiItem] = [:]
                    for local in locals {
                        if case let .uploaded(sid, _) = local.syncState { byServer[sid] = local }
                    }
                    let previews = refs.compactMap { ref -> SimilarItemPreview? in
                        byServer[ref.mochiItemID].map { SimilarItemPreview(item: $0, reasons: ref.reasons) }
                    }
                    await send(.similarLoaded(id, previews))
                }

            case let .loaded(mochiItem):
                state.mochiItem = mochiItem
                return .none

            case let .similarLoaded(requestID, previews):
                // stale 가드 — 요청 후 슬롯이 다른 항목으로 갈아끼워졌으면 버린다.
                guard requestID == state.mochiItemID else { return .none }
                state.similar = previews
                return .none

            case let .similarItemTapped(localID):
                return .send(.delegate(.openSimilar(localID)))

            case let .todoToggled(instance):
                guard let item = state.mochiItem else { return .none }
                let isCompleted = instance.lifecycle.kind == .archived
                let target: InstanceLifecycle = isCompleted ? .active : .archived(reason: .todoCompleted)
                return .run { send in
                    // 낙관적 로컬 전이 + 즉시 reload — 상세는 observeChanges 미구독이라
                    // state.mochiItem 을 직접 갱신해야 토글이 화면에 보인다.
                    try? await repository.updateInstanceLifecycle(
                        mochiItemID: item.id, instanceID: instance.id, to: target
                    )
                    await send(.loaded(try? await repository.find(id: item.id)))
                    // 서버 push(+레거시 instance id 치유, 실패 시 로컬 롤백) — 캘린더 탭과 공용 경로.
                    let failure = await TodoLifecycleSync.pushToggle(
                        item: item, instance: instance, target: target,
                        repository: repository, apiClient: apiClient
                    )
                    // 치유 교정·롤백 결과 반영.
                    await send(.loaded(try? await repository.find(id: item.id)))
                    if let failure { await send(.operationFailed(failure)) }
                }

            case .favoriteToggled:
                guard let item = state.mochiItem else { return .none }
                let target = !item.isFavorite
                // 동기 낙관 반영 — 연타 시 다음 탭이 갱신된 값 기준으로 target 을 잡아 on/off 가 어긋나지 않는다.
                state.mochiItem?.isFavorite = target
                return .run { send in
                    try? await repository.setFavorite(mochiItemID: item.id, isFavorite: target)
                    // 서버 push(실패 시 FavoriteSync 가 로컬 롤백) — 검색 카드와 공용 경로.
                    let failure = await FavoriteSync.pushToggle(
                        item: item, isFavorite: target, repository: repository, apiClient: apiClient
                    )
                    if let failure {
                        await send(.loaded(try? await repository.find(id: item.id)))  // 롤백 반영
                        await send(.operationFailed(failure))
                    }
                }
                // 연타 시 직전 in-flight push 를 취소(cancelInFlight) → 최신 토글만 살아 last-write-wins.
                // 취소된 오래된 요청의 롤백이 최신 의도를 덮어쓰지 않는다.
                .cancellable(id: CancelID.favorite(item.id), cancelInFlight: true)

            case .titleTapped:
                state.titleDraft = state.mochiItem?.displayHeadline ?? ""
                state.isEditingTitle = true
                return .none

            case let .titleDraftChanged(text):
                // 리턴 키 = 완료 — axis .vertical TextField 는 리턴이 개행으로 들어와 onSubmit 이
                // 안 불릴 수 있다(여러 줄로 감긴 제목). 제목에 개행은 의미가 없으므로
                // 개행 감지 시 공백으로 합치고 커밋한다(붙여넣기 멀티라인도 동일 처리).
                if text.contains("\n") {
                    state.titleDraft = text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    return .send(.titleCommitted)
                }
                state.titleDraft = text
                return .none

            case .titleCommitted:
                guard let id = state.mochiItem?.id else { return .none }
                let trimmed = state.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let newTitle = trimmed.isEmpty ? nil : trimmed
                state.isEditingTitle = false
                state.mochiItem?.userTitle = newTitle   // 낙관적 로컬 반영 (상세는 observe 미구독)
                return .run { send in
                    do {
                        try await repository.setUserTitle(mochiItemID: id, title: newTitle)
                    } catch {
                        // 저장 실패 시 낙관 반영을 DB 진실로 되돌린다 (상세는 observe 미구독이라 자동 복구 안 됨).
                        await send(.loaded(try? await repository.find(id: id)))
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .titleEditCancelled:
                state.isEditingTitle = false
                state.titleDraft = ""
                return .none

            case .saveImageButtonTapped:
                guard let ref = state.mochiItem?.source.imageRefs.first else {
                    return .send(.operationFailed(ScreenshotSaver.SaveError.noImage.localizedDescription))
                }
                return .run { send in
                    do {
                        try await ScreenshotSaver.saveToPhotos(ref: ref, apiClient: apiClient)
                        await send(.imageSaved)
                    } catch {
                        await send(.operationFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
                    }
                }

            case .imageSaved:
                state.lastError = nil
                state.saveToast = "사진에 저장했어요"
                return .run { send in
                    try? await Task.sleep(for: .seconds(2))
                    await send(.dismissSaveToast)
                }

            case .dismissSaveToast:
                state.saveToast = nil
                return .none

            case let .operationFailed(message):
                state.lastError = message
                return .none

            case .deleteButtonTapped:
                state.deleteAlert = AlertState {
                    TextState("기록을 삭제할까요?")
                } actions: {
                    ButtonState(role: .destructive, action: .confirmDelete) { TextState("삭제") }
                    ButtonState(role: .cancel) { TextState("취소") }
                } message: {
                    TextState("삭제한 기록은 되돌릴 수 없어요.")
                }
                return .none

            case .deleteAlert(.presented(.confirmDelete)):
                guard let item = state.mochiItem else { return .none }
                let localID = item.id
                // 업로드된(서버에 존재하는) 항목만 서버 soft delete. 미업로드면 로컬만 지운다.
                let serverID: UUID? = {
                    if case let .uploaded(sid, _) = item.syncState { return sid }
                    return nil
                }()
                return .run { send in
                    do {
                        if let serverID {
                            try await apiClient.deleteMochiItem(mochiServerID: serverID)
                        }
                        try await repository.delete(id: localID)
                        // pull↔upload 경합 복제 쌍 방어(양방향) — 같은 서버 항목으로 매핑되는
                        // 다른 로컬 행(origin: uploaded(serverID) / pull 복제: PK == serverID,
                        // syncState 도 uploaded(serverID)라 같은 스캔에 잡힘)을 전부 거둔다.
                        // 한 행만 지우면 남은 쪽이 영구 고아로 홈에 잔존(없으면 no-op).
                        if let serverID {
                            let all = (try? await repository.listRecent(limit: 2000)) ?? []
                            for item in all where item.id != localID {
                                if case let .uploaded(sid, _) = item.syncState, sid == serverID {
                                    try? await repository.delete(id: item.id)
                                }
                            }
                        }
                        await send(.delegate(.deleted))
                    } catch {
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .deleteAlert:
                return .none

            case .closeButtonTapped:
                return .send(.delegate(.closeRequested))

            case let .setHeroImageHidden(hidden):
                state.heroImageHidden = hidden
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$deleteAlert, action: \.deleteAlert)
    }
}

/// "비슷한 기록" 카드 1건 — 서버가 고른 이웃의 로컬 MochiItem + 왜 비슷한지 근거.
/// 카드는 로컬 항목으로 렌더하고(썸네일·형태·제목), 근거 칩만 서버 신호를 쓴다.
public struct SimilarItemPreview: Equatable, Sendable, Identifiable {
    public let item: MochiItem
    public let reasons: [SimilarReason]
    public var id: UUID { item.id }

    public init(item: MochiItem, reasons: [SimilarReason]) {
        self.item = item
        self.reasons = reasons
    }
}
