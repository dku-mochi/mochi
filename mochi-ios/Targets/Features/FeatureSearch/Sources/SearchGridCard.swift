import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 2col 그리드 카드 — compact thumbnail, height 138, radius = 홈 item 카드(md).
///
/// 요소 언어는 홈(RecentMochiCard·MochiItemKindTag)을 따른다 — 캐릭터는 귀엽되
/// 카드·배지 같은 구조 요소는 작고 실용적으로.
///
/// type 별 분기:
/// - 링크: 제목 → 메타 → spacer → mini link preview
/// - 스크린샷: 실제 썸네일(있으면) 또는 텍스트 preview 박스 → spacer → 메타
/// - 메모/미확인: 제목 → 본문 2줄 → spacer → 메타
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

    var body: some View {
        Button {
            onTap(HeroSourceFrames(
                card: cardFrame,
                cardImage: hasRealThumbnail ? mediaFrame : nil,
                imageRelativePath: item.source.imageRefs.first?.relativePath
            ))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                topRow
                cardBody
            }
            .padding(SearchD5.Sizes.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SearchD5.Sizes.gridCardHeight)
            .background(
                RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous)
                    .fill(SearchD5.Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous)
                    .stroke(SearchD5.Palette.cardBorder, lineWidth: 1)
            )
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

    // MARK: - Top row

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

    // MARK: - Body (type 분기)

    @ViewBuilder
    private var cardBody: some View {
        switch typeFilter {
        case .link:                                linkBody
        case .screenshot:                          screenshotBody
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

    /// 스크린샷: 실제 썸네일이 있으면 이미지 strip, 없으면(mock) 텍스트 preview 박스.
    private var screenshotBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
            screenshotPreview
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { mediaFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, newFrame in
                                mediaFrame = newFrame
                            }
                    }
                )
            Spacer(minLength: 0)
            metaRow
        }
    }

    private var memoBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText
            Text(Self.highlight(item.analysis?.summary ?? item.source.text ?? "", ranges: summaryHighlights))
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .lineSpacing(1)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            metaRow
        }
    }

    // MARK: - Reusable

    private var titleText: some View {
        Text(Self.highlight(cardTitle, ranges: titleHighlights))
            .font(.system(size: 14.5, weight: .bold, design: .rounded))
            .tracking(-0.3)
            .foregroundStyle(SearchD5.Palette.textPrimary)
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
        }
        .lineLimit(1)
    }

    // MARK: - Mini previews

    private var linkPreview: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SearchD5.Palette.primaryPale)
                .overlay(
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(SearchD5.Palette.primary)
                )
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.analysis?.summary ?? "링크")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .lineLimit(1)
                Text(item.source.url?.host ?? "example.com")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textTertiary)
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.purple50.opacity(0.55))
        )
    }

    @ViewBuilder
    private var screenshotPreview: some View {
        if hasRealThumbnail {
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.relativePath,
                targetSize: CGSize(width: 160, height: 52),
                alignment: .top
            ) {
                screenshotTextBox
            }
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .stroke(SearchD5.Palette.cardBorder, lineWidth: 1)
            )
        } else {
            screenshotTextBox
        }
    }

    private var screenshotTextBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.analysis?.summary ?? cardTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textPrimary)
                .lineLimit(1)
            if let text = item.source.text, !text.isEmpty,
               text != (item.analysis?.summary ?? "") {
                Text(text)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(SearchD5.Palette.textSecondary)
                    .lineSpacing(1)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private var hasRealThumbnail: Bool {
        item.source.imageRefs.first?.relativePath != nil
    }

    private var shareText: String {
        if let url = item.source.url { return "\(cardTitle)\n\(url.absoluteString)" }
        return cardTitle
    }

    private var cardTitle: String {
        item.instances.first?.label ?? item.analysis?.summary ?? item.source.text ?? "(분석 대기)"
    }

    private var typeFilter: SearchD5.TypeFilter {
        if item.needsReview { return .unconfirmed }
        if SearchD5.TypeFilter.screenshot.matches(item) { return .screenshot }
        if SearchD5.TypeFilter.link.matches(item) { return .link }
        return .memo
    }

    private var sourceLabel: String {
        switch item.source.channel {
        case .kakaoTalk:      return "카카오톡"
        case .instagram:      return "Instagram"
        case .youtube:        return "YouTube"
        case .safari:         return item.source.url?.host ?? "Safari"
        case .screenshot:     return "스크린샷"
        case .appIntent:      return "단축어"
        case .appShareSheet:  return "캘린더"
        case .appDirectInput: return "내 메모"
        case .chat:           return "모찌와 대화"
        case .unknown:        return "기록"
        }
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
