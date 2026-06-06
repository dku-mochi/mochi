import UIKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import CoreDomain
import CorePersistence

/// 코드 기반 진입점 — `Info.plist` 의 `NSExtensionPrincipalClass` 가 이 클래스를 가리킨다.
/// 스토리보드 의존을 제거해 빌드 안정성·SwiftUI 사용 자유도를 확보한다.
@objc(ShareExtensionPrincipal)
public final class ShareExtensionPrincipal: UIViewController {

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        Task { @MainActor in
            let extracted = await Self.extractInboundPayload(from: extensionContext)
            let host = UIHostingController(rootView: contentView(for: extracted))
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            host.didMove(toParent: self)
        }
    }

    /// 백탭 단축어 진입(이미지 1장 단독, URL/text 없음) → 1-step UI ``BackTapShareView``,
    /// 외부 공유시트 진입(URL/text 또는 다중 이미지) → 기존 ``ShareEntryView``.
    @ViewBuilder
    private func contentView(for extracted: ExtractedShareInput) -> some View {
        if extracted.imageRefs.count == 1
            && extracted.url == nil
            && (extracted.text?.isEmpty ?? true) {
            BackTapShareView(
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                sourceApp: extracted.sourceApp,
                onSubmit: { [weak self] payload in self?.persist(payload, original: extracted.imageRefs) },
                onCancel: { [weak self] in self?.cancel(cleaning: extracted.imageRefs) }
            )
        } else {
            ShareEntryView(
                initialURL: extracted.url,
                initialText: extracted.text,
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                sourceApp: extracted.sourceApp,
                onSubmit: { [weak self] payload in self?.persist(payload, original: extracted.imageRefs) },
                onCancel: { [weak self] in self?.cancel(cleaning: extracted.imageRefs) }
            )
        }
    }

    /// 큐에 떨굴 때, 일반 메모 모드로 사용자가 제거한 이미지(원본엔 있었으나 payload 엔 빠진)의
    /// 고아 PNG 를 함께 청소한다 — `persistImage` 가 이미 디스크에 써 둔 상태라 안 지우면 누수.
    private func persist(_ payload: InboundIngestPayload, original: [ImageRef]) {
        let removed = original.filter { ref in
            !payload.imageRefs.contains { $0.relativePath == ref.relativePath }
        }
        Self.deleteImagePNGs(removed)
        Task { [weak self] in
            // 1) 큐 적재가 **항상 진실원천** — 로컬 Realm ingest·동기화·유실 방지(다음 active tick 의
            //    drain → upsert → SyncWorker 업로드). 직접전송보다 먼저 써 유실을 0으로 만든다.
            let fileURL = AppGroup.inboundQueueURL.appendingPathComponent("\(payload.id.uuidString).json")
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: fileURL, options: [.atomic])
            }
            // 2) best-effort 선반영 — 서버 분석을 앱 부팅 전 조기 트리거(짧은 timeout).
            //    성공해도 큐는 그대로 — 멱등키(payload.id)가 drain·SyncWorker 재전송과 같은 행을
            //    반환해 이중 적재가 없다. 이미지 업로드 성공 시 큐 JSON 도 objectKey 로 보강한다.
            //    completeRequest 전에 시도해 extension 이 살아있는 동안 끝낸다.
            await ShareExtDirectUpload.attempt(payload, queueFileURL: fileURL)
            self?.complete(success: true)
        }
    }

    /// 취소(시트 dismiss) 경로 — `persistImage` 가 써 둔 PNG 를 모두 청소한 뒤 닫는다.
    /// (이전엔 청소 없이 닫아 capturedImages/ 에 고아 PNG 가 누수됐다.)
    private func cancel(cleaning refs: [ImageRef]) {
        Self.deleteImagePNGs(refs)
        complete(success: false)
    }

    private func complete(success: Bool) {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func deleteImagePNGs(_ refs: [ImageRef]) {
        for ref in refs {
            let url = AppGroup.containerURL.appendingPathComponent(ref.relativePath)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - NSItemProvider 추출

    private struct ExtractedShareInput {
        var url: URL?
        var text: String?
        /// 단축어가 sentinel 로 보낸 출처앱(자동신호). `text`/`user_memo` 와 분리해 흐른다.
        var sourceApp: String?
        var imageRefs: [ImageRef]
        var channelGuess: IngestChannel
    }

    /// 단일 캡처 ID 는 추출 시점에 결정되어 (메인 앱 · 백엔드까지) 동일 ID 로 흐른다.
    /// 이 ID 는 ``InboundIngestPayload.id`` 로 들어가고, 그대로 멱등키 base가 된다.
    private static let payloadIDPrefix = "captures"

    private static let maxImageBytes = 20 * 1024 * 1024     // 단일 이미지 20MB 상한

    private static func extractInboundPayload(from context: NSExtensionContext?) async -> ExtractedShareInput {
        guard let context else { return ExtractedShareInput(url: nil, text: nil, sourceApp: nil, imageRefs: [], channelGuess: .appShareSheet) }

        var url: URL?
        var text: String?
        var sourceApp: String?
        var imageRefs: [ImageRef] = []

        for item in context.inputItems.compactMap({ $0 as? NSExtensionItem }) {
            for provider in item.attachments ?? [] {
                // **이미지를 url 보다 먼저 평가** — 단축어에서 보낸 image attachment 는 file:// URL
                // 형태로도 전달되어 `UTType.url.identifier` (public.url) 에 conform 한다.
                // url 분기를 먼저 잡으면 이미지가 url 로 오인되어 백탭 진입 감지 (이미지 1장 + URL 없음)
                // 가 fail 하고 `ShareEntryView` fallback 으로 떠오른다.
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let ref = await persistImage(from: provider) {
                        imageRefs.append(ref)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), url == nil {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) as? URL {
                        url = loaded
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) as? String {
                        // sentinel(자동신호)과 일반 텍스트를 각자 첫 값만 받아 **각 채널로 분리** 흡수한다.
                        // sentinel 은 메타라 text 콘텐츠로 합치지 않아 previewCard 에 raw JSON 이 노출되지 않는다.
                        if let ctx = CaptureContextSentinel.decode(loaded) {
                            if sourceApp == nil { sourceApp = ctx.sourceApp }
                        } else if text == nil {
                            text = loaded
                        }
                    }
                }
            }
        }

        return ExtractedShareInput(
            url: url,
            text: text,
            sourceApp: sourceApp,
            imageRefs: imageRefs,
            channelGuess: Self.guessChannel(from: url, hasImage: !imageRefs.isEmpty)
        )
    }

    private static func persistImage(from provider: NSItemProvider) async -> ImageRef? {
        guard let imageURL = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) as? URL,
              let data = try? Data(contentsOf: imageURL),
              data.count <= maxImageBytes else { return nil }
        let mimeType = UTType(filenameExtension: imageURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let filename = "\(UUID().uuidString).\(imageURL.pathExtension.isEmpty ? "img" : imageURL.pathExtension)"
        let relativePath = "\(payloadIDPrefix)/\(filename)"
        let destination = AppGroup.capturedImagesDirectoryURL.appendingPathComponent(filename)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImageRef(
            relativePath: relativePath,
            mimeType: mimeType,
            byteSize: data.count,
            sha256: digest,
            objectKey: nil
        )
    }

    private static func guessChannel(from url: URL?, hasImage: Bool) -> IngestChannel {
        if hasImage && url == nil { return .screenshot }
        guard let host = url?.host?.lowercased() else { return .appShareSheet }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("kakao") { return .kakaoTalk }
        if host.contains("apple.com") || host.contains("safari") { return .safari }
        return .appShareSheet
    }
}
