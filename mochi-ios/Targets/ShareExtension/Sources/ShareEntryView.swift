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
/// 디자인 토큰/컴포넌트는 ``ShareDesign`` 을 통해 ``BackTapShareView`` 와 공유한다.
struct ShareEntryView: View {
    let initialURL: URL?
    let initialText: String?
    let imageRefs: [ImageRef]
    let channelGuess: IngestChannel
    let onSubmit: (InboundIngestPayload) -> Void
    let onCancel: () -> Void

    @State private var memo: String = ""

    /// 이미지만 들어왔고 URL/텍스트가 없다면, BackTap 과 같은 "스크린샷 우세" 레이아웃.
    private var isImageDominant: Bool {
        !imageRefs.isEmpty && initialURL == nil && (initialText?.isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient
                .ignoresSafeArea()

            content
        }
        .overlay(alignment: .topLeading) {
            ShareCloseButton(action: onCancel)
                .padding(.top, 12)
                .padding(.leading, 16)
        }
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

    /// 이미지가 화면 대부분 — 헤더는 컴팩트, preview 가 maxHeight: .infinity 로 늘어남.
    private var imageDominantLayout: some View {
        VStack(spacing: 14) {
            compactHeader

            if let firstImage = imageRefs.first {
                SharePreviewImage(imageRef: firstImage)
                    .frame(maxHeight: .infinity)
            }

            if imageRefs.count > 1 {
                Text("외 \(imageRefs.count - 1)장 더 · 총 \(totalImageMB)MB")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ShareDesign.muted)
            }

            ShareMemoField(memo: $memo, compact: true)
            SharePrimaryButton(title: "모찌에 저장", action: submit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 52)
        .padding(.bottom, 16)
    }

    /// URL/텍스트 위주 — preview 카드는 컴팩트, 메모는 펼친 모드.
    private var textDominantLayout: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                fullHeader
                previewCard
                ShareMemoField(memo: $memo, compact: false)
                SharePrimaryButton(title: "모찌에 저장", action: submit)
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Header

    private var compactHeader: some View {
        HStack(spacing: 12) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text("모찌에 저장할까요?")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(ShareDesign.title)
        }
    }

    private var fullHeader: some View {
        VStack(spacing: 8) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            Text("모찌에 저장할까요?")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(ShareDesign.title)
        }
        .padding(.top, 4)
    }

    // MARK: - Preview card (text/URL mode)

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = initialURL {
                row(icon: "link", text: url.absoluteString, mono: true, lineLimit: 3)
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

    private var hasURL: Bool { initialURL != nil }
    private var hasText: Bool { !(initialText?.isEmpty ?? true) }
    private var isEmptyPayload: Bool { !hasURL && !hasText && imageRefs.isEmpty }

    private var totalImageMB: String {
        let bytes = imageRefs.reduce(0) { $0 + $1.byteSize }
        return String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }

    private func submit() {
        onSubmit(InboundIngestPayload(
            url: initialURL,
            text: initialText,
            userMemo: memo.isEmpty ? nil : memo,
            channelGuess: channelGuess,
            imageRefs: imageRefs
        ))
    }
}
