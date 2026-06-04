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

    /// Live Activity trigger — 스크린샷 ingest 시 `.analyzing` / `.ready` / `end` 호출.
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

            // 스크린샷(백탭) 입력은 분석 중 Live Activity 를 점유한다 (입력 UX 유지) — Lock Screen /
            // Dynamic Island 에 "분류 중" 표시. ingest 경로는 단일화됐다: 모든 채널이
            // presign→PUT→`ingestMochiItem`(with imageRefs). 백엔드가 `.ingested` 로 적재하고
            // worker 가 비동기 분석하므로 이 항목은 `pollAnalysisOnce` 대상이 된다.
            if mochiItem.source.channel == .screenshot,
               let imageRef = mochiItem.source.imageRefs.first {
                let caption = liveActivityCaption(
                    mochiItemID: mochiItem.id,
                    body: mochiItem.source.userMemo?.prefix(40).description ?? "스크린샷 분석 중"
                )
                await liveActivity.startAnalyzing(
                    mochiItemID: mochiItem.id,
                    caption: caption,
                    thumbnailRelativePath: imageRef.relativePath
                )
            }

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

    /// 분석 결과(intent instances / needsReview / reviewOptions / summary / importance)를 Realm 의
    /// ``MochiItem.analysis`` 에 반영하는 공통 writer. 폴링(`pollAnalysisOnce`)이 호출한다.
    ///
    /// 처리상태 `lifecycleState` 를 `.analyzed` 로 직접 박는다 (분석 완료 — iOS 폴링 컷오버).
    /// `repository.upsert` 는 처리상태 전이 검증 없이 그대로 쓴다. 버킷(분석중/헷갈려요/중요)은
    /// 처리상태가 아니라 analysis 의 instances/needsReview 에서 derive 한다.
    private func applyAnalysis(
        to mochiItemID: UUID,
        instances: [IntentInstance],
        needsReview: Bool,
        reviewOptions: [ReviewOption],
        summary: String,
        importance: Int,
        expectedUpdatedAt: Date? = nil
    ) async {
        guard var current = try? await repository.find(id: mochiItemID) else { return }
        // 세대 가드(폴링 경로): GET 을 await 하는 사이 수동 분류(setIntent)·재시도(requeue)가
        // 끼어들 수 있다. 스냅샷 이후 항목이 바뀌었으면 stale 결과로 덮지 않는다.
        if let expectedUpdatedAt, current.updatedAt != expectedUpdatedAt { return }
        current.analysis = MochiItemAnalysis(
            summary: summary,
            instances: instances,
            needsReview: needsReview,
            reviewOptions: reviewOptions,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: MochiItemAnalysis.Importance(rawValue: importance) ?? .medium,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date()
        )
        current.lifecycleState = .analyzed
        try? await repository.upsert(current)
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

            guard let dto = try? await apiClient.getMochiItem(id: serverID) else {
                // GET 실패(네트워크/404 등): deadline 초과면 give-up, 아니면 다음 tick 재시도.
                if expired { await demoteToManual(item) }
                continue
            }

            // 백엔드가 분석을 끝내면 처리상태가 `analyzed` 로 전이한다 (구 `active` — 빅뱅 개명).
            // ⚠️ 이 case 문자열이 백엔드 처리상태와 어긋나면 폴링이 영영 안 끝난다.
            switch dto.lifecycleKind {
            case "analyzed":
                let instances = Self.instances(from: dto)
                await applyAnalysis(
                    to: item.id,
                    instances: instances,
                    needsReview: dto.needsReview,
                    reviewOptions: Self.reviewOptions(from: dto),
                    summary: dto.summary ?? "",
                    importance: dto.importance,
                    expectedUpdatedAt: item.updatedAt
                )
                // 백탭(screenshot) 은 분석 완료 시 instance 와 함께 Live Activity 를 `.ready` 로 전환한다.
                // (foreground 한정 — background push 는 APNs 도입 후. instance 없으면 LA 종료.)
                if item.source.channel == .screenshot {
                    let liveCandidates = instances.map {
                        LiveActivityCandidate(
                            label: $0.displayLabel,
                            intent: $0.intentType.rawValue,
                            applicability: 1.0
                        )
                    }
                    if liveCandidates.isEmpty {
                        await liveActivity.endIfActive(mochiItemID: item.id, failed: false)
                    } else {
                        await liveActivity.transitionToReady(mochiItemID: item.id, candidates: liveCandidates)
                    }
                }
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
        // 백탭(screenshot) 강등 시 점유 중이던 Live Activity 를 실패로 종료.
        if item.source.channel == .screenshot {
            await liveActivity.endIfActive(mochiItemID: item.id, failed: true)
        }
    }

    /// 백엔드 분석 결과의 intent instance(typed payload·한국어 label 포함)를 도메인으로 재구성한다.
    /// 분석 전이면 빈 배열 — 홈 카드/Live Activity 가 instance 없음으로 렌더.
    private static func instances(from dto: MochiItemDTO) -> [IntentInstance] {
        dto.intentInstances.map { i in
            IntentInstance(
                intentType: i.intentType,
                payload: payload(from: i.payload),
                label: i.label,
                reasoning: i.reasoning,
                lifecycle: instanceLifecycle(from: i.lifecycleKind)
            )
        }
    }

    private static func reviewOptions(from dto: MochiItemDTO) -> [ReviewOption] {
        dto.reviewOptions.map { ReviewOption(intentType: $0.intentType, label: $0.label, reasoning: $0.reasoning) }
    }

    private static func payload(from dto: IntentPayloadDTO?) -> IntentPayload {
        guard let dto else { return IntentPayload() }
        return IntentPayload(
            title: dto.title, date: dto.date, time: dto.time, deadline: dto.deadline,
            person: dto.person, topic: dto.topic, url: dto.url, note: dto.note
        )
    }

    /// 응답 instance 의 의미상태 문자열을 도메인으로. 새로 적재된 instance 는 대개 `active`.
    /// 응답엔 archive reason 이 없어 archived 는 `userManual` 로 기본 매핑(새 적재엔 거의 없음).
    private static func instanceLifecycle(from raw: String) -> InstanceLifecycle {
        switch raw {
        case "decaying":        return .decaying
        case "reviewRequested": return .reviewRequested
        case "archived":        return .archived(reason: .userManual)
        default:                return .active
        }
    }
}
