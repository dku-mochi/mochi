import UIKit
import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os
import CoreDomain
import CorePersistence
import CorePrivacy

/// 선감지 시트에서 사용자가 정한 가림 결과 — 캡처 화면(아래에 살아있는)이 관찰해 **블러본을 보여주고**
/// 그 위에서 crop/메모를 쓰게 한다. 저장 시 `workingRef`/`decision` 이 payload 에 실린다. 캡처 뷰의
/// 메모·크롭 @State 는 뷰 인스턴스가 유지되므로(관찰 객체만 바뀜) 보존된다.
@MainActor final class CaptureRedaction: ObservableObject {
    /// 가림 적용 후 작업 ref — **원본 `relativePath` 보존 + 블러본은 `redactedRelativePath`** (불변식 1·5).
    /// nil = 미적용(원본 사용) 또는 원본/기기에만 선택. 표시는 블러본(`displayRelativePath`), 정리·업로드는 원본.
    @Published var workingRef: ImageRef?
    /// 적용된 정책 — 저장 payload 에 실린다. nil = 아직 선감지 미해결.
    @Published var decision: PrivacyDecision?
}

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

    /// 캡처 직후 background 선감지 — 저장 탭을 기다리지 않고 민감하면 시트를 자동으로 띄운다.
    private var detectionTask: Task<PrivacyDetection?, Never>?
    /// 선감지 결과 — 캡처 화면이 관찰해 블러본 표시·crop, 저장 시 payload 에 싣는다.
    private let redaction = CaptureRedaction()
    /// 캡처 화면 위에 띄운 선감지 시트(확정/취소 시 제거해 캡처로 복귀, 메모/크롭 유지).
    private var privacyOverlay: UIViewController?
    /// 저장이 시작됐는지 — 선감지가 뒤늦게 끝나도 자동 시트를 띄우지 않게.
    private var didSubmit = false
    /// 사용자가 선감지 시트를 가림 없이 닫았는지 — 저장 시 재감지/재프롬프트 skip.
    private var privacyDismissed = false

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
            // 캡처를 보여준 **직후** background 선감지 시작 — 화면 표시·기록은 막지 않는다(기록 지연 0).
            startEarlyDetection(for: extracted.imageRefs.first)
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
                redaction: redaction,
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                sourceApp: extracted.sourceApp,
                url: extracted.url,
                onSubmit: { [weak self] payload, crop in self?.persist(payload, crop: crop, original: extracted.imageRefs) },
                onCancel: { [weak self] in self?.cancel(cleaning: extracted.imageRefs) }
            )
        } else {
            ShareEntryView(
                redaction: redaction,
                initialURL: extracted.url,
                initialText: extracted.text,
                imageRefs: extracted.imageRefs,
                channelGuess: extracted.channelGuess,
                sourceApp: extracted.sourceApp,
                onSubmit: { [weak self] payload, crop in self?.persist(payload, crop: crop, original: extracted.imageRefs) },
                onCancel: { [weak self] in self?.cancel(cleaning: extracted.imageRefs) }
            )
        }
    }

    /// 캡처 직후 첫 이미지를 background 로 선감지한다 — 화면 표시는 즉시(감지가 막지 않음).
    /// 민감하면 저장 탭을 기다리지 않고 시트를 **캡처 화면 위에 자동으로** 띄운다("감지하자마자").
    private func startEarlyDetection(for ref: ImageRef?) {
        guard let ref else { return }
        let task = Task.detached(priority: .userInitiated) {
            await Self.detectPrivacy(for: ref)
        }
        detectionTask = task
        Task { @MainActor [weak self] in
            let detection = await task.value
            guard let self, let detection,
                  !self.didSubmit, !self.privacyDismissed,
                  self.redaction.decision == nil, self.privacyOverlay == nil else { return }
            self.presentEarlyPrivacy(detection)
        }
    }

    /// 캡처 화면 **위에** 선감지 시트를 띄운다 — 캡처 화면은 아래 살아 있어 메모/크롭 입력이 유지된다.
    /// 확정 = 가림 결정을 저장해 두고 캡처로 복귀(저장 탭 때 그대로 적용). 취소 = 가림 없이 복귀.
    private func presentEarlyPrivacy(_ detection: PrivacyDetection) {
        let host = UIHostingController(rootView: PrivacyChoiceView(
            assessment: detection.assessment,
            originalImage: detection.originalImage,
            detectedRegions: detection.regions,
            textBoxes: detection.textBoxes,
            confirmTitle: "이대로 적용하기",
            cancelTitle: "가리지 않고 둘게요",
            onChoose: { [weak self] policy, enabledRegions in
                guard let self else { return }
                // 블러인데 켠 영역이 없으면 원본으로 자연 강등.
                let effective: PrivacyPolicy = (policy == .blurredUpload && enabledRegions.isEmpty) ? .originalUpload : policy
                Task { @MainActor in
                    let blurRef = await Self.makeBlur(
                        policy: effective, rects: enabledRegions.map(\.rect),
                        original: detection.originalRef
                    )
                    // 가림 적용 → 캡처 화면이 블러본(`displayRelativePath`)을 작업 이미지로 보여주고 그 위에서
                    // crop/메모. `workingRef` 는 원본 `relativePath` 를 보존하므로 저장 청소가 원본을 지우지 않는다.
                    // 저장 시 이 결정이 payload 에 실린다. (블러면 workingRef=원본+블러본, 원본/기기에만이면 nil)
                    self.redaction.workingRef = blurRef
                    self.redaction.decision = PrivacyDecision(policy: effective, level: detection.assessment.level)
                    self.dismissPrivacyOverlay()
                }
            },
            onCancel: { [weak self] in
                self?.privacyDismissed = true
                self?.dismissPrivacyOverlay()
            }
        ))
        privacyOverlay = host
        embed(host)
    }

    private func dismissPrivacyOverlay() {
        guard let host = privacyOverlay else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        privacyOverlay = nil
    }

    /// 큐에 떨굴 때, (a) 사용자 코너 크롭을 첫 이미지에 적용해 새 ref 로 교체하고, (b) 일반 메모
    /// 모드로 사용자가 제거한 이미지(원본엔 있었으나 payload 엔 빠진)의 고아 PNG 를 함께 청소한다.
    /// 크롭으로 교체된 원본도 (b) 로직(원본엔 있고 최종 payload 엔 없는 ref)에 걸려 자동 정리된다.
    private func persist(_ payload: InboundIngestPayload, crop: CGRect, original: [ImageRef]) {
        isPersisting = true   // 끌어내림 안전망이 큐 적재 이미지를 청소하지 않도록 표식
        didSubmit = true      // 선감지가 뒤늦게 끝나도 자동 시트를 띄우지 않게

        Task { [weak self] in
            guard let self else { return }
            // 0) 사용자 크롭 적용 — 디코드·재인코딩·파일쓰기는 무거우므로 메인 밖에서. 크롭이 사실상
            //    전체거나 실패하면 payload 그대로(원본 유지). 멱등키(payload.id)는 보존한다.
            let finalPayload = await Task.detached(priority: .userInitiated) {
                Self.applyCrop(crop, to: payload)
            }.value

            // 크롭 교체 원본 + 메모 모드 제거 이미지를 함께 청소.
            let removed = original.filter { ref in
                !finalPayload.imageRefs.contains { $0.relativePath == ref.relativePath }
            }
            Self.deleteImagePNGs(removed)

            // 크롭으로 교체된 블러본 파생도 청소 — 크롭 시 잘린 블러본을 새로 만들므로 크롭 전 블러본이
            // 위 `removed`(relativePath 만 비교)에 안 걸려 고아로 남는다. 최종 payload 에 없는 블러본만 지운다.
            let finalRedacted = Set(finalPayload.imageRefs.compactMap(\.redactedRelativePath))
            for path in payload.imageRefs.compactMap(\.redactedRelativePath) where !finalRedacted.contains(path) {
                try? FileManager.default.removeItem(at: AppGroup.containerURL.appendingPathComponent(path))
            }

            // 선감지에서 이미 가림이 정해졌거나(payload.privacy — 캡처 뷰가 실어 보냄) 사용자가 가림을
            // 거부했으면 재감지 없이 그대로 저장한다(크롭은 블러본/원본 무엇이든 위에서 이미 적용됨).
            if finalPayload.privacy != nil || self.privacyDismissed {
                await self.proceedSave(finalPayload)
                return
            }

            // 선감지가 저장보다 늦은(아주 빠른 탭) fallback — 저장 시점 감지로 시트를 띄운다.
            if let detection = await Self.detectPrivacy(for: finalPayload) {
                self.presentPrivacyChoice(detection, payload: finalPayload, original: original)
                return
            }
            await self.proceedSave(finalPayload)
        }
    }

    /// 큐 적재(진실원천) + best-effort 직접전송 + 성공 종료. 민감/비민감 경로 공통 저장 로직.
    private func proceedSave(_ finalPayload: InboundIngestPayload) async {
        // 성공 모먼트(`ShareSuccessOverlay`)의 최소 노출시간 — 직접전송이 즉시 반환되는 빠른 경로에서
        // 한 프레임만 깜빡이고 닫히는 glitch 를 막고 "기억했어요!" 를 읽을 시간을 보장한다.
        let minSuccessDisplay = Task { try? await Task.sleep(nanoseconds: 900_000_000) }
        // 큐 적재가 **항상 진실원천** — 로컬 Realm ingest·동기화·유실 방지(다음 active tick 의
        // drain → upsert → SyncWorker 업로드). 직접전송보다 먼저 써 유실을 0으로 만든다.
        let fileURL = AppGroup.inboundQueueURL.appendingPathComponent("\(finalPayload.id.uuidString).json")
        if let data = try? JSONEncoder().encode(finalPayload) {
            try? data.write(to: fileURL, options: [.atomic])
        }
        // best-effort 선반영 — 서버 분석을 앱 부팅 전 조기 트리거. 멱등키(payload.id)가 drain·
        // SyncWorker 재전송과 같은 행을 반환해 이중 적재가 없다. 업로드는 privacy 정책에 따라
        // 원본/블러본/스킵으로 분기된다(`ShareExtDirectUpload`).
        await ShareExtDirectUpload.attempt(finalPayload, queueFileURL: fileURL)
        await minSuccessDisplay.value
        complete(success: true)
    }

    /// 민감 선택 시트를 현재 화면 위에 띄운다. 선택 결과를 payload 에 반영해 저장으로 잇는다.
    private func presentPrivacyChoice(
        _ detection: PrivacyDetection,
        payload: InboundIngestPayload,
        original: [ImageRef]
    ) {
        let view = PrivacyChoiceView(
            assessment: detection.assessment,
            originalImage: detection.originalImage,
            detectedRegions: detection.regions,
            textBoxes: detection.textBoxes,
            onChoose: { [weak self] policy, enabledRegions in
                guard let self else { return }
                // 블러 정책인데 켠 영역이 하나도 없으면 원본 저장으로 자연 강등(사용자가 다 끔).
                let effective: PrivacyPolicy = (policy == .blurredUpload && enabledRegions.isEmpty) ? .originalUpload : policy
                self.embed(UIHostingController(rootView: ShareSuccessOverlay()))
                Task {
                    // 사용자가 고른 영역만 블러본 생성 — 디코드·블러·파일쓰기는 메인 밖에서.
                    let blurRef = await Self.makeBlur(
                        policy: effective,
                        rects: enabledRegions.map(\.rect),
                        original: detection.originalRef
                    )
                    let updated = Self.applyPrivacy(
                        effective,
                        level: detection.assessment.level,
                        blurRef: blurRef,
                        to: payload
                    )
                    await self.proceedSave(updated)
                }
            },
            onCancel: { [weak self] in self?.cancel(cleaning: original) }
        )
        embed(UIHostingController(rootView: view))
    }

    /// 블러 정책일 때만, 사용자가 고른 영역으로 블러본 PNG 를 만들고 **원본 ref 에 블러본을
    /// `redactedRelativePath` 로 붙인** 파생 ref 를 돌려준다. `relativePath`·원본 PNG 는 그대로 보존되고
    /// (불변식 1·5), `objectKey` 는 nil(블러본 미업로드 — 업로드 워커가 정책에 따라 새로 올린다).
    ///
    /// 블러 소스는 **업로드 변환과 같은 1920px** 로 디코드한다 — 업로드(`makeUploadVariant`, `maxLongEdge:1920`)가
    /// 어차피 1920px 장변으로 줄이므로, 저장/업로드되는 블러본은 **원본 업로드와 동일 해상도**다(표시는 더
    /// 다운샘플). ⚠️ **ShareExtension 120MB 메모리 한도** — 4096px 같은 큰 디코드 + 가우시안 블러는 OOM 으로
    /// 익스텐션이 강제 종료된다(반드시 1920 유지). 감지 rect 는 정규화(0–1)라 해상도와 무관하게 그대로 매핑된다.
    /// OCR(`detectPrivacy`)·블러는 둘 다 이 `downsampledCGImage`(transform-baked 정립)로 같은 좌표계를 공유한다.
    /// 메인 스레드 밖에서 수행한다(디코드·블러·인코딩이 무겁다).
    private static func makeBlur(policy: PrivacyPolicy, rects: [CGRect], original: ImageRef) async -> ImageRef? {
        guard policy == .blurredUpload, !rects.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let url = AppGroup.containerURL.appendingPathComponent(original.relativePath)
            guard let data = try? Data(contentsOf: url),
                  let cg = Self.downsampledCGImage(from: data, maxPixel: 1920),
                  let blurredCG = ImageBlurRedactor().redactedImage(from: cg, normalizedRects: rects),
                  let blurredPath = Self.writeBlurredPNG(blurredCG, refID: original.id) else { return nil }
            return ImageRef(
                id: original.id,
                relativePath: original.relativePath,
                mimeType: original.mimeType,
                byteSize: original.byteSize,
                sha256: original.sha256,
                objectKey: nil,
                redactedRelativePath: blurredPath
            )
        }.value
    }

    /// 사용자 선택(정책)을 payload 에 반영 — 대상 이미지 ref 를 블러본 파생 ref(`makeBlur` 가 만든,
    /// 원본 `relativePath` 보존 + 블러본 `redactedRelativePath`)로 교체하고 privacy 결정을 싣는다.
    /// 블러본이 없으면(원본/기기에만 정책, 또는 블러 실패) 원본 ref 그대로 + 결정만 싣는다.
    private static func applyPrivacy(
        _ policy: PrivacyPolicy,
        level: SensitivityLevel,
        blurRef: ImageRef?,
        to payload: InboundIngestPayload
    ) -> InboundIngestPayload {
        let refs = payload.imageRefs.map { ref -> ImageRef in
            guard let blurRef, ref.id == blurRef.id else { return ref }
            return blurRef
        }
        return InboundIngestPayload(
            id: payload.id,
            url: payload.url,
            text: payload.text,
            userMemo: payload.userMemo,
            channelGuess: payload.channelGuess,
            imageRefs: refs,
            privacy: PrivacyDecision(policy: policy, level: level)
        )
    }

    /// 첫 이미지를 OCR→패턴 감지하고, 고신뢰 신호가 있으면 블러본까지 만들어 선택 시트 입력을 준비한다.
    /// 비민감(시트 불필요)이면 `nil` 을 반환해 호출부가 기존 경로로 저장하게 한다.
    private static func detectPrivacy(for payload: InboundIngestPayload) async -> PrivacyDetection? {
        guard let ref = payload.imageRefs.first else { return nil }   // 이미지 캡처만 대상
        return await detectPrivacy(for: ref)
    }

    /// 지정 이미지를 OCR→패턴 감지한다. 고신뢰 신호가 없으면(시트 불필요) `nil`.
    /// 블러본은 **확정 시** 사용자가 고른 영역으로만 생성한다(`makeBlur`) — 여기서 미리 굽지 않는다.
    /// 반환된 `originalRef` 가 블러본 파생 ref 의 베이스(원본 `relativePath`/메타 보존)다.
    private static func detectPrivacy(for ref: ImageRef) async -> PrivacyDetection? {
        let url = AppGroup.containerURL.appendingPathComponent(ref.relativePath)
        guard let data = try? Data(contentsOf: url),
              let cgImage = downsampledCGImage(from: data) else { return nil }

        let result = await SensitiveCaptureScanner().scan(cgImage: cgImage)
        guard result.assessment.shouldPromptUser else { return nil }

        return PrivacyDetection(
            assessment: result.assessment,
            originalImage: UIImage(cgImage: cgImage),
            originalRef: ref,
            regions: result.regions,
            textBoxes: result.textBoxes
        )
    }

    /// OCR·블러용 다운샘플 CGImage. Share Extension 120MB 한도 안에서 메모리를 아끼려 장변을 제한한다.
    private static func downsampledCGImage(from data: Data, maxPixel: CGFloat = 1920) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 블러본 PNG 를 App Group `captures/` 에 쓰고 그 상대경로를 돌려준다 — **원본 PNG 는 건드리지 않는다**.
    /// 이 경로는 ref 의 `redactedRelativePath`(표시·업로드용)로만 쓰이고, `relativePath`(원본)는 보존된다
    /// (불변식 1·5). 실패 시 nil.
    private static func writeBlurredPNG(_ cgImage: CGImage, refID: UUID) -> String? {
        let relativePath = "captures/\(refID.uuidString).blurred.png"
        let url = AppGroup.containerURL.appendingPathComponent(relativePath)
        guard let data = UIImage(cgImage: cgImage).pngData(),
              (try? data.write(to: url, options: [.atomic])) != nil else { return nil }
        return relativePath
    }

    /// 첫 이미지에 코너 크롭을 적용해 imageRefs[0] 을 새 ref 로 교체한 payload 를 만든다.
    /// 크롭이 전체(또는 실패)면 원본 payload 를 그대로 돌려준다. **멱등키 `id` 는 보존**한다.
    private static func applyCrop(_ crop: CGRect, to payload: InboundIngestPayload) -> InboundIngestPayload {
        guard let first = payload.imageRefs.first,
              let cropped = ShareImageCropper.croppedRef(from: first, crop: crop) else { return payload }
        var refs = payload.imageRefs
        refs[0] = cropped
        return InboundIngestPayload(
            id: payload.id,
            url: payload.url,
            text: payload.text,
            userMemo: payload.userMemo,
            channelGuess: payload.channelGuess,
            imageRefs: refs,
            privacy: payload.privacy
        )
    }

    /// 민감 감지 결과 묶음 — 선택 시트 입력용(원본 + 라벨 영역 + 수동 후보 박스).
    /// `UIImage`/`CGImage` 는 생성 후 읽기 전용이라 detached 선감지 task 경계로 안전히 넘긴다.
    private struct PrivacyDetection: @unchecked Sendable {
        let assessment: SensitivityAssessment
        /// 미리보기·감지용 다운샘플(1920px). 시트 라이브 블러는 이걸로 충분.
        let originalImage: UIImage
        /// 블러본 파생 ref 의 베이스 — 원본 `relativePath`/`id`/메타를 보존한다(불변식 1·5).
        let originalRef: ImageRef
        /// 자동 감지된(라벨 달린) 블러 후보.
        let regions: [RedactionRegion]
        /// 모든 OCR 텍스트 줄 영역(수동 가림 후보).
        let textBoxes: [CGRect]
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
