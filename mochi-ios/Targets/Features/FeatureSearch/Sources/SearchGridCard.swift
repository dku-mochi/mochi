import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 2col 그리드 카드 — type 별 가변 높이 (스크린샷 이미지-led 182 / 그 외 138).
///
/// 요소 언어는 홈(RecentMochiCard·MochiItemKindTag)을 따른다 — 캐릭터는 귀엽되
/// 카드·배지 같은 구조 요소는 작고 실용적으로.
///
/// type 별 layout:
/// - 스크린샷(+이미지): 미디어가 카드 상단 edge-to-edge (배지 overlay) → 제목 → 메타. 홈 카드 패턴.
/// - 스크린샷(이미지 없음): 제목 → 텍스트 preview 박스 → 메타 (서버 복구 전 폴백)
/// - 링크: 제목 → 메타 → favicon letter mini preview
/// - 메모/미확인: 제목 → 본문 2줄 (인용 워터마크) → 메타
struct SearchGridCard: View {
    let item: MochiItem
    /// 검색어 매칭 위치 — 결과 화면에서만 전달. 기본 화면(.idle) 카드는 빈 배열.
    let titleHighlights: [HighlightRange]
    let summaryHighlights: [HighlightRange]
    /// 탭 시 카드 frame 묶음을 넘긴다 — 홈 카드와 동일한 hero 확대 전환의 시작점.
    let onTap: (HeroSourceFrames) -> Void
    let onDelete: () -> Void

    @State private var cardFrame: CGRect = .zero
    @State private var mediaFrame: CGRect = .zero

    init(
        item: MochiItem,
        titleHighlights: [HighlightRange] = [],
        summaryHighlights: [HighlightRange] = [],
        onTap: @escaping (HeroSourceFrames) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.titleHighlights = titleHighlights
        self.summaryHighlights = summaryHighlights
        self.onTap = onTap
        self.onDelete = onDelete
    }

    /// masonry 분배가 쓰는 카드 예상 높이 — 이미지-led 스크린샷만 크다.
    static func estimatedHeight(for item: MochiItem) -> CGFloat {
        isImageLed(item) ? 182 : 138
    }

    private static func isImageLed(_ item: MochiItem) -> Bool {
        !item.needsReview
            && SearchD5.TypeFilter.screenshot.matches(item)
            && item.source.imageRefs.first?.relativePath != nil
    }

