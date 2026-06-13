import SwiftUI
import UIKit
import CoreDomain
import DesignSystem

/// "최근 추가한 모찌" / "중요해 보여요" 가로 스크롤의 카드.
///
/// 도메인 `MochiItem` 를 받아 시안의 3가지 카드 변형(screenshot/memo/url)으로 렌더.
struct RecentMochiCard: View {
    let mochiItem: MochiItem
    /// 탭 시 카드 전체의 글로벌 frame 을 넘긴다 — hero 확대(카드 통째 → 상세 헤더)의 시작점.
    let onTap: (HeroSourceFrames) -> Void
    /// 롱프레스 메뉴의 삭제 — soft delete 를 상위(HomeFeature)로 위임.
    let onDelete: () -> Void
    @State private var cardFrame: CGRect = .zero
    /// 카드 미디어(썸네일) 영역의 글로벌 frame — 스크린샷 hero 가 상세 이미지로 자라는 시작점.
    @State private var mediaFrame: CGRect = .zero

    var body: some View {
        Button {
            // 스크린샷 카드는 미디어(이미지) 영역을 상세 이미지로 키운다(주체: 이미지).
            // 단 가로 스크롤에서 카드가 화면 가장자리에 잘려 있으면, 보이는 부분만 비트맵 스냅샷돼
            // 잘린 채로 날아가 어색하다 — 충분히 보일 때만 이미지 hero 를 쓰고 아니면 fade 폴백.
            // 이미지가 없는 memo/url 카드도 cardImage=nil 로 fade 폴백.
            onTap(HeroSourceFrames(
                card: cardFrame,
                cardImage: (mochiItem.viewKind == .screenshot && isMediaFullyVisible) ? mediaFrame : nil,
                imageRelativePath: mochiItem.source.imageRefs.first?.relativePath
            ))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                media
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { mediaFrame = geo.frame(in: .global) }
                                .onChange(of: geo.frame(in: .global)) { _, newFrame in
                                    mediaFrame = newFrame
                                }
                        }
                    )
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
            // 최근 항목은 홈의 보조 영역 — 그림자를 낮춰 확인/입력 영역보다 뒤로 물러나게 한다.
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(PressableStyle())
        // 카드의 글로벌 frame 을 추적해 탭 시점에 넘긴다 (가로 스크롤 위치 반영).
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
            // 편집은 아직 미구현 — placeholder 로 노출하되 비활성.
            Button { } label: { Label("편집", systemImage: "pencil") }
                .disabled(true)
            Button(role: .destructive, action: onDelete) {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    // MARK: Media

    @ViewBuilder
    private var media: some View {
        switch mochiItem.viewKind {
        case .screenshot:
            LocalThumbnail(
                relativePath: mochiItem.source.imageRefs.first?.relativePath,
                targetSize: CGSize(width: 178, height: 134)
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
            .frame(height: 134)
            .clipped()

        case .memo:
            ZStack(alignment: .topLeading) {
                // 종이 메모 느낌 — 버터 톤 그라데이션 + 우하단 인용 워터마크.
                LinearGradient(
                    colors: [HomeDesign.Color.butter50, HomeDesign.Color.cream100],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "quote.closing")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(HomeDesign.Spacing.md)
                Text(memoPreviewText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .lineSpacing(2)
                    .foregroundStyle(HomeDesign.Color.ink700)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HomeDesign.Spacing.md)
                    .padding(.top, HomeDesign.Spacing.md)
            }
            .frame(height: 134)

        case .url:
            ZStack(alignment: .topLeading) {
                HomeDesign.Color.purple50
                URLPreviewMini(
                    host: mochiItem.source.url?.host ?? "link",
                    headline: mochiItem.analysis?.summary ?? mochiItem.source.url?.path ?? "",
                    faviconLetter: String(mochiItem.source.url?.host?.prefix(1).uppercased() ?? "L")
                )
                .padding(.horizontal, HomeDesign.Spacing.md)
                .padding(.top, HomeDesign.Spacing.md)
            }
            .frame(height: 134)
        }
    }

    // MARK: Body (text)

    private var textContent: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            Text(mochiItem.displayTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .tracking(-0.2)
                // 2줄 공간을 항상 확보 — 가로 스크롤에서 카드 높이가 들쭉날쭉하지 않게.
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(mochiItem.displaySubtitle)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Variant helpers

    /// 카드 미디어가 화면 안에 충분히(>=92%) 보이는지 — 가로 스크롤에서 가장자리에 잘린 카드는
    /// 비트맵 스냅샷이 잘린 채 날아가므로, 미달이면 이미지 hero 대신 fade 폴백으로 보낸다.
    private var isMediaFullyVisible: Bool {
        guard mediaFrame.width > 0,
              let screenWidth = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.screen.bounds.width else { return false }
        let visibleLeft = max(mediaFrame.minX, 0)
        let visibleRight = min(mediaFrame.maxX, screenWidth)
        return (visibleRight - visibleLeft) / mediaFrame.width >= 0.92
    }

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
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                Text(host)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            Text(headline)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineSpacing(1)
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
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .shadow(color: HomeDesign.Color.ink900.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}

// IntentChip 은 DesignSystem 으로 승격됨 (HomeViewMapping.swift).
