import Foundation
import CoreDomain
import CoreNetworking
import Dependencies

/// 로컬에 ingest 된 mochiItem 를 백엔드 `/api/v1/mochi_items` 에 업로드하는 워커.
///
/// **동작:**
/// 1. ``AuthTokenProvider.bearerToken()`` 이 nil 이면 즉시 종료 (미인증 사용자가 백탭 snippet 으로
///    Realm `.pendingUpload` 만 박아둔 상태일 수 있음 — 무인증 ingest 는 401 받고 `.syncFailed` 로
///    영구 strand 됨). 로그인 후 다음 active tick 에 다시 시도된다.
/// 2. ``MochiItemRepository.listRecent`` 에서 `syncState == .pendingUpload` 인 항목을 가져옴
/// 3. 백탭 흐름 (`.screenshot` + 단일 이미지) 은 multipart `back-tap` 으로, 그 외는 metadata-only ingest
/// 4. 성공 시 `syncState=.uploaded(serverID, at)` 로 업데이트
/// 5. 실패 시 transient 면 backoff, 영구 실패면 `syncFailed(reason, retryAfter)` 로 업데이트
///
/// 멱등키는 `MochiItem.id.uuidString` 자체를 사용한다 — 같은 항목을 두 번 올려도 백엔드가 같은 행을 반환.
public actor MochiItemSyncWorker {
    private let repository: any MochiItemRepository
    private let apiClient: any MochiAPIClient
    private let tokenProvider: any AuthTokenProvider
    private var isRunning = false
    /// foreground 동안만 도는 metadata-only 분석 폴링 루프. background 진입 시 cancel.
    private var pollTask: Task<Void, Never>?

    /// Live Activity trigger — 백탭 multipart 분기에서 `.analyzing` / `.ready` / `end` 호출.
    /// DI 미주입 시 `NotConfiguredLiveActivityCoordinator` 가 no-op.
    @Dependency(\.liveActivityCoordinator) private var liveActivity

    public init(
        repository: any MochiItemRepository,
        apiClient: any MochiAPIClient,
        tokenProvider: any AuthTokenProvider
    ) {
        self.repository = repository
        self.apiClient = apiClient
        self.tokenProvider = tokenProvider
    }

    public func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // 미인증 skip — 무인증 ingest 는 401 → `.syncFailed` 영구 strand 를 만든다.
        // `.pendingUpload` 로 그대로 두면 다음 인증된 active tick 이 처리.
        guard await tokenProvider.bearerToken() != nil else { return }

        let pending: [MochiItem]
        do {
            // `.pendingUpload` 와 `.syncFailed` 모두 retry 대상 — dev 단계라 backoff 없이
            // 매 tick (scenePhase active + refresh 트리거) 단순 retry. production 격상 시
            // `.syncFailed` 의 retryAfter 또는 backoff 정책 도입 (`docs/TODO.md` §3.4).
            pending = try await repository.listRecent(limit: 200).filter {
                if case .pendingUpload = $0.syncState { return true }
                if case .syncFailed = $0.syncState { return true }
                return false
            }
        } catch {
            return
        }

        for mochiItem in pending {
            await uploadOne(mochiItem)
        }
    }

    private func uploadOne(_ mochiItem: MochiItem) async {
        do {
            try? await repository.updateSync(mochiItemID: mochiItem.id, to: .uploading)

            // 백탭 흐름 (`.screenshot` channel + 단일 이미지) 은 multipart back-tap endpoint 로
            // PNG bytes 를 직접 보내 백엔드가 Gemini 분류까지 즉시 수행한다.
            // 그 외 (외부 공유시트, AppIntent 텍스트 등) 는 metadata-only ingest.
            let serverID: UUID
            if mochiItem.source.channel == .screenshot,
               let imageRef = mochiItem.source.imageRefs.first,
               mochiItem.source.imageRefs.count == 1,
               let pngData = readImageBytes(imageRef.relativePath) {
                // 분석 시작 시각 Live Activity 점유 — 사용자가 Lock Screen / Dynamic Island 에서
                // "분류 중" 진행을 본다. caption 에 mochiItemID prefix 박아 후속 update 매칭.
                let caption = liveActivityCaption(
                    mochiItemID: mochiItem.id,
                    body: mochiItem.source.userMemo?.prefix(40).description ?? "스크린샷 분석 중"
                )
                await liveActivity.startAnalyzing(
                    mochiItemID: mochiItem.id,
                    caption: caption,
                    thumbnailRelativePath: imageRef.relativePath
                )

                let response = try await apiClient.ingestBackTapMochiItem(
                    pngData: pngData,
                    mimeType: imageRef.mimeType,
                    userMemo: mochiItem.source.userMemo,
                    idempotencyKey: mochiItem.id.uuidString
                )
                serverID = response.item.id
                await applyClassification(to: mochiItem.id, response: response)

                // 응답의 candidates 로 Live Activity `.ready` transition — 사용자 선택 대기.
                // 멱등 replay 인 경우 candidates 가 빈 배열이라 LA end 로 폴백.
                if !response.candidates.isEmpty {
                    let liveCandidates = response.candidates.map {
                        LiveActivityCandidate(
                            label: $0.label,
                            intent: $0.intent.rawValue,
                            applicability: $0.applicability
                        )
                    }
                    await liveActivity.transitionToReady(
                        mochiItemID: mochiItem.id,
                        candidates: liveCandidates
                    )
                } else {
                    await liveActivity.endIfActive(mochiItemID: mochiItem.id, failed: false)
                }
            } else {
                let request = MochiItemIngestRequest(
                    channel: mochiItem.source.channel,
                    url: mochiItem.source.url,
                    text: mochiItem.source.text,
                    userMemo: mochiItem.source.userMemo,
                    imageRefs: mochiItem.source.imageRefs.map { ImageRefDTO(
                        objectKey: $0.objectKey,
                        mimeType: $0.mimeType,
                        byteSize: $0.byteSize,
                        sha256: $0.sha256
                    ) }
                )
                let dto = try await apiClient.ingestMochiItem(request, idempotencyKey: mochiItem.id.uuidString)
                serverID = dto.id
            }
            try await repository.updateSync(
                mochiItemID: mochiItem.id,
                to: .uploaded(serverID: serverID, at: Date())
            )
        } catch let envelope as APIErrorEnvelope {
            try? await repository.updateSync(
                mochiItemID: mochiItem.id,
                to: .syncFailed(reason: "[\(envelope.code)] \(envelope.message)", retryAfter: nil)
            )
            await liveActivity.endIfActive(mochiItemID: mochiItem.id, failed: true)
        } catch {
            try? await repository.updateSync(
                mochiItemID: mochiItem.id,
                to: .syncFailed(reason: String(describing: error), retryAfter: nil)
            )
            await liveActivity.endIfActive(mochiItemID: mochiItem.id, failed: true)
        }
    }

    /// `relativePath` 는 `RealmImageRef.relativePath` (예: `captures/<filename>`). App Group container
    /// 기준으로 절대 경로 조립 후 bytes 를 읽는다. 파일이 없거나 읽기 실패 시 nil.
    private func readImageBytes(_ relativePath: String) -> Data? {
        let url = AppGroup.containerURL.appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }

    /// 분석 결과(intent / summary / importance / confidence / **후보**)를 Realm 의
    /// ``MochiItem.analysis`` 에 반영하는 공통 writer. back-tap(동기) 과 metadata-only(폴링) 양쪽이 쓴다.
    ///
    /// `candidates` 는 홈 "모찌가 헷갈려요" 카드 버튼의 원천이며, `topGap` 영속화(매퍼)와 함께
    /// 불확실성 판정(`MochiItemAnalysis.isUncertain`)을 가능케 한다.
    ///
    /// `lifecycleState` 는 `.active` 로 직접 박는다. `repository.upsert` 는 `LifecyclePolicy.validate`
    /// 를 거치지 않아 `.ingested → .active` 직접 전이가 가능 (분류 결과 즉시 반영을 위한 의식적 우회).
    /// 버킷(분석중/헷갈려요/자동정리)은 lifecycle 이 아니라 analysis 의 intent/confidence/topGap 에서 derive 한다.
    private func applyAnalysis(
        to mochiItemID: UUID,
        intent: Intent,
        summary: String,
        importance: Int,
        confidence: Double,
        candidates: [IntentCandidate],
        expectedUpdatedAt: Date? = nil
    ) async {
        guard var current = try? await repository.find(id: mochiItemID) else { return }
        // 세대 가드(폴링 경로): GET 을 await 하는 사이 수동 분류(setIntent)·재시도(requeue)가
        // 끼어들 수 있다. 스냅샷 이후 항목이 바뀌었으면 stale 결과로 덮지 않는다.
        if let expectedUpdatedAt, current.updatedAt != expectedUpdatedAt { return }
        current.analysis = MochiItemAnalysis(
            summary: summary,
            intent: intent,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: MochiItemAnalysis.Importance(rawValue: importance) ?? .medium,
            confidence: confidence,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date(),
            candidates: candidates
        )
        current.lifecycleState = .active
        try? await repository.upsert(current)
    }

    /// 백탭 multipart 응답 → 공통 writer. candidates 의 한국어 라벨("구매 고민" 등)을 보존한다.
    /// 멱등 replay 로 candidates 가 비면 라벨 없이 confidence 만으로 판정된다.
    private func applyClassification(
        to mochiItemID: UUID,
        response: BackTapMochiItemResponseDTO
    ) async {
        let dto = response.item
        guard let intent = dto.intent else { return }
        let candidates = response.candidates.map {
            IntentCandidate(label: $0.label, intent: $0.intent, applicability: $0.applicability)
        }
        // summary 가 비면 첫 후보 라벨을 fallback (홈/Inbox 가 보여줄 첫 텍스트).
        let summary = (dto.summary?.isEmpty == false ? dto.summary! : response.candidates.first?.label) ?? ""
        await applyAnalysis(
            to: mochiItemID,
            intent: intent,
            summary: summary,
            importance: dto.importance,
            confidence: dto.confidence,
            candidates: candidates
        )
    }

    // MARK: - metadata-only 분석 폴링 (foreground 한정)

    /// foreground 동안 `interval` 초마다 metadata-only 항목의 분석 상태를 백엔드에서 재조회한다.
    /// 이미 돌고 있으면 무시. background 진입 시 ``stopForegroundPolling()`` 으로 중단한다.
    public func startForegroundPolling(every interval: Double = 3) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAnalysisOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopForegroundPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 업로드됐으나(syncState == .uploaded) 아직 분석이 안 붙은(analysis == nil) metadata-only 항목을
    /// `GET /mochi_items/{id}` 로 재조회해, 백엔드 분석이 끝났으면(lifecycle == active) 결과를 반영한다.
    /// back-tap 스크린샷은 동기 분류로 이미 analysis 가 있어 대상에서 자동 제외된다.
    public func pollAnalysisOnce() async {
        guard await tokenProvider.bearerToken() != nil else { return }
        let pending: [MochiItem]
        do {
            pending = try await repository.listRecent(limit: 200).filter { item in
                guard item.analysis == nil else { return false }
                if case .uploaded = item.syncState { return true }
                return false
            }
        } catch {
            return
        }
        for item in pending {
            if Task.isCancelled { return }
            // 서버 PK 는 iOS 로컬 id 와 다르다 — 백엔드 ingest 가 자체 uuid4 를 부여하고
            // iOS UUID 는 Idempotency-Key 로만 쓰인다. 업로드 응답에서 받은 serverID 로 조회한다.
            // (로컬 id 로 GET 하면 404 → 무한 폴링.)
            guard case let .uploaded(serverID, uploadedAt) = item.syncState else { continue }
            let expired = Date().timeIntervalSince(uploadedAt) > Self.analysisPollDeadline

            guard let dto = try? await apiClient.getMochiItem(id: serverID) else {
                // GET 실패(네트워크/404 등): deadline 초과면 give-up, 아니면 다음 tick 재시도.
                if expired { await demoteToManual(item) }
                continue
            }

            // 백엔드가 분석을 끝내면 lifecycle 이 active 로 전이한다. 그 전엔 intent 가 MEMO 기본값일
            // 수 있으므로 lifecycle 로 "분석 완료"를 판정한다.
            switch dto.lifecycleKind {
            case "active":
                guard let intent = dto.intent else { continue }
                await applyAnalysis(
                    to: item.id,
                    intent: intent,
                    summary: dto.summary ?? "",
                    importance: dto.importance,
                    confidence: dto.confidence,
                    candidates: Self.candidates(from: dto),
                    expectedUpdatedAt: item.updatedAt
                )
            case "failed":
                await demoteToManual(item) // 명시적 분석 실패 — 즉시 강등.
            default:
                // ingested/analyzing: 아직 처리 중. deadline 초과면 give-up.
                if expired { await demoteToManual(item) }
            }
        }
    }

    /// 폴링 give-up deadline — 업로드 후 이 시간이 지나도 분석이 안 끝나면 강등한다.
    private static let analysisPollDeadline: TimeInterval = 90

    /// 분석 실패/지연 항목을 "분석 중"에서 빼 "헷갈려요"(의견 없음 → 직접 분류/다시 시도)로 강등한다.
    /// `confidence = 0` + 빈 candidates → `isUncertain` 이면서 `reviewOpinions` 가 비어,
    /// 홈 카드가 "모찌가 잘 모르겠어요" 분기로 렌더(직접 분류 + "다시 맡기기").
    private func demoteToManual(_ item: MochiItem) async {
        guard var current = try? await repository.find(id: item.id) else { return }
        // 세대 가드: 스냅샷 이후 (분석 도착·수동 분류·재시도로) 바뀐 항목은 강등하지 않는다.
        guard current.analysis == nil, current.updatedAt == item.updatedAt else { return }
        let fallbackIntent: Intent = current.source.url != nil ? .knowledge : .memo
        let summary = current.source.text
            ?? current.source.url?.absoluteString
            ?? "분석하지 못했어요"
        current.analysis = MochiItemAnalysis(
            summary: summary,
            intent: fallbackIntent,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .low,            // "중요해 보여요"(importance>=3)로 누출되지 않게 최저로.
            confidence: 0,
            modelVersion: MochiItemAnalysis.failedModelVersion,
            analyzedAt: Date(),
            candidates: []
        )
        current.lifecycleState = .active
        try? await repository.upsert(current)
    }

    /// metadata-only 분석 결과(primary + secondaryIntents + applicability)를 라벨 없는 후보 리스트로 재구성.
    private static func candidates(from dto: MochiItemDTO) -> [IntentCandidate] {
        guard let primary = dto.intent else { return [] }
        var result: [IntentCandidate] = [
            IntentCandidate(
                label: nil,
                intent: primary,
                applicability: dto.intentApplicability[primary.rawValue] ?? dto.confidence
            )
        ]
        for sec in dto.secondaryIntents {
            result.append(
                IntentCandidate(label: nil, intent: sec, applicability: dto.intentApplicability[sec.rawValue] ?? 0)
            )
        }
        return result
    }
}