    var body: some View {
        Button {
            onTap(HeroSourceFrames(
                card: cardFrame,
                cardImage: Self.isImageLed(item) ? mediaFrame : nil,
                imageRelativePath: item.source.imageRefs.first?.relativePath
            ))
        } label: {
            Group {
                if Self.isImageLed(item) {
                    imageLedBody
                } else {
                    textCardBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.estimatedHeight(for: item))
            .background(
                RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous)
                    .fill(SearchD5.Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous)
                    .stroke(SearchD5.Palette.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous))
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(PressableStyle())
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        cardFrame = newFrame
                    }
            }
        )
        .contextMenu {
            ShareLink(item: shareText) {
                Label("공유", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive, action: onDelete) {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    // MARK: - 이미지-led (스크린샷 + 로컬 이미지) — 홈 RecentMochiCard 패턴

    private var imageLedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                LocalThumbnail(
                    relativePath: item.source.imageRefs.first?.relativePath,
                    targetSize: CGSize(width: 180, height: 100),
                    alignment: .top
                ) {
                    LinearGradient(
                        colors: [HomeDesign.Color.sky100, HomeDesign.Color.purple100],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(height: 100)
                .clipped()

                overlayBadge
                    .padding(HomeDesign.Spacing.sm)
            }
            .frame(height: 100)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { mediaFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            mediaFrame = newFrame
                        }
                }
            )

            VStack(alignment: .leading, spacing: 4) {
                titleText
                Spacer(minLength: 0)
                metaRow
            }
            .padding(SearchD5.Sizes.cardPadding)
        }
    }

    /// 이미지 위 배지 — 홈 tag() 와 동일하게 material 캡슐로 가독성 확보.
    private var overlayBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: SearchD5.TypeFilter.screenshot.systemImage)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
            Text(SearchD5.TypeFilter.screenshot.label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.05)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(HomeDesign.Color.ink700)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - 텍스트 카드 (링크/메모/미확인/이미지 없는 스크린샷)

    private var textCardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            cardBody
        }
        .padding(SearchD5.Sizes.cardPadding)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 0) {
            TypeBadge(filter: typeFilter)
            Spacer(minLength: 0)
            Menu {
                ShareLink(item: shareText) {
                    Label("공유", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("삭제", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch typeFilter {
        case .link:                                linkBody
        case .screenshot:                          screenshotTextBody
        case .memo, .unconfirmed, .all:            memoBody
        }
    }

    private var linkBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleText
            metaRow
            Spacer(minLength: 2)
            linkPreview
        }
    }

    /// 이미지 없는 스크린샷 (서버 복구 전 등) — 텍스트 preview 박스 폴백.
    private var screenshotTextBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
            screenshotTextBox
            Spacer(minLength: 0)
            metaRow
        }
    }

    private var memoBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText
            Text(Self.highlight(bodyPreview, ranges: summaryHighlights))
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .lineSpacing(1)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    // 홈 메모 카드의 종이 인용 워터마크 미니 버전 — 메모 정체성.
                    Image(systemName: "quote.closing")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.butter400.opacity(0.16))
                        .offset(x: -2, y: 2)
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 0)
            metaRow
        }
    }

    // MARK: - Reusable

    private var titleText: some View {
        Text(Self.highlight(cardTitle, ranges: titleHighlights))
            .font(.system(size: 14.5, weight: .bold, design: .rounded))
            .tracking(-0.3)
            .foregroundStyle(isAnalyzing ? SearchD5.Palette.textSecondary : SearchD5.Palette.textPrimary)
            .lineSpacing(0.5)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(sourceLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textTertiary)
            Circle().fill(SearchD5.Palette.textTertiary).opacity(0.6)
                .frame(width: 2.5, height: 2.5)
            Text(absoluteDate)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textTertiary)
            if isAnalyzing {
                Circle().fill(SearchD5.Palette.textTertiary).opacity(0.6)
                    .frame(width: 2.5, height: 2.5)
                Text("분석 중")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.primary)
            }
        }
        .lineLimit(1)
    }

    // MARK: - Mini previews

    /// 링크 preview — 홈 URLPreviewMini 의 favicon letter 패턴 (host 첫 글자 보라 타일).
    private var linkPreview: some View {
        HStack(spacing: 7) {
            Text(faviconLetter)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.analysis?.summary ?? "링크")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .lineLimit(1)
                Text(item.source.url?.host ?? "")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textTertiary)
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.purple50.opacity(0.55))
        )
    }

    private var screenshotTextBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.analysis?.summary ?? cardTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textPrimary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .stroke(SearchD5.Palette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var isAnalyzing: Bool { item.analysis == nil }

    private var shareText: String {
        if let url = item.source.url { return "\(cardTitle)\n\(url.absoluteString)" }
        return cardTitle
    }

    /// 제목 위생 — 홈과 같은 `displayTitle` 위계(교정 제목 → AI 제목 → 요약 → 원문 → host)에
    /// 백탭 캡처가 원문 선두에 넣는 "[출처앱: …]" 류 메타 블록 제거를 더한다.
    private var cardTitle: String {
        let cleaned = Self.stripSourceMeta(item.displayTitle)
        if cleaned.isEmpty {
            return isAnalyzing ? "모찌가 정리하고 있어요" : item.displayTitle
        }
        return cleaned
    }

    /// 선두의 "[출처앱: Instagram]" 같은 대괄호 메타 블록(연속 포함)을 걷어낸다.
    private static func stripSourceMeta(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private var bodyPreview: String {
        let raw = item.analysis?.summary ?? item.source.text ?? ""
        return Self.stripSourceMeta(raw)
    }

    private var faviconLetter: String {
        String(item.source.url?.host?.replacingOccurrences(of: "www.", with: "").prefix(1) ?? "L").uppercased()
    }

    private var typeFilter: SearchD5.TypeFilter {
        if item.needsReview { return .unconfirmed }
        if SearchD5.TypeFilter.screenshot.matches(item) { return .screenshot }
        if SearchD5.TypeFilter.link.matches(item) { return .link }
        return .memo
    }

    private var sourceLabel: String {
        if item.source.channel == .safari, let host = item.source.url?.host { return host }
        return item.source.channel.shortLabel
    }

    private var absoluteDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: item.source.capturedAt)
    }

    /// 검색어 매칭 위치를 노란 highlight 배경으로 강조.
    /// UTF-16 offset 기반 `HighlightRange` 를 `AttributedString` substring 매칭으로 변환.
    private static func highlight(_ text: String, ranges: [HighlightRange]) -> AttributedString {
        var attr = AttributedString(text)
        guard !ranges.isEmpty else { return attr }
        let ns = text as NSString
        for r in ranges {
            guard r.location >= 0, r.location + r.length <= ns.length else { continue }
            let substring = ns.substring(with: NSRange(location: r.location, length: r.length))
            if let range = attr.range(of: substring) {
                attr[range].backgroundColor = HomeDesign.Color.butter100
                attr[range].foregroundColor = HomeDesign.Color.ink900
            }
        }
        return attr
    }
}

// MARK: - Type badge (홈 MochiItemKindTag 스케일 — 작고 실용적)

struct TypeBadge: View {
    let filter: SearchD5.TypeFilter

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: filter.systemImage)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
            Text(filter.label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.05)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(filter.activeFg)
        .background(Capsule().fill(filter.activeBg))
        .overlay(Capsule().stroke(HomeDesign.Color.border, lineWidth: 1))
    }
}
