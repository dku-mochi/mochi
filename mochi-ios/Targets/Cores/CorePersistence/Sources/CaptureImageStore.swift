import Foundation
import CoreDomain

/// 캡처 이미지의 로컬-우선 / GCS-폴백 로더의 단일 정본.
///
/// 캡처 원본은 App Group `captures/<sha256>.<ext>` 에 content-addressed 로 저장되고, GCS 에도
/// `objectKey` 로 올라가 있다. 로컬 파일이 없으면(재설치·Realm 스키마 bump 와이프 후 pull 복원 등)
/// GCS 에서 받아 같은 경로에 캐시한다. presign+다운로드는 CoreNetworking 의존을 이 모듈에 들이지
/// 않도록 앱 부팅 시 1회 주입하는 `recoverer` 클로저에 캡슐화한다
/// (`AppGroup.setSharedAPIBaseURL` 과 같은 "부팅 시 전역 구성" 패턴).
///
/// 두 소비자: ① `MochiItemSyncWorker.pullRemote`(ImageRef 통째 복원) ② `LocalThumbnail`(렌더 시점 폴백).
public actor CaptureImageStore {
    public static let shared = CaptureImageStore()

    /// objectKey → 원본 바이트. 앱 부팅 시 1회 주입. 미구성(ShareExtension·테스트)이면 폴백은
    /// no-op(파일 없으면 nil 반환 → placeholder 유지) — fail-open.
    private var recoverer: (@Sendable (_ objectKey: String) async throws -> Data)?
    /// 같은 이미지(sha256)를 여러 셀이 동시에 요청할 때 presign 중복 호출을 합친다.
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {}

    public func configure(recoverer: @escaping @Sendable (_ objectKey: String) async throws -> Data) {
        self.recoverer = recoverer
    }

    /// `SyncWorker` 용 — `objectKey` 만 있고 로컬 파일이 없는 ref 를 GCS 에서 받아 `relativePath` 를
    /// 채운 ref 를 돌려준다. 실패하면 원본 ref(빈 relativePath) 그대로 — 렌더 시점 폴백이 나중에 메운다.
    public func ensureLocalRef(for ref: ImageRef) async -> ImageRef {
        guard let objectKey = ref.objectKey, !objectKey.isEmpty, ref.relativePath.isEmpty else {
            return ref
        }
        guard let path = await ensureLocalPath(
            sha256: ref.sha256, mimeType: ref.mimeType, objectKey: objectKey
        ) else { return ref }
        return ImageRef(
            id: ref.id,
            relativePath: path,
            mimeType: ref.mimeType,
            byteSize: ref.byteSize,
            sha256: ref.sha256,
            objectKey: ref.objectKey
        )
    }

    /// 렌더 폴백 용 — content-addressed 로컬 파일이 있으면 그 `relativePath`, 없으면 GCS 에서 받아
    /// 캐시 후 `relativePath`. objectKey 없음·recoverer 미구성·다운로드 실패 시 nil(placeholder 유지).
    public func ensureLocalPath(sha256: String, mimeType: String, objectKey: String?) async -> String? {
        let filename = "\(sha256).\(Self.imageExtension(for: mimeType))"
        let relativePath = "captures/\(filename)"
        let fileURL = AppGroup.capturedImagesDirectoryURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) { return relativePath }
        guard let recoverer, let objectKey, !objectKey.isEmpty else { return nil }
        // 같은 sha256 이 진행 중이면 그 Task 를 기다려 presign 중복 호출을 막는다(coalescing).
        if let existing = inFlight[sha256] { return await existing.value }
        let task = Task<String?, Never> {
            do {
                let data = try await recoverer(objectKey)
                try data.write(to: fileURL, options: .atomic)
                return relativePath
            } catch {
                return nil
            }
        }
        inFlight[sha256] = task
        let result = await task.value
        inFlight.removeValue(forKey: sha256)
        return result
    }

    private static func imageExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png":  return "png"
        case "image/jpeg": return "jpg"
        default:           return "bin"
        }
    }
}
