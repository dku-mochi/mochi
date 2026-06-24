import Foundation
import os
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
    /// 실패 사유 진단용 — Console.app 에서 `app.mochi.ShareExtension` subsystem 으로 필터.
    /// 토큰 값은 어떤 분기에서도 절대 로그하지 않는다.
    private static let logger = Logger(subsystem: "app.mochi.ShareExtension", category: "direct-upload")

    /// 캡처를 서버에 **best-effort 선반영**한다 — 분석을 앱 부팅 전 조기 트리거.
    /// 성공/실패 무관하게 호출부는 큐를 항상 적재하므로(로컬·동기화·유실방지의 진실원천), 반환값은
    /// 향후 로깅용 신호일 뿐이다. 성공해도 멱등키(`payload.id`)가 drain·SyncWorker 재전송과 같은
    /// 행을 반환해 이중 적재가 없다.
    @discardableResult
    static func attempt(_ payload: InboundIngestPayload, queueFileURL: URL? = nil) async -> Bool {
        guard let baseURL = AppGroup.sharedAPIBaseURL // 앱이 공유한 baseURL (앱 미실행이면 nil → 큐만)
        else {
            logger.notice("skip: base-url-nil (메인 앱 미실행) → 큐 폴백")
            return false
        }

        guard let resolved = await resolveToken() else {
            logger.notice("skip: no-token (capture token 부재 + access token 만료/부재) → 큐 폴백")
            return false
        }
        logger.notice("start: token-source=\(resolved.source, privacy: .public) images=\(payload.imageRefs.count)")

        let client = OpenAPIMochiClient(
            baseURL: baseURL,
            tokenProvider: StaticTokenProvider(token: resolved.token)
        )
        // ShareExt 는 OS 가 빠르게 종료시킬 수 있는 단명 프로세스라 짧은 timeout 으로 hang 을 막는다.
        // timeout/실패면 false → 호출부가 이미 써 둔 큐가 처리(유실 0).
        do {
            let ok = try await withTimeout(seconds: timeoutSeconds(for: payload)) {
                let uploaded = try await uploadedImageRefs(
                    payload.imageRefs,
                    policy: payload.privacy?.policy ?? .originalUpload,
                    using: client
                )
                persistUploadedImageRefs(uploaded.imageRefs, for: payload, to: queueFileURL)
                let request = MochiItemIngestRequest(
                    channel: payload.channelGuess,
                    url: payload.url,
                    text: payload.text,
                    userMemo: payload.userMemo,
                    imageRefs: uploaded.dtos,
                    analysisOcrText: EphemeralOCRGate.textForUpload(
                        privacy: payload.privacy,
                        ocrText: payload.analysisOcrText
                    )
                )
                _ = try await client.ingestMochiItem(request, idempotencyKey: payload.id.uuidString)
                return true
            }
            logger.notice("success: token-source=\(resolved.source, privacy: .public)")
            return ok
        } catch is CancellationError {
            logger.notice("fail: timeout(\(timeoutSeconds(for: payload), format: .fixed(precision: 0))s) → 큐 폴백")
            return false
        } catch {
            // 에러 설명에 토큰이 섞일 일은 없다 (URLError/APIErrorEnvelope 계열).
            logger.notice("fail: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error)) → 큐 폴백")
            return false
        }
    }

    /// 인증 토큰 선택 — ① capture token(장수명, sliding) ② access token(만료 60s 여유) ③ 없음.
    ///
    /// capture token 은 **세션 사용자와 ``CaptureTokenRecord/userID`` 가 일치할 때만** 쓴다 —
    /// 메인 앱이 재발급에 실패한 채 계정이 바뀌었으면 이전 계정 명의로 업로드되는
    /// cross-account 오염이 생기므로, 사용 지점에서도 불변식을 강제한다 (codex review P1).
    /// 로컬 ``CaptureTokenRecord/expiresAt`` 으로는 **게이트하지 않는다** — 서버가 사용 시
    /// 연장하는 sliding 이라 로컬 값은 최소 보장일 뿐이고(ShareExt 자신의 캡처도 연장을
    /// 일으킨다), 만료 판단의 정본은 서버다. 서버가 거부(401)하면 큐가 처리한다.
    /// refresh 는 어느 쪽도 시도하지 않는다 — 단명 프로세스의 회전 토큰 유실 위험 회피.
    private static func resolveToken() async -> (token: String, source: String)? {
        let sessionStore = AuthSessionStore(store: KeychainTokenStore())
        let session = await sessionStore.current()
        if let record = try? KeychainCaptureTokenStore().load(),
           let session, record.userID == session.user.id {
            return (record.token, "capture")
        }
        if let access = await sessionStore.accessTokenIfValid() {
            return (access, "access")
        }
        return nil
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
        policy: PrivacyPolicy,
        using client: any MochiAPIClient
    ) async throws -> UploadedImageRefs {
        // 기기에만 저장 — 서버에 이미지를 전송하지 않는다(텍스트/메타는 그대로 ingest).
        if policy == .localOnly {
            return UploadedImageRefs(imageRefs: imageRefs, dtos: [])
        }
        var enrichedRefs: [ImageRef] = []
        var dtos: [ImageRefDTO] = []

        for imageRef in imageRefs {
            if let objectKey = imageRef.objectKey, !objectKey.isEmpty {
                // objectKey 는 정책 적용 후 생성된다(블러 정책이면 블러본 key). 방어: blurredUpload 인데
                // 블러본이 없으면 이 objectKey 는 원본일 수 있어 재사용하지 않는다(원본 유출 방지, codex P1).
                if policy == .blurredUpload, imageRef.redactedRelativePath == nil {
                    enrichedRefs.append(imageRef)
                    continue
                }
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

            // 블러 정책이면 블러본을, 아니면 원본을 올린다. 블러본이 없으면 원본 유출을 막기 위해 스킵.
            let sourcePath: String
            switch policy {
            case .localOnly:
                enrichedRefs.append(imageRef)
                continue
            case .blurredUpload:
                guard let redacted = imageRef.redactedRelativePath else {
                    enrichedRefs.append(imageRef)
                    continue
                }
                sourcePath = redacted
            case .originalUpload:
                sourcePath = imageRef.relativePath
            }

            let originalData = try Data(
                contentsOf: AppGroup.containerURL.appendingPathComponent(sourcePath)
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
                    objectKey: signed.objectKey,
                    // 블러본 로컬 경로를 보존한다 — 빠뜨리면 이 enriched ref 가 큐를 덮어써(`persistUploadedImageRefs`)
                    // 메인 앱 Realm 의 `redactedRelativePath` 가 nil 이 되고, `displayRelativePath` 가 원본을 가리켜
                    // 저장된 캡처가 메인 앱에서 가려지지 않은 채 보인다.
                    redactedRelativePath: imageRef.redactedRelativePath
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
            imageRefs: imageRefs,
            privacy: payload.privacy,
            analysisOcrText: payload.analysisOcrText
        )
        if let data = try? JSONEncoder().encode(enrichedPayload) {
            try? data.write(to: queueFileURL, options: [.atomic])
        }
    }

    /// 작업을 짧은 timeout 으로 감싼다 — 초과 시 작업을 취소하고 throw 한다.
    /// (URLSession 등 **cancellation 협조** 작업 전용 — 콜백 API[NSItemProvider]엔 무효라
    /// `ShareExtensionPrincipal` 은 once-gate continuation 방식을 따로 쓴다.)
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
