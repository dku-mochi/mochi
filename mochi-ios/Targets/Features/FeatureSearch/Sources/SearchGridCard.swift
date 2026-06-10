import SwiftUI
import CoreDomain

/// 검색 탭 2col 그리드 카드 — v4 spec.
/// 핵심: "찾는 모찌를 *알아보는* 화면" — compact thumbnail, height 138, 1.3:1 비율.
///
/// type 별 분기:
/// - 링크: 제목 → 메타(제목 아래) → spacer → mini link preview (38pt)
/// - 스크린샷: preview 박스 (제목 X, 박스가 main) → spacer → 메타
/// - 메모/미확인: 제목 → 본문 2줄 → spacer → 메타
struct SearchGridCard: View {
    let item: MochiItem
    let onTap: () -> Void
    let onMoreTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
            .shadow(color: Color.black.opacity(0.025), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(GridCardPress())
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(alignment: .center, spacing: 0) {
            TypeBadge(filter: typeFilter)
            Spacer(minLength: 0)
            Button(action: onMoreTap) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    /// 스크린샷: 외부 제목 없이 preview 박스가 카드 main content (시안 정합).
    private var screenshotBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            screenshotPreview
            metaRow
        }
    }

    private var memoBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText
            Text(item.analysis?.summary ?? item.source.text ?? "")
                .font(.system(size: 12.5, weight: .regular))
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
        Text(cardTitle)
            .font(.system(size: 15, weight: .bold))
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
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(SearchD5.Palette.textTertiary)
            Circle().fill(SearchD5.Palette.textTertiary).opacity(0.6)
                .frame(width: 2.5, height: 2.5)
            Text(absoluteDate)
                .font(.system(size: 11.5, weight: .regular))
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SearchD5.Palette.primary)
                )
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.analysis?.summary ?? "링크")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .lineLimit(1)
                Text(item.source.url?.host ?? "example.com")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SearchD5.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SearchD5.Palette.textTertiary)
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 248/255, green: 245/255, blue: 255/255))
        )
    }

    /// 스크린샷 preview — 시안 #47 정합: cardTitle 이 박스 안의 label, summary 가 main bold, text 가 sub.
    /// 카드 main content 라 maxHeight: .infinity 로 확장.
    private var screenshotPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cardTitle)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(SearchD5.Palette.textTertiary)
                .lineLimit(1)

            if let summary = item.analysis?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                    .lineLimit(1)
            }

            if let text = item.source.text, !text.isEmpty,
               text != (item.analysis?.summary ?? "") {
                Text(text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SearchD5.Palette.textSecondary)
                    .lineSpacing(1)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 250/255, green: 251/255, blue: 255/255))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(red: 228/255, green: 231/255, blue: 240/255), lineWidth: 1)
        )
    }

    // MARK: - Helpers

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
        case .unknown:        return "기록"
        }
    }

    private var absoluteDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: item.source.capturedAt)
    }
}

// MARK: - Type badge (v4 — 22pt height, 11pt font)

struct TypeBadge: View {
    let filter: SearchD5.TypeFilter

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: filter.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(filter.label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(-0.2)
        }
        .padding(.horizontal, 7)
        .frame(height: SearchD5.Sizes.badgeHeight)
        .foregroundStyle(filter.activeFg)
        .background(Capsule().fill(filter.activeBg))
    }
}

private struct GridCardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
