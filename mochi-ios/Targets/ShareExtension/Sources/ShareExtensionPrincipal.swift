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
            let host = UIHostingController(rootView: ShareEntryView(
                initialURL: extracted.url,
                initialText: extracted.text,
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                onSubmit: { [weak self] payload in self?.persist(payload) },
                onCancel: { [weak self] in self?.complete(success: false) }
            ))
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

    private func persist(_ payload: InboundIngestPayload) {
        Task.detached {
            let fileURL = AppGroup.inboundQueueURL.appendingPathComponent("\(payload.id.uuidString).json")
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: fileURL, options: [.atomic])
            }
            await MainActor.run { self.complete(success: true) }
        }
    }

    private func complete(success: Bool) {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - NSItemProvider 추출

    private struct ExtractedShareInput {
        var url: URL?
        var text: String?
        var imageRefs: [ImageRef]
        var channelGuess: IngestChannel
    }

    /// 단일 캡처 ID 는 추출 시점에 결정되어 (메인 앱 · 백엔드까지) 동일 ID 로 흐른다.
    /// 이 ID 는 ``InboundIngestPayload.id`` 로 들어가고, 그대로 멱등키 base가 된다.
    private static let payloadIDPrefix = "captures"

    private static let maxImageBytes = 20 * 1024 * 1024     // 단일 이미지 20MB 상한

    private static func extractInboundPayload(from context: NSExtensionContext?) async -> ExtractedShareInput {
        guard let context else { return ExtractedShareInput(url: nil, text: nil, imageRefs: [], channelGuess: .appShareSheet) }

        var url: URL?
        var text: String?
        var imageRefs: [ImageRef] = []

        for item in context.inputItems.compactMap({ $0 as? NSExtensionItem }) {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), url == nil {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) as? URL {
                        url = loaded
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), text == nil {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) as? String {
                        text = loaded
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let ref = await persistImage(from: provider) {
                        imageRefs.append(ref)
                    }
                }
            }
        }

        return ExtractedShareInput(
            url: url,
            text: text,
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
