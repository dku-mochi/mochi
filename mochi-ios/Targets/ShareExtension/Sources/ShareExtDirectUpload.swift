import Foundation
import CoreDomain
import CorePersistence
import CoreNetworking
import CoreAuth

/// ShareExtension 의 "직접 전송 시도 → 실패 시 큐 폴백" 하이브리드.
///
/// 메인 앱이 부팅되기 전이라도 URL/텍스트/이미지 캡처를 즉시 서버에 올린다. 이미지 포함 캡처는
/// App Group 의 원본을 기존 앱 본체와 같은 JPEG upload variant 로 줄인 뒤 presign+PUT 한다.
///
/// 멱등키(`payload.id`)가 안전망 — ShareExt 가 올리고 메인 앱 drain 이 또 올려도 백엔드가 같은
/// 행을 반환(owner-scoped Idempotency-Key)하므로 이중 적재가 불가능하다. 따라서 큐 폴백이 안전.
enum ShareExtDirectUpload {
    /// 캡처를 서버에 **best-effort 선반영**한다 — 분석을 앱 부팅 전 조기 트리거.
    /// 성공/실패 무관하게 호출부는 큐를 항상 적재하므로(로컬·동기화·유실방지의 진실원천), 반환값은
    /// 향후 로깅용 신호일 뿐이다. 성공해도 멱등키(`payload.id`)가 drain·SyncWorker 재전송과 같은
    /// 행을 반환해 이중 적재가 없다.
    @discardableResult
    static func attempt(_ payload: InboundIngestPayload, queueFileURL: URL? = nil) async -> Bool {
        guard let baseURL = AppGroup.sharedAPIBaseURL // 앱이 공유한 baseURL (앱 미실행이면 nil → 큐만)
        else { return false }

        // Keychain access group 으로 access token read (만료 60s 전까지 유효). refresh 는 시도하지
        // 않는다 — 단명 프로세스 재진입 위험 회피. 만료/부재면 큐가 처리.
        let sessionStore = AuthSessionStore(store: KeychainTokenStore())
        guard let token = await sessionStore.accessTokenIfValid() else { return false }

        let client = OpenAPIMochiClient(baseURL: baseURL, tokenProvider: StaticTokenProvider(token: token))
        // ShareExt 는 OS 가 빠르게 종료시킬 수 있는 단명 프로세스라 짧은 timeout 으로 hang 을 막는다.
        // timeout/실패면 false → 호출부가 이미 써 둔 큐가 처리(유실 0).
        do {
            return try await withTimeout(seconds: timeoutSeconds(for: payload)) {
                let uploaded = try await uploadedImageRefs(payload.imageRefs, using: client)
                persistUploadedImageRefs(uploaded.imageRefs, for: payload, to: queueFileURL)
                let request = MochiItemIngestRequest(
                    channel: payload.channelGuess,
                    url: payload.url,
                    text: payload.text,
                    userMemo: payload.userMemo,
                    imageRefs: uploaded.dtos
                )
                _ = try await client.ingestMochiItem(request, idempotencyKey: payload.id.uuidString)
                return true
            }
        } catch {
            return false  // 401 / 네트워크 / timeout → 큐가 처리
        }
    }

    private static func timeoutSeconds(for payload: InboundIngestPayload) -> TimeInterval {
        payload.imageRefs.isEmpty ? 5 : 20
    }

    private struct UploadedImageRefs: Sendable {
        let imageRefs: [ImageRef]
        let dtos: [ImageRefDTO]
    }

    private static func uploadedImageRefs(
        _ imageRefs: [ImageRef],
        using client: any MochiAPIClient
    ) async throws -> UploadedImageRefs {
        var enrichedRefs: [ImageRef] = []
        var dtos: [ImageRefDTO] = []

        for imageRef in imageRefs {
            if let objectKey = imageRef.objectKey, !objectKey.isEmpty {
                enrichedRefs.append(imageRef)
                dtos.append(
                    ImageRefDTO(
                        objectKey: objectKey,
                        mimeType: imageRef.mimeType,
                        byteSize: imageRef.byteSize,
                        sha256: imageRef.sha256
                    )
                )
                continue
            }

            let originalData = try Data(
                contentsOf: AppGroup.containerURL.appendingPathComponent(imageRef.relativePath)
            )
            let uploadImage = try CaptureUploadImagePreprocessor.makeUploadVariant(from: originalData)
            let signed = try await client.presignCaptureUpload(
                sha256: uploadImage.sha256,
                mimeType: uploadImage.mimeType
            )
            try await client.putCaptureImage(
                uploadURL: signed.uploadURL,
                data: uploadImage.data,
                mimeType: uploadImage.mimeType
            )
            enrichedRefs.append(
                ImageRef(
                    id: imageRef.id,
                    relativePath: imageRef.relativePath,
                    mimeType: uploadImage.mimeType,
                    byteSize: uploadImage.byteSize,
                    sha256: uploadImage.sha256,
                    objectKey: signed.objectKey
                )
            )
            dtos.append(
                ImageRefDTO(
                    objectKey: signed.objectKey,
                    mimeType: uploadImage.mimeType,
                    byteSize: uploadImage.byteSize,
                    sha256: uploadImage.sha256
                )
            )
        }

        return UploadedImageRefs(imageRefs: enrichedRefs, dtos: dtos)
    }

    private static func persistUploadedImageRefs(
        _ imageRefs: [ImageRef],
        for payload: InboundIngestPayload,
        to queueFileURL: URL?
    ) {
        guard let queueFileURL, imageRefs != payload.imageRefs else { return }
        let enrichedPayload = InboundIngestPayload(
            id: payload.id,
            url: payload.url,
            text: payload.text,
            userMemo: payload.userMemo,
            channelGuess: payload.channelGuess,
            imageRefs: imageRefs
        )
        if let data = try? JSONEncoder().encode(enrichedPayload) {
            try? data.write(to: queueFileURL, options: [.atomic])
        }
    }

    /// 작업을 짧은 timeout 으로 감싼다 — 초과 시 작업을 취소하고 throw 한다.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

/// 고정 access token 을 주입하는 경량 ``AuthTokenProvider`` — ShareExt 직접 전송 전용.
/// refresh 회전은 하지 않는다(만료면 큐 폴백).
private struct StaticTokenProvider: AuthTokenProvider {
    let token: String
    func bearerToken() async -> String? { token }
}
