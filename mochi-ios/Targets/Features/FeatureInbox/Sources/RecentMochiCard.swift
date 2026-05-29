import SwiftUI
import CoreDomain

/// "최근 추가한 모찌" / "중요해 보여요" 가로 스크롤의 카드.
///
/// 도메인 `MochiItem` 를 받아 시안의 3가지 카드 변형(screenshot/memo/url)으로 렌더.
struct RecentMochiCard: View {
    let mochiItem: MochiItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                media
                textContent
            }
            .frame(width: 178)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous))
            .cardShadow()
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Media

    @ViewBuilder
    private var media: some View {
        switch mochiItem.viewKind {
        case .screenshot:
            ZStack(alignment: .topLeading) {
                LocalThumbnail(
                    relativePath: mochiItem.source.imageRefs.first?.relativePath,
                    targetSize: CGSize(width: 178, height: 116)
                ) {
                    ZStack {
                        LinearGradient(
                            colors: screenshotGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                tag(MochiItemKind.screenshot)
            }
            .frame(height: 116)
            .clipped()

        case .memo:
            ZStack(alignment: .topLeading) {
                HomeDesign.Color.butter50
                Text(memoPreviewText)
                    .font(.system(size: 11.5, weight: .regular))
                    .lineSpacing(1)
                    .foregroundStyle(HomeDesign.Color.ink700)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HomeDesign.Spacing.md)
                    .padding(.top, 34)
                tag(MochiItemKind.memo)
            }
            .frame(height: 116)

        case .url:
            ZStack(alignment: .topLeading) {
                HomeDesign.Color.purple50
                URLPreviewMini(
                    host: mochiItem.source.url?.host ?? "link",
                    headline: mochiItem.analysis?.summary ?? mochiItem.source.url?.path ?? "",
                    faviconLetter: String(mochiItem.source.url?.host?.prefix(1).uppercased() ?? "L")
                )
                .padding(.horizontal, HomeDesign.Spacing.md)
                .padding(.top, 34)
                tag(MochiItemKind.url)
            }
            .frame(height: 116)
        }
    }

    private func tag(_ kind: MochiItemKind) -> some View {
        MochiItemKindTag(kind: kind)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(HomeDesign.Spacing.sm)
    }

    // MARK: Body (text)

    private var textContent: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            Text(mochiItem.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .tracking(-0.1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: HomeDesign.Spacing.sm) {
                if let intent = mochiItem.analysis?.intent {
                    IntentChip(intent: MochiViewIntent(intent))
                }
                Text(mochiItem.displaySubtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Variant helpers

    private var memoPreviewText: String {
        let raw = mochiItem.source.text ?? mochiItem.analysis?.summary ?? ""
        return raw.isEmpty ? mochiItem.displayTitle : raw
    }

    /// 스크린샷 카드의 그라디언트 — mochiItem ID 해시로 색을 결정해
    /// 같은 항목은 항상 같은 색, 화면 안에서는 변주가 자연스럽게 보이도록.
    private var screenshotGradient: [Color] {
        let palettes: [[Color]] = [
            [HomeDesign.Color.mint100,  HomeDesign.Color.mint400.opacity(0.45)],
            [HomeDesign.Color.blush100, HomeDesign.Color.peach400.opacity(0.4)],
            [HomeDesign.Color.sky100,   HomeDesign.Color.sky400.opacity(0.45)],
            [HomeDesign.Color.purple100, HomeDesign.Color.purple400.opacity(0.4)],
            [HomeDesign.Color.butter100, HomeDesign.Color.butter400.opacity(0.4)],
        ]
        let idx = abs(mochiItem.id.uuidString.hashValue) % palettes.count
        return palettes[idx]
    }
}

// MARK: - URL preview mini

private struct URLPreviewMini: View {
    let host: String
    let headline: String
    let faviconLetter: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(faviconLetter)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3).fill(HomeDesign.Color.purple500))
                Text(host)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .lineLimit(1)
            }
            Text(headline)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, HomeDesign.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }
}

// MARK: - Intent chip (compact)

struct IntentChip: View {
    let intent: MochiViewIntent

    var body: some View {
        Text(intent.label)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.05)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(intent.chipBackground)
            )
            .foregroundStyle(intent.dotColor)
    }
}
