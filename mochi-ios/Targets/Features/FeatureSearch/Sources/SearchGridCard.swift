import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 2col 그리드 카드 — 이미지/타이포 모자이크.
///
/// 배지·날짜·출처 같은 chrome 을 모두 걷어내고 카드의 *형태*가 타입을 말한다 —
/// 사진 타일이면 스크린샷, 파스텔 타이포 타일이면 메모/링크. 타입 구분·날짜는
/// 필터칩과 상세 화면이 담당 (시각적으론 빼되 VoiceOver 라벨에는 유지).
///
/// type 별 layout:
/// - 스크린샷(+이미지): 2:3 풀블리드 이미지 + 하단 적응형 스크림 + 흰 제목 overlay.
///   center 크롭 — 사용자가 어느 부분을 중요하게 캡처했는지 모르므로 위쪽을 가정하지 않는다.
/// - 스크린샷(이미지 없음): sky 타일 — 제목 → 텍스트 preview (서버 복구 전 폴백)
/// - 링크: purple 타일 — 제목 → favicon letter + 도메인 한 줄 (도메인은 장식이 아니라 회수 단서)
/// - 메모: butter 타일 / 미확인: ink 타일 — 제목 → 본문 2줄 (인용 워터마크)
struct SearchGridCard: View {
    let item: MochiItem
    /// 검색어 매칭 위치 — 결과 화면에서만 전달. 기본 화면(.idle) 카드는 빈 배열.
    let titleHighlights: [HighlightRange]
    let summaryHighlights: [HighlightRange]
    /// 서버 의미 검색으로 보강된 항목 — 시각 표시는 모자이크 미니멀화로 제거,
    /// VoiceOver 라벨("비슷한 기억으로 찾음")에만 유지.
    let isSemantic: Bool
    /// 탭 시 카드 frame 묶음을 넘긴다 — 홈 카드와 동일한 hero 확대 전환의 시작점.
    let onTap: (HeroSourceFrames) -> Void
    let onDelete: () -> Void

    /// hero 비행 시작 frame 저장소 — *비관찰* class box.
    /// @State CGRect 로 두면 스크롤·키보드 애니메이션 중 global frame 이 매 틱 바뀌며
    /// 보이는 카드 전부가 재렌더되는 연쇄(검색 탭 랙의 주범)가 생긴다.
    /// frame 은 탭 순간에만 필요하므로 쓰기가 뷰를 무효화하지 않는 box 에 담는다.
    @State private var frames = FrameBox()

    /// 썸네일 하단 35% 평균 휘도(0~1) — 스크림 강도를 이미지에 맞춘다.
    /// 측정 전 기본값은 밝음(0.8) — 모찌 캡처 대부분이 흰 배경 스크린샷이고,
    /// 로드 전 placeholder 도 밝은 파스텔이라 진한 스크림이 안전하다.
    @State private var bottomLuminance: CGFloat = 0.8

    private final class FrameBox {
        var card: CGRect = .zero
        var media: CGRect = .zero
    }

    init(
        item: MochiItem,
        titleHighlights: [HighlightRange] = [],
        summaryHighlights: [HighlightRange] = [],
        isSemantic: Bool = false,
        onTap: @escaping (HeroSourceFrames) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.titleHighlights = titleHighlights
        self.summaryHighlights = summaryHighlights
        self.isSemantic = isSemantic
        self.onTap = onTap
        self.onDelete = onDelete
    }

    /// masonry 분배가 쓰는 카드 예상 높이.
    /// 스크린샷+썸네일 = 2:3 풀블리드 이미지 (col 폭 ~184 × 1.5 ≈ 275, 제목은 overlay 라 추가 높이 없음).
    static func estimatedHeight(for item: MochiItem) -> CGFloat {
        Self.hasThumbnail(item) ? 275 : 138
    }

    private static func hasThumbnail(_ item: MochiItem) -> Bool {
        item.source.imageRefs.first?.relativePath != nil
    }

    private var hasThumbnail: Bool { Self.hasThumbnail(item) }

