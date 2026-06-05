import Foundation
import CoreDomain
import CoreNetworking
import CoreAgentClient
import Dependencies

/// 로컬에 ingest 된 mochiItem 를 백엔드 `/api/v1/mochi_items` 에 업로드하는 워커.
///
/// **동작:**
/// 1. ``AuthTokenProvider.bearerToken()`` 이 nil 이면 즉시 종료 (미인증 사용자가 백탭 snippet 으로
///    Realm `.pendingUpload` 만 박아둔 상태일 수 있음 — 무인증 ingest 는 401 받고 `.syncFailed` 로
///    영구 strand 됨). 로그인 후 다음 active tick 에 다시 시도된다.
/// 2. ``MochiItemRepository.listRecent`` 에서 `syncState == .pendingUpload` 인 항목을 가져옴
/// 3. 모든 채널을 presign→GCS PUT→`POST /mochi_items` 단일 경로로 ingest (스크린샷은 Live Activity 점유)
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
    /// 진행 중 SSE 구독 — serverID 별 1건. 중복 구독 방지 + background 진입 시 일괄 취소.
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    /// Live Activity trigger — 전 채널 ingest 시 `.analyzing` / push 토큰 등록 / `.ready` / `end` 호출.
    /// DI 미주입 시 `NotConfiguredLiveActivityCoordinator` 가 no-op.
    @Dependency(\.liveActivityCoordinator) private var liveActivity

    /// SSE 라이브 스트림 — foreground in-flight 항목의 분석 완료를 3초 폴링보다 빨리 받는다(폴링은 fallback).
    /// DI 미주입 시 `NotConfiguredAgentStreamClient` 가 즉시 throw → 폴링이 단독으로 메운다.
    @Dependency(\.agentStreamClient) private var agentStream

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

            // 전 채널 입력이 분석 중 Live Activity 를 점유한다 — Lock Screen / Dynamic Island 에 "분석 중"
            // 표시. 썸네일은 스크린샷만 존재(그 외 nil → placeholder). ingest 경로는 단일화됐다: 모든
            // 채널이 presign→PUT→`ingestMochiItem`. 백엔드가 `.ingested` 로 적재하고 worker 가 비동기
            // 분석하므로 이 항목은 SSE 구독 + `pollAnalysisOnce`(fallback) 대상이 된다.
            let caption = mochiItem.source.userMemo?.prefix(40).description ?? "분석 중"
            await liveActivity.startAnalyzing(
                mochiItemID: mochiItem.id,
                caption: caption,
                thumbnailRelativePath: mochiItem.source.imageRefs.first?.relativePath
            )

            let imageRefs = try await uploadedImageRefDTOs(for: mochiItem)
            let request = MochiItemIngestRequest(
                channel: mochiItem.source.channel,
                url: mochiItem.source.url,
                text: mochiItem.source.text,
                userMemo: mochiItem.source.userMemo,
                imageRefs: imageRefs
            )
            let dto = try await apiClient.ingestMochiItem(request, idempotencyKey: mochiItem.id.uuidString)
            try await repository.updateSync(
                mochiItemID: mochiItem.id,
                to: .uploaded(serverID: dto.id, at: Date())
            )
            // serverID 확정 → LA push 토큰(로컬 관찰)을 server PK 로 등록(백엔드 background LA 갱신용).
            await liveActivity.registerPushToken(mochiItemID: mochiItem.id, serverID: dto.id)
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

    private func uploadedImageRefDTOs(for mochiItem: MochiItem) async throws -> [ImageRefDTO] {
        var refs: [ImageRefDTO] = []
        for imageRef in mochiItem.source.imageRefs {
            let uploaded = try await ensureUploadedImageRef(mochiItemID: mochiItem.id, imageRef: imageRef)
            refs.append(
                ImageRefDTO(
                    objectKey: uploaded.objectKey,
                    mimeType: uploaded.mimeType,
                    byteSize: uploaded.byteSize,
                    sha256: uploaded.sha256
                )
            )
        }
        return refs
    }

    private func ensureUploadedImageRef(mochiItemID: UUID, imageRef: ImageRef) async throws -> ImageRefDTO {
        if let objectKey = imageRef.objectKey, !objectKey.isEmpty {
            return ImageRefDTO(
                objectKey: objectKey,
                mimeType: imageRef.mimeType,
                byteSize: imageRef.byteSize,
                sha256: imageRef.sha256
            )
        }
        let originalData = try readImageBytes(imageRef.relativePath)
        let uploadImage = try CaptureUploadImagePreprocessor.makeUploadVariant(from: originalData)
        let signed = try await apiClient.presignCaptureUpload(
            sha256: uploadImage.sha256,
            mimeType: uploadImage.mimeType
        )
        try await apiClient.putCaptureImage(
            uploadURL: signed.uploadURL,
            data: uploadImage.data,
            mimeType: uploadImage.mimeType
        )
        try await repository.updateImageUploadMetadata(
            mochiItemID: mochiItemID,
            imageRefID: imageRef.id,
            mimeType: uploadImage.mimeType,
            byteSize: uploadImage.byteSize,
            sha256: uploadImage.sha256,
            objectKey: signed.objectKey
        )
        return ImageRefDTO(
            objectKey: signed.objectKey,
            mimeType: uploadImage.mimeType,
            byteSize: uploadImage.byteSize,
            sha256: uploadImage.sha256
        )
    }

    /// `relativePath` 는 `RealmImageRef.relativePath` (예: `captures/<filename>`). App Group container
    /// 기준으로 절대 경로 조립 후 bytes 를 읽는다.
    private func readImageBytes(_ relativePath: String) throws -> Data {
        let url = AppGroup.containerURL.appendingPathComponent(relativePath)
        return try Data(contentsOf: url)
    }

    /// 분석 결과를 Realm 의 ``MochiItem.analysis`` 에 반영하는 공통 writer (폴링·SSE 공용).
    ///
    /// 처리상태 `lifecycleState` 를 `.analyzed` 로 직접 박는다 (분석 완료 — iOS 컷오버).
    /// `repository.upsert` 는 처리상태 전이 검증 없이 그대로 쓴다. 버킷(분석중/헷갈려요/중요)은
    /// 처리상태가 아니라 analysis 의 instances/needsReview 에서 derive 한다.
    ///
    /// **중복 적용 차단(apply-once)**: SSE 와 폴링이 거의 동시에 같은 `analysis == nil` 스냅샷을 잡아
    /// 둘 다 도달할 수 있다. `upsert` 는 `updatedAt` 을 bump 하지 않아(RealmMochiItemMapper) 세대
    /// 가드만으론 못 막으므로, 이미 분석이 붙었으면(`analysis != nil`) 두 번째 적용을 건너뛴다.
    /// 추가로 세대 가드: GET/스트림을 await 하는 사이 수동 분류(setIntent)·재시도가 끼어들어 스냅샷
    /// 이후 항목이 바뀌었으면 stale 결과로 덮지 않는다. 적용 여부를 반환 — 호출부가 LA 갱신 분기에 쓴다.
    @discardableResult
    private func applyAnalysis(
        to mochiItemID: UUID,
        analysis: MochiItemAnalysis,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        guard var current = try? await repository.find(id: mochiItemID) else { return false }
        guard current.analysis == nil else { return false }  // 이미 적용됨(SSE/폴링 경합) — 한 번만.
        if let expectedUpdatedAt, current.updatedAt != expectedUpdatedAt { return false }
        current.analysis = analysis
        current.lifecycleState = .analyzed
        try? await repository.upsert(current)
        return true
    }

    /// 분석 적용 + Live Activity `.ready` 전환(전 채널). 적용이 세대 가드로 막히면 LA 도 건너뛴다.
    /// 후보는 `reviewOptions`(헷갈려요 후보)에서 — needsReview=false 면 빈 후보 + summary 로 확정 표시.
    private func applyAnalysisAndUpdateLA(
        localID: UUID,
        analysis: MochiItemAnalysis,
        expectedUpdatedAt: Date?
    ) async {
        let applied = await applyAnalysis(to: localID, analysis: analysis, expectedUpdatedAt: expectedUpdatedAt)
        guard applied else { return }
        let candidates = analysis.reviewOptions.map {
            LiveActivityCandidate(
                intentType: $0.intentType.rawValue,
                label: $0.displayLabel,
                reasoning: $0.reasoning ?? ""
            )
        }
        await liveActivity.transitionToReady(
            mochiItemID: localID,
            needsReview: analysis.needsReview,
            summary: analysis.summary,
            candidates: candidates
        )
    }

    /// in-flight(uploaded + analysis==nil) 항목의 SSE 스트림을 보장(중복 구독은 무시).
    /// `final`(GET 재조회 결과)→분석 적용+LA. node/partial 은 진행표시용이라 worker 는 무시.
    ///
    /// **`failed` 는 강등하지 않는다**: 백엔드는 genuine 실패뿐 아니라 SSE deadline(분석은 계속 중)도
    /// `failed`로 흘린다. 둘을 구분 못 하므로, 강등 판단은 deadline·lifecycleKind 를 보는 폴링에 맡긴다.
    /// SSE 와 폴링은 생명주기가 같아(둘 다 foreground, background 진입 시 함께 취소) 폴링이 항상 메운다.
    private func ensureStream(for item: MochiItem, serverID: UUID) {
        guard streamTasks[serverID] == nil else { return }
        streamTasks[serverID] = Task { [weak self, agentStream] in
            do {
                for try await event in agentStream.stream(mochiItemID: serverID) {
                    if case let .finalAnalysis(analysis) = event {
                        await self?.applyAnalysisAndUpdateLA(
                            localID: item.id, analysis: analysis, expectedUpdatedAt: item.updatedAt
                        )
                    }
                    // node/tool/partial/failed — 폴링 fallback 이 진행·강등을 맡는다.
                }
            } catch {
                // SSE 실패/끊김 — 폴링 fallback 이 메운다.
            }
            await self?.clearStream(serverID)
        }
    }

    private func clearStream(_ serverID: UUID) {
        streamTasks[serverID] = nil
    }

    // MARK: - 분석 폴링 (foreground 한정) — 백탭·metadata-only 공통

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
        // background 진입 시 SSE 소켓은 어차피 suspend 된다 — 명시적으로 취소해 dangling task 제거.
        // (background 분석 완료는 APNs 가 인계, 복귀 시 reconcile 이 메운다.)
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
    }

    /// 업로드됐으나(syncState == .uploaded) 아직 분석이 안 붙은(analysis == nil) 항목을
    /// `GET /mochi_items/{id}` 로 재조회해, 백엔드 worker 분석이 끝났으면(처리상태 analyzed) 결과를 반영한다.
    /// 백탭 스크린샷도 동기 분류를 제거해 analysis == nil 로 적재되므로 이 폴링 대상에 포함된다 —
    /// 분석 완료 시 결과 반영 + Live Activity `.ready` 전환을 함께 수행한다.
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
            // SSE 구독 보장 — foreground 즉시 반영(폴링은 fallback). 중복 구독은 무시.
            ensureStream(for: item, serverID: serverID)

            guard let dto = try? await apiClient.getMochiItem(id: serverID) else {
                // GET 실패(네트워크/404 등): deadline 초과면 give-up, 아니면 다음 tick 재시도.
                if expired { await demoteToManual(item) }
                continue
            }

            // 백엔드가 분석을 끝내면 처리상태가 `analyzed` 로 전이한다 (구 `active` — 빅뱅 개명).
            // ⚠️ 이 case 문자열이 백엔드 처리상태와 어긋나면 폴링이 영영 안 끝난다.
            switch dto.lifecycleKind {
            case "analyzed":
                // 전 채널 분석 완료 — 분석 적용 + Live Activity `.ready` 전환(공통 헬퍼).
                await applyAnalysisAndUpdateLA(
                    localID: item.id,
                    analysis: dto.toMochiItemAnalysis(),
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
    /// `needsReview = true` + 빈 reviewOptions + `failedModelVersion` 마커 → 홈 카드가
    /// "모찌가 잘 모르겠어요" 분기로 렌더(직접 분류 + "다시 맡기기").
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
            instances: [IntentInstance(intentType: fallbackIntent)],
            needsReview: true,
            reviewOptions: [],
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .low,            // "중요해 보여요"(importance>=3)로 누출되지 않게 최저로.
            modelVersion: MochiItemAnalysis.failedModelVersion,
            analyzedAt: Date()
        )
        current.lifecycleState = .analyzed
        try? await repository.upsert(current)
        // 강등 시 점유 중이던 Live Activity 를 실패로 종료(전 채널).
        await liveActivity.endIfActive(mochiItemID: item.id, failed: true)
    }
}
