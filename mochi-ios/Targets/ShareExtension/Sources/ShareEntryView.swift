import SwiftUI
import CoreDomain
import CorePersistence

/// 외부 공유시트 진입 (URL/text 또는 다중 이미지) 의 1-step UI.
///
/// **레이아웃**:
/// - **이미지 우세 모드** (텍스트/URL 없이 이미지만): 첫 이미지가 화면 대부분을 차지하고
///   메모는 한 줄짜리 컴팩트. `BackTapShareView` 와 동일 패턴.
/// - **텍스트/URL 모드**: URL · 텍스트 · 이미지 카운트가 들어간 카드 + 메모 펼친 모드.
///
/// **저장 피드백**: 제출 즉시 ``ShareSuccessOverlay`` 가 화면을 덮는다 (``BackTapShareView`` 와 동일 근거).
///
/// 디자인 토큰/컴포넌트는 ``ShareDesign`` 을 통해 ``BackTapShareView`` 와 공유한다.
struct ShareEntryView: View {
    /// 선감지 결과 — 첫 이미지가 가려지면 블러본을 보여주고 저장 payload 에 싣는다.
    @ObservedObject var redaction: CaptureRedaction
    let initialURL: URL?
    let initialText: String?
    let imageRefs: [ImageRef]
    let channelGuess: IngestChannel
    let sourceApp: String?
    /// 사용자 코너 크롭(이미지 우세 모드에서만, 정규화 0...1). 제출 시 ``ShareImageCropper`` 가 적용한다.
    let onSubmit: (InboundIngestPayload, CGRect) -> Void
    let onCancel: () -> Void
    /// 민감 감지가 있을 때 가림 화면으로 (다시) 들어가는 동선(이미지 우세 모드에서만). nil 이면 미표시.
    var onEditRedaction: (() -> Void)? = nil

    @State private var memo: String = ""
    @State private var crop = ShareCropImage.fullCrop
    @State private var isSubmitting = false
    @State private var appeared = false