    var body: some View {
        Button {
            onTap(HeroSourceFrames(
                card: frames.card,
                cardImage: hasThumbnail ? frames.media : nil,
                imageRelativePath: item.source.imageRefs.first?.relativePath
            ))
        } label: {
            Group {
                if hasThumbnail {
                    // showcase 카드 — 이미지 비율이 높이를 정하므로 고정 frame 없음.
                    showcaseBody
                } else {
                    textCardBody
                        .frame(height: Self.estimatedHeight(for: item))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // edge-to-edge 모자이크 — 테두리·그림자 없이 6pt 이음새 + radius 가 셀을 구분한다.
            .background(
                RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous)
                    .fill(tileBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: SearchD5.Sizes.gridCardRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frames.card = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        frames.card = newFrame
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
        } preview: {
            SearchCardPreview(item: item)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("두 번 탭하면 상세를 열어요")
    }

    private var accessibilitySummary: String {
        var parts = [typeFilter.label, cardTitle, "\(sourceLabel), \(absoluteDate)"]
        if isAnalyzing { parts.append("분석 중") }
        if isSemantic { parts.append("비슷한 기억으로 찾음") }
        return parts.joined(separator: ", ")
    }

    // MARK: - 텍스트 카드 (파스텔 타이포 타일 — 글자가 곧 커버)

    private var textCardBody: some View {
        cardBody
            .padding(HomeDesign.Spacing.md)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch typeFilter {
        case .link:                                linkBody
        case .screenshot:                          screenshotTextBody
        case .memo, .unconfirmed, .all:            memoBody
        }
    }

    /// 카드 바탕 — 이미지 카드는 surface(이미지가 전부 덮음), 텍스트 타일은 타입 파스텔.
    /// 필터칩(activeBg)과 같은 색이라 "타일 색 = 타입" 매핑이 화면 안에서 자가 설명된다.
    private var tileBackground: Color {
        hasThumbnail ? SearchD5.Palette.card : typeFilter.activeBg
    }

    private var linkBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText(size: 16)
            Spacer(minLength: 2)
            domainRow
        }
    }

    // MARK: - Showcase 카드 (스크린샷 + 로컬 이미지) — 인스타 탐색탭 식 오버레이

    /// 2:3 풀블리드 이미지 위에 하단 스크림 + 흰 제목. footer·배지·메타 없음.
    /// 스크림 강도는 썸네일 하단 휘도에 비례 — 흰 텍스트 스크린샷(모찌의 다수)에서 진하게,
    /// 어두운 사진에서 옅게. center 크롭: 캡처의 어느 부분이 중요한지 모르므로 위쪽을 가정하지 않는다.
    private var showcaseBody: some View {
        ZStack(alignment: .bottomLeading) {
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.relativePath,
                targetSize: CGSize(width: 184, height: 276),
                alignment: .center,
                onBottomLuminance: { bottomLuminance = $0 }
            ) {
                LinearGradient(
                    colors: [HomeDesign.Color.sky100, HomeDesign.Color.purple100],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frames.media = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            frames.media = newFrame
                        }
                }
            )

            scrim

            titleText(size: 14.5, color: .white)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                .padding(HomeDesign.Spacing.md)
        }
    }

    /// 하단 휘도 적응형 스크림 — 이미지 위쪽 절반은 건드리지 않고 하단으로 갈수록 어두워진다.
    /// 최대 불투명도 0.45(어두운 이미지)~0.8(흰 이미지) — 흰 제목 대비 확보가 기준.
    private var scrim: some View {
        let maxOpacity = 0.45 + min(max(bottomLuminance, 0), 1) * 0.35
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0.5),
                .init(color: .black.opacity(maxOpacity * 0.5), location: 0.78),
                .init(color: .black.opacity(maxOpacity), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// 이미지 없는 스크린샷 (서버 복구 전 등) — 텍스트 폴백.
    private var screenshotTextBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleText(size: 16)
                .padding(.bottom, 6)
            if let summary = item.analysis?.summary, !summary.isEmpty,
               Self.stripSourceMeta(summary) != cardTitle {
                Text(Self.highlight(Self.stripSourceMeta(summary), ranges: summaryHighlights))
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .tracking(-0.2)
                    .lineSpacing(1)
                    .foregroundStyle(SearchD5.Palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    private var memoBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText(size: 16)
            Text(Self.highlight(bodyPreview, ranges: summaryHighlights))
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .lineSpacing(1)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(3)
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
        }
    }

    // MARK: - Reusable

    /// 제목 — 이미지 overlay(흰색)와 파스텔 타일(잉크색) 양쪽에서 쓴다.
    private func titleText(size: CGFloat, color: Color? = nil) -> some View {
        Text(Self.highlight(cardTitle, ranges: titleHighlights))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .tracking(-0.3)
            .foregroundStyle(color ?? (isAnalyzing ? SearchD5.Palette.textSecondary : SearchD5.Palette.textPrimary))
            .lineSpacing(0.5)
            .lineLimit(3)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 링크 타일 하단 — 멘션 필: 실제 파비콘 + 도메인을 흰 캡슐에. 어떤 링크였는지 떠올리게 하는 회수 단서.
    private var domainRow: some View {
        HStack(spacing: 5) {
            FaviconTile(host: item.source.url?.host, size: 16)
            Text(item.source.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "링크")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.6)))
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

// MARK: - Long-press preview (contextMenu 확대 미리보기)

/// long-press 시 카드 위에 뜨는 미리보기 — 그리드 카드가 잘라낸 내용(전체 본문·큰 이미지)을 보여준다.
private struct SearchCardPreview: View {
    let item: MochiItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = item.source.imageRefs.first?.relativePath {
                LocalThumbnail(
                    relativePath: path,
                    targetSize: CGSize(width: 320, height: 240),
                    alignment: .top
                ) {
                    Color.clear
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous))
            }

            Text(item.displayTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .multilineTextAlignment(.leading)

            if let body = item.analysis?.summary ?? item.source.text, !body.isEmpty {
                Text(body)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .lineSpacing(2)
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(HomeDesign.Color.surface)
    }
}
