import UIKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import os
import CoreDomain
import CorePersistence

/// 코드 기반 진입점 — `Info.plist` 의 `NSExtensionPrincipalClass` 가 이 클래스를 가리킨다.
/// 스토리보드 의존을 제거해 빌드 안정성·SwiftUI 사용 자유도를 확보한다.
@objc(ShareExtensionPrincipal)
public final class ShareExtensionPrincipal: UIViewController {
    private static let logger = Logger(subsystem: "app.mochi.ShareExtension", category: "lifecycle")

    /// `completeRequest` 멱등 가드 — 정상 종료(저장/취소)와 끌어내림 안전망의 이중호출을 막는다.
    private var didComplete = false
    /// 끌어내림으로 닫혔을 때 청소할 고아 PNG 후보 — 추출 직후 채워진다.
    private var capturedRefs: [ImageRef] = []
    /// 저장 진행 중 표식 — 끌어내림 안전망이 큐에 적재된 이미지를 잘못 청소하지 않게 한다.
    private var isPersisting = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        Self.logger.notice("ShareExtension viewDidLoad")
        Self.logInputProviders(extensionContext)
        view.backgroundColor = .systemBackground

        Task { @MainActor in
            // 온보딩 백탭 검증 모드: 백탭이 ShareExtension 까지 도달했음을 기록하고, 진짜 저장 없이
            // "작동해요" 만 보여준 뒤 닫는다 (검증용 스크린샷이 쓰레기로 남지 않게). 백탭의 실제
            // 진입점은 snippet(CaptureScreenshotIntent)이 아니라 이 ShareExtension 이다.
            // **추출 이전에** 분기한다 — 검증 모드는 payload 가 필요 없고, 추출 단계 hang 에 검증 UI 가
            // 막혀선 안 되며, 불필요한 PNG persist(→고아 청소)도 피한다.
            if AppGroup.isBackTapVerificationActive {
                AppGroup.markBackTapVerificationHit()
                // **먹통 수정 (탭 종료)**: 자동(타이머) `completeRequest` 는 ShareExtension scene 을
                // teardown 못 시켜 카드 fade 후에도 익스텐션 윈도우가 살아남아 홈제스처까지 막고
                // 잠금/해제 전엔 안 꺼졌다. 정상 캡처(`BackTapShareView`)는 사용자 탭으로
                // `completeRequest` 를 부른다 — 검증만 타이머라 생긴 차이. 그래서 검증도 캡처와
                // 똑같이 "완료" 탭(onDone→complete)으로 종료한다.
                embed(UIHostingController(rootView: BackTapVerifyShareView(
                    onDone: { [weak self] in self?.complete(success: false) }
                )))
                // capture 경로처럼 입력 item provider 도 로드해 소비한다(미소비 provider 가
                // teardown 을 막을 가능성 차단). persist 는 안 해 고아 PNG 0.
                let context = extensionContext
                Task { @MainActor in await Self.drainInputProviders(context) }
                return
            }

            let extracted = await Self.extractInboundPayload(from: extensionContext)
            capturedRefs = extracted.imageRefs
            embed(UIHostingController(rootView: contentView(for: extracted)))
        }
    }

    /// **먹통 수정 (끌어내림 종료)**: 사용자가 시트를 손으로 끌어내려 닫으면 저장/취소 콜백을 거치지
    /// 않아 ``complete`` 가 호출되지 않는다 → 호출자(단축어)가 익스텐션 종료를 무한 대기한다.
    /// 마지막 안전망으로 여기서 `completeRequest` 를 보장한다. 저장 중이 아니면(미저장 닫힘) 디스크에
    /// 써 둔 고아 PNG 도 함께 청소한다. 정상 종료는 ``complete`` 의 멱등 가드로 이중호출되지 않는다.
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didComplete else { return }
        Self.logger.notice("ShareExtension dismissed interactively — completing request")
        if !isPersisting { Self.deleteImagePNGs(capturedRefs) }
        complete(success: false)
    }

    /// 자식 UIHostingController 를 전체 화면으로 임베드한다.
    private func embed(_ host: UIViewController) {
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

    private static func logInputProviders(_ context: NSExtensionContext?) {
        guard let context else {
            logger.notice("ShareExtension context is nil")
            return
        }
        for (itemIndex, item) in context.inputItems.compactMap({ $0 as? NSExtensionItem }).enumerated() {
            for (providerIndex, provider) in (item.attachments ?? []).enumerated() {
                logger.notice("provider[\(itemIndex),\(providerIndex)] types: \(provider.registeredTypeIdentifiers.joined(separator: ","), privacy: .public)")
            }
        }
    }

    /// 백탭 단축어 진입(이미지 1장 + 출처앱 sentinel; Safari URL 선택) → 1-step UI ``BackTapShareView``,
    /// 외부 공유시트 진입(sentinel 없는 URL/text 또는 다중 이미지) → 기존 ``ShareEntryView``.
    ///
    /// 백탭은 우리 단축어 경유라 항상 sentinel(`sourceApp`)을 보낸다 → URL 이 채워져도(Safari)
    /// `sourceApp != nil` 로 백탭임을 식별해 1-step UI 를 유지한다. sentinel 없는 단일 이미지+URL
    /// (외부 앱의 기본 공유)은 `ShareEntryView` 로 빠진다.
    @ViewBuilder
    private func contentView(for extracted: ExtractedShareInput) -> some View {
        if extracted.imageRefs.count == 1
            && (extracted.text?.isEmpty ?? true)
            && (extracted.url == nil || extracted.sourceApp != nil) {
            BackTapShareView(
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                sourceApp: extracted.sourceApp,
                url: extracted.url,
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
        isPersisting = true   // 끌어내림 안전망이 큐 적재 이미지를 청소하지 않도록 표식
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
        guard !didComplete else { return }
        didComplete = true
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

    /// 단일 `NSItemProvider` 로드 상한. 단축어가 cross-process 로 넘긴 lazy provider 가 completion 을
    /// 호출하지 않으면 콜백이 영원히 안 와 무한 대기가 된다(이미지+sentinel 을 한 List 로 함께 보낼 때
    /// 관측). ``loadWithItemTimeout`` 의 once-gate 타이머가 이 시간에 끊는다. 정상 로드는 1초 내.
    /// 추출이 attachment 순차라 최악의 경우 provider 수 × 이 값이 누적되므로 과하지 않게 둔다.
    private static let itemLoadTimeout: TimeInterval = 5

    /// 검증 모드 전용 — 입력 item provider 를 로드 후 폐기해 **소비만** 한다.
    /// 미소비 provider 가 매달려 ShareExtension 종료(→host dismiss)를 막는 먹통을 푼다.
    /// 각 provider 는 첫 등록 타입으로 데이터를 읽고 즉시 버린다(persist X). `loadWithItemTimeout`
    /// 이 cross-process hang 을 끊으므로 검증 UI 가 막히지 않는다.
    private static func drainInputProviders(_ context: NSExtensionContext?) async {
        guard let context else { return }
        for item in context.inputItems.compactMap({ $0 as? NSExtensionItem }) {
            for provider in item.attachments ?? [] {
                guard let typeID = provider.registeredTypeIdentifiers.first else { continue }
                _ = await loadWithItemTimeout { (done: @escaping @Sendable (Data?) -> Void) -> Progress? in
                    provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in done(data) }
                }
            }
        }
    }

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
                if provider.hasImageLikeItem {
                    if let ref = await persistImage(from: provider) {
                        imageRefs.append(ref)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), url == nil {
                    if let loaded = await loadItem(from: provider, typeIdentifier: UTType.url.identifier, as: URL.self) {
                        url = loaded
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let loaded = await loadItem(from: provider, typeIdentifier: UTType.plainText.identifier, as: String.self) {
                        // sentinel(자동신호)과 일반 텍스트를 각자 첫 값만 받아 **각 채널로 분리** 흡수한다.
                        // sentinel 은 메타라 text 콘텐츠로 합치지 않아 previewCard 에 raw JSON 이 노출되지 않는다.
                        if let ctx = CaptureContextSentinel.decode(loaded) {
                            if sourceApp == nil { sourceApp = ctx.sourceApp }
                            // sentinel 의 화면상 URL(Safari 등) → url. getOnScreenContent 출력을
                            // public.url 로 못 받던 누락을 메운다. sentinel 은 신뢰경계가 아니므로
                            // http/https + host 가드(끝단 openURL 로 신뢰 못 할 scheme 유입 차단).
                            // 이미 채워졌으면 유지 — 우리 단축어는 raw url 항목을 안 보내 충돌이 없고,
                            // 외부 공유의 public.url 과 겹쳐도 먼저 채운 쪽을 지킨다.
                            if url == nil, let raw = ctx.url, let parsed = URL(string: raw),
                               let scheme = parsed.scheme?.lowercased(),
                               scheme == "http" || scheme == "https", parsed.host != nil {
                                url = parsed
                            }
                        } else if !CaptureContextSentinel.looksLikeSentinel(loaded), text == nil {
                            // marker 가 있는데 decode 실패한 깨진 sentinel 은 text 로 흘리지 않는다
                            // (raw JSON 이 user 콘텐츠로 오염되는 것 방지).
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

    /// 단축어가 cross-process 로 넘기는 in-memory 이미지는 file URL 로 오지 않으므로
    /// `loadItem(...) as? URL` 의존을 버리고 **data representation 을 직접**(+timeout) 받는다.
    /// 이미지+sentinel 을 한 List 로 함께 보낼 때의 무한 대기를 끊고, file·in-memory 양쪽을 받는다.
    private static func persistImage(from provider: NSItemProvider) async -> ImageRef? {
        guard let loaded = await loadImageData(from: provider),
              loaded.data.count <= maxImageBytes else { return nil }

        let data = loaded.data
        let mimeType = loaded.type.preferredMIMEType ?? "application/octet-stream"
        let ext = loaded.type.preferredFilenameExtension ?? "img"
        let filename = "\(UUID().uuidString).\(ext)"
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

    /// provider 에서 image 바이트를 직접 읽는다 — registered 타입 중 image 에 conform 하는 첫 타입의
    /// 표현을 우선하고, Shortcuts 가 `앱과 공유`에서 PNG 를 file provider 로 감쌀 때는 file URL 로
    /// fallback 한다. timeout 은 ``loadWithItemTimeout`` 이 책임진다.
    private static func loadImageData(from provider: NSItemProvider) async -> (data: Data, type: UTType)? {
        let registeredImageType = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first(where: { $0.conforms(to: .image) })
        if let imageType = registeredImageType {
            guard let data = await loadWithItemTimeout({ (done: @escaping @Sendable (Data?) -> Void) -> Progress? in
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in done(data) }
            }) else { return nil }
            return (data, imageType)
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              let fileURL = await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier, as: URL.self),
              let type = imageType(for: fileURL),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return (data, type)
    }

    private static func imageType(for fileURL: URL) -> UTType? {
        guard let type = UTType(filenameExtension: fileURL.pathExtension),
              type.conforms(to: .image) else { return nil }
        return type
    }

    /// `loadItem` 을 timeout 으로 감싸 cross-process provider hang 을 끊는다. timeout·실패·타입
    /// 불일치는 모두 nil — 한 attachment 가 막혀도 나머지(이미지+sentinel)는 계속 흐른다.
    private static func loadItem<T: Sendable>(
        from provider: NSItemProvider,
        typeIdentifier: String,
        as _: T.Type
    ) async -> T? {
        await loadWithItemTimeout { (done: @escaping @Sendable (T?) -> Void) -> Progress? in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                done(item as? T)
            }
            return nil   // loadItem(completion:) 은 Void 반환 — 취소할 Progress 가 없다(timeout 이 직접 끊음)
        }
    }

    /// `NSItemProvider` 의 콜백 로드를 timeout 과 경합시켜, 콜백이 영원히 안 와도 유한 시간에 nil 로 끊는다.
    ///
    /// **왜 structured timeout(`withThrowingTaskGroup` race)이 아닌가**: 콜백 API 는 cancellation 을
    /// 협조 관찰하지 않아, timeout child 가 먼저 끝나도 TaskGroup 이 scope-exit 전에 hang 한 로드 child 를
    /// 암묵적으로 await(SE-0304)해 무한 대기가 그대로 남는다. 그래서 콜백과 타이머를 **단일 continuation**
    /// 에서 once-gate(`OSAllocatedUnfairLock`)로 경합시켜 먼저 도착한 쪽이 정확히 한 번 resume 한다.
    /// timeout 시엔 진행 중 로드의 `Progress.cancel()` 도 시도한다.
    private static func loadWithItemTimeout<T: Sendable>(
        _ start: (@escaping @Sendable (T?) -> Void) -> Progress?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: T?) {
                let isFirst = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { continuation.resume(returning: value) }
            }
            nonisolated(unsafe) let progress = start { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + itemLoadTimeout) {
                progress?.cancel()
                finish(nil)
            }
        }
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

private extension NSItemProvider {
    var hasImageLikeItem: Bool {
        hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
}