    /// 이미지만 들어왔고 URL/텍스트가 없다면, BackTap 과 같은 "스크린샷 우세" 레이아웃.
    private var isImageDominant: Bool {
        !imageRefs.isEmpty && initialURL == nil && (initialText?.isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient
                .ignoresSafeArea()

            content

            if isSubmitting {
                ShareSuccessOverlay()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Content (mode-aware)

    @ViewBuilder
    private var content: some View {
        if isImageDominant {
            imageDominantLayout
        } else {
            textDominantLayout
        }
    }

    /// 이미지가 화면 대부분 — 탑바(취소+출처칩)만 두고 preview 가 maxHeight: .infinity 로 늘어남.
    private var imageDominantLayout: some View {
        VStack(spacing: 14) {
            ShareTopBar(sourceApp: sourceApp, isSubmitting: isSubmitting, onCancel: onCancel)
                .shareEntrance(0, appeared: appeared)

            if let firstImage = redaction.workingRef ?? imageRefs.first {
                ShareCropImage(imageRef: firstImage, crop: $crop)
                    .frame(maxHeight: .infinity)
                    .shareEntrance(1, appeared: appeared)
            }

            if imageRefs.count > 1 {
                Text("외 \(imageRefs.count - 1)장 더 · 총 \(totalImageMB)MB")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ShareDesign.muted)
                    .shareEntrance(2, appeared: appeared)
            }

            if redaction.canEditRedaction, let onEditRedaction {
                redactionEntryButton(onEditRedaction)
                    .shareEntrance(2, appeared: appeared)
            }

            ShareMemoField(memo: $memo, compact: true)
                .shareEntrance(3, appeared: appeared)
            SharePrimaryButton(title: "모찌에 저장", icon: "sparkles", action: submit)
                .shareEntrance(4, appeared: appeared)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    /// URL/텍스트 위주 — 탑바는 스크롤 밖 고정, preview 카드는 컴팩트, 메모는 펼친 모드.
    private var textDominantLayout: some View {
        VStack(spacing: 0) {
            ShareTopBar(sourceApp: sourceApp, isSubmitting: isSubmitting, onCancel: onCancel)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .shareEntrance(0, appeared: appeared)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    previewCard
                        .shareEntrance(1, appeared: appeared)
                    ShareMemoField(memo: $memo, compact: false)
                        .shareEntrance(2, appeared: appeared)
                    SharePrimaryButton(title: "모찌에 저장", icon: "sparkles", action: submit)
                        .shareEntrance(3, appeared: appeared)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Preview card (text/URL mode)

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = initialURL {
                urlRow(url)
            }

            if hasURL && hasText { divider }

            if let text = initialText, !text.isEmpty {
                row(icon: "text.quote", text: text, mono: false, lineLimit: 4)
            }

            if (hasURL || hasText) && !imageRefs.isEmpty { divider }

            if !imageRefs.isEmpty {
                row(
                    icon: "photo.stack",
                    text: "이미지 \(imageRefs.count)장 · \(totalImageMB)MB",
                    mono: false,
                    lineLimit: 1
                )
            }

            if isEmptyPayload {
                row(
                    icon: "square.dashed",
                    text: "첨부된 내용 없음 — 메모만 저장됩니다",
                    mono: false,
                    lineLimit: 2,
                    muted: true
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ShareDesign.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ShareDesign.cardStroke, lineWidth: 1)
                )
        )
    }

    /// 링크는 host 를 제목처럼 강조하고 전체 URL 은 보조로 — "어디서 온 링크인지" 가 먼저 읽힌다.
    private func urlRow(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShareDesign.primary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayHost(of: url))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShareDesign.title)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ShareDesign.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func displayHost(of url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func row(
        icon: String,
        text: String,
        mono: Bool,
        lineLimit: Int,
        muted: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(muted ? ShareDesign.muted : ShareDesign.primary)
                .frame(width: 18)
                .padding(.top, 2)

            Text(text)
                .font(mono
                    ? .system(size: 13, design: .monospaced)
                    : .system(.footnote, design: .rounded))
                .foregroundStyle(muted ? ShareDesign.muted : ShareDesign.title)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(ShareDesign.cardStroke)
            .frame(height: 1)
            .padding(.leading, 28)
    }

    // MARK: - Derived

    /// 선감지로 첫 이미지가 가려졌으면 그 블러본으로 첫 ref 를 교체(나머지 이미지는 유지).
    private var effectiveImageRefs: [ImageRef] {
        guard let wr = redaction.workingRef, !imageRefs.isEmpty else { return imageRefs }
        return [wr] + imageRefs.dropFirst()
    }

    private var hasURL: Bool { initialURL != nil }
    private var hasText: Bool { !(initialText?.isEmpty ?? true) }
    private var isEmptyPayload: Bool { !hasURL && !hasText && imageRefs.isEmpty }

    private var totalImageMB: String {
        let bytes = imageRefs.reduce(0) { $0 + $1.byteSize }
        return String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }

    /// 민감 감지가 있을 때 가림 화면으로 (다시) 들어가는 진입점 — 이미 가렸으면 "가린 곳 고치기", 아직이면 "가리기".
    private var redactionEntryTitle: String {
        redaction.decision?.policy == .blurredUpload ? "가린 곳 고치기" : "가리기"
    }

    private func redactionEntryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text(redactionEntryTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(ShareDesign.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(ShareDesign.primary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(ShareDesign.primary.opacity(0.25), lineWidth: 1))
            .contentShape(Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityLabel(Text(redactionEntryTitle))
    }

    private func submit() {
        guard !isSubmitting else { return }   // 중복 탭 방지
        withAnimation(.easeInOut(duration: 0.2)) { isSubmitting = true }
        ShareHaptics.success()
        onSubmit(
            InboundIngestPayload(
                url: initialURL,
                text: CaptureContextSentinel.composeText(sourceApp: sourceApp, base: initialText),
                userMemo: memo.isEmpty ? nil : memo,
                channelGuess: channelGuess,
                imageRefs: effectiveImageRefs,
                privacy: redaction.decision
            ),
            isImageDominant ? crop : ShareCropImage.fullCrop
        )
    }
}
