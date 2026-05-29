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

    /// 백탭 multipart ingest 응답으로 받은 분류 결과 (intent / summary / importance / confidence) 를
    /// Realm 의 ``MochiItem.analysis`` 에 반영한다. Inbox / 홈 UI 가 `analysis?.summary` 가 nil 이면
    /// "(분석 대기 중)" 으로 표시하기 때문 — 백엔드는 이미 분류를 끝낸 상태이므로 그 결과를 즉시 노출.
    ///
    /// `lifecycleState` 도 `.active` 로 직접 박는다. `repository.upsert` 는 `LifecyclePolicy.validate`
    /// 를 거치지 않아 `.ingested → .active` 직접 전이가 가능 (백엔드의 즉시 분류 결과를 반영하는
    /// 의식적 우회 — `LifecyclePolicy` 의 `.analyzing` 중간 상태는 백엔드 응답이 도착하지 않은
    /// 시점을 표현하기 위한 것이라 본 흐름엔 무관).
    private func applyClassification(
        to mochiItemID: UUID,
        response: BackTapMochiItemResponseDTO
    ) async {
        guard var current = try? await repository.find(id: mochiItemID) else { return }
        let dto = response.item
        guard let intent = dto.intent else { return }

        // 백엔드 응답의 summary 가 비어 있으면 첫 후보 라벨 ("구매 고민" 등) 을 fallback.
        // InboxView / 홈이 보여줄 첫 번째 사용자-facing 텍스트.
        let summary: String = {
            if let s = dto.summary, !s.isEmpty { return s }
            return response.candidates.first?.label ?? ""
        }()

        current.analysis = MochiItemAnalysis(
            summary: summary,
            intent: intent,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: MochiItemAnalysis.Importance(rawValue: dto.importance) ?? .medium,
            confidence: dto.confidence,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date()
        )
        current.lifecycleState = .active
        try? await repository.upsert(current)
    }
}
