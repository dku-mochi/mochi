import Foundation
import CoreDomain
import CoreNetworking

/// 로컬에 ingest 된 capture 를 백엔드 `/api/v1/captures` 에 업로드하는 워커.
///
/// **동작:**
/// 1. ``AuthTokenProvider.bearerToken()`` 이 nil 이면 즉시 종료 (미인증 사용자가 백탭 snippet 으로
///    Realm `.pendingUpload` 만 박아둔 상태일 수 있음 — 무인증 ingest 는 401 받고 `.syncFailed` 로
///    영구 strand 됨). 로그인 후 다음 active tick 에 다시 시도된다.
/// 2. ``CaptureRepository.listRecent`` 에서 `syncState == .pendingUpload` 인 캡처를 가져옴
/// 3. 각 캡처에 대해 ``MochiAPIClient.ingestCapture`` 호출
/// 4. 성공 시 `syncState=.uploaded(serverID, at)` 로 업데이트
/// 5. 실패 시 transient 면 backoff, 영구 실패면 `syncFailed(reason, retryAfter)` 로 업데이트
///
/// 멱등키는 `Capture.id.uuidString` 자체를 사용한다 — 같은 캡처를 두 번 올려도 백엔드가 같은 행을 반환.
public actor CaptureSyncWorker {
    private let repository: any CaptureRepository
    private let apiClient: any MochiAPIClient
    private let tokenProvider: any AuthTokenProvider
    private var isRunning = false

    public init(
        repository: any CaptureRepository,
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

        let pending: [Capture]
        do {
            pending = try await repository.listRecent(limit: 200).filter { $0.syncState == .pendingUpload }
        } catch {
            return
        }

        for capture in pending {
            await uploadOne(capture)
        }
    }

    private func uploadOne(_ capture: Capture) async {
        let request = CaptureIngestRequest(
            channel: capture.source.channel,
            url: capture.source.url,
            text: capture.source.text,
            userMemo: capture.source.userMemo,
            imageRefs: capture.source.imageRefs.map { ImageRefDTO(
                objectKey: $0.objectKey,
                mimeType: $0.mimeType,
                byteSize: $0.byteSize,
                sha256: $0.sha256
            ) }
        )
        do {
            try? await repository.updateSync(captureID: capture.id, to: .uploading)
            let dto = try await apiClient.ingestCapture(request, idempotencyKey: capture.id.uuidString)
            try await repository.updateSync(
                captureID: capture.id,
                to: .uploaded(serverID: dto.id, at: Date())
            )
        } catch let envelope as APIErrorEnvelope {
            try? await repository.updateSync(
                captureID: capture.id,
                to: .syncFailed(reason: "[\(envelope.code)] \(envelope.message)", retryAfter: nil)
            )
        } catch {
            try? await repository.updateSync(
                captureID: capture.id,
                to: .syncFailed(reason: String(describing: error), retryAfter: nil)
            )
        }
    }
}
