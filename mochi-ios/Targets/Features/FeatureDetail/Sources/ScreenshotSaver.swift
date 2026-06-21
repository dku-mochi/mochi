import Foundation
import Photos
import UIKit
import CoreDomain
import CoreNetworking
import CorePersistence

/// 캡처 원본 이미지를 사진 앱에 저장한다 — 상세 ⋯ 메뉴의 "이미지 저장".
///
/// 저장은 **원본 풀해상도**다(상세 미리보기의 다운샘플 경로를 재사용하지 않는다). 소스 우선순위:
/// ① App Group 로컬 캐시(`captures/<sha256>`)가 있으면 그 파일 → ② 없으면 presign GCS 원본을
/// 받아 저장하고 다음 저장을 위해 로컬에도 멱등 캐시한다(MochiItemSyncWorker.ensureLocalImage 와 같은 규약).
///
/// 민감 캡처 게이트 없음(ungated) — 현재 `sensitivity_level` 미구현이라 판별 근거 자체가 없다.
/// 단, 사진 앱은 앱 경계 밖(라이브러리·iCloud) 반출 표면이라 privacy 필드 도입 시 게이트 대상이다
/// (docs/PRIVACY_SENSITIVE_CAPTURE.md §9, docs/TODO.md).
enum ScreenshotSaver {
    enum SaveError: LocalizedError {
        case noImage
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noImage:         return "저장할 이미지를 찾지 못했어요."
            case .permissionDenied: return "사진 접근 권한이 없어 저장하지 못했어요. 설정에서 허용해 주세요."
            }
        }
    }

    static func saveToPhotos(ref: ImageRef, apiClient: any MochiAPIClient) async throws {
        let data = try await imageData(ref: ref, apiClient: apiClient)
        try await addToLibrary(data)
    }

    private static func imageData(ref: ImageRef, apiClient: any MochiAPIClient) async throws -> Data {
        if !ref.displayRelativePath.isEmpty {
            let url = AppGroup.containerURL.appendingPathComponent(ref.displayRelativePath)
            if let data = try? Data(contentsOf: url) { return data }
        }
        guard let objectKey = ref.objectKey, !objectKey.isEmpty else { throw SaveError.noImage }
        let url = try await apiClient.presignCaptureDownload(objectKey: objectKey)
        let (data, response) = try await URLSession.shared.data(from: url)
        // 만료된 signed URL·403/404 는 XML 에러 본문을 200 아닌 status 로 준다 — 그걸 사진앱에
        // 저장하지 않도록 status·실제 디코드 가능 여부를 확인한다.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, UIImage(data: data) != nil else { throw SaveError.noImage }
        cacheLocally(data, ref: ref)
        return data
    }

    /// content-addressed 멱등 캐시 — 실패해도 저장 자체엔 영향 없으므로 best-effort.
    private static func cacheLocally(_ data: Data, ref: ImageRef) {
        let ext: String
        switch ref.mimeType {
        case "image/png":  ext = "png"
        case "image/jpeg": ext = "jpg"
        default:           ext = "bin"
        }
        let fileURL = AppGroup.capturedImagesDirectoryURL.appendingPathComponent("\(ref.sha256).\(ext)")
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func addToLibrary(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.permissionDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
