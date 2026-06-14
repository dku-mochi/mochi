import SwiftUI
import CoreDomain
import DesignSystem

// MARK: - Brand / role 매핑

/// `ReferenceLink.provider`·`role` 을 모찌 팔레트 안의 브랜드 액센트로 환원한다.
///
/// 실제 기업 hex 를 쓰지 않고 파스텔 팔레트의 400-레벨로 매핑해 화면 톤을 깨지 않으면서도
/// "올리브영=민트 / 쿠팡=블러시 / 네이버=민트 / 캐치테이블=피치"처럼 목적지를 색으로 먼저 떠올리게 한다.
/// soft tint 는 `accent.opacity` 파생 — provider 가 늘어도 팔레트 짝을 새로 정의할 필요가 없다.
struct ReferenceBrandStyle {
    let accent: Color
    let name: String
    let roleIcon: String

    /// 타일·CTA 배경에 까는 옅은 브랜드 틴트.
    var soft: Color { accent.opacity(0.12) }

    init(provider: String, role: String) {
        (accent, name) = Self.brand(for: provider)
        roleIcon = Self.icon(for: role)
    }

    private static func brand(for provider: String) -> (Color, String) {
        switch provider {
        case "oliveyoung":                                  return (HomeDesign.Color.mint400, "올리브영")
        case "naver_map":                                   return (HomeDesign.Color.mint400, "네이버 지도")
        case "naver_shopping":                              return (HomeDesign.Color.mint400, "네이버쇼핑")
        case "smartstore":                                  return (HomeDesign.Color.mint400, "스마트스토어")
        case "coupang":                                     return (HomeDesign.Color.blush400, "쿠팡")
        case "catchtable":                                  return (HomeDesign.Color.peach400, "캐치테이블")
        case "zigzag":                                      return (HomeDesign.Color.blush400, "지그재그")
        case "musinsa":                                     return (HomeDesign.Color.ink700, "무신사")
        case "29cm":                                        return (HomeDesign.Color.ink700, "29CM")
        case "wconcept":                                    return (HomeDesign.Color.ink700, "W컨셉")
        case "openmarket":                                  return (HomeDesign.Color.butter400, "오픈마켓")
        case "info":                                        return (HomeDesign.Color.sky400, "블로그·아티클")
        case "social":                                      return (HomeDesign.Color.peach400, "SNS")
        case "official":                                    return (HomeDesign.Color.purple500, "공식 사이트")
        case "visible_url":                                 return (HomeDesign.Color.purple600, "화면 속 링크")
        case "original_url":                                return (HomeDesign.Color.purple600, "원본 링크")
        default:                                            return (HomeDesign.Color.purple500, "관련 링크")
        }
    }

    private static func icon(for role: String) -> String {
        switch role {
        case "reserve": return "calendar.badge.clock"
        case "book":    return "ticket.fill"
        case "buy":     return "bag.fill"
        case "read":    return "book.fill"
        default:        return "link"
        }
    }
}

extension ReferenceLink {
    /// usefulness 5 = 기록이 가리킨 바로 그 자료가 상위 — "딱 맞아요" 강조 대상.
    var isExactMatch: Bool { (usefulness ?? 0) >= 5 }
    /// usefulness 4 = 관련도 높음.
    var isStrongMatch: Bool { (usefulness ?? 0) >= 4 }
}

// MARK: - "딱 맞아요" 뱃지

private struct MatchBadge: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
            Text("딱 맞아요")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.14)))
    }
}

// MARK: - 브랜드 타일 (favicon + 브랜드 링)

private struct ReferenceBrandTile: View {
    let host: String?
    let style: ReferenceBrandStyle
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(style.soft)
            FaviconTile(host: host, size: size * 0.56)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(style.accent.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - 관련 링크 카드 · 메타 행카드 (favicon + 부제·가격 한 줄)

/// 행카드에 검색 메타를 한 줄 보탠다 — 제목 아래 "업종·지역 / 요약문 / 브랜드" 부제와
/// 쇼핑 가격을 인라인으로. 누르기 전에 "어디·무슨 글·얼마"를 한눈에 읽게 하는 게 목적.
/// 메타가 없는 링크(원본·화면 속)는 호스트로 폴백해 빈 줄을 만들지 않는다.
struct ReferenceMetaRowCard: View {
    let link: ReferenceLink
    let action: () -> Void

    private var style: ReferenceBrandStyle {
        ReferenceBrandStyle(provider: link.provider, role: link.role)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ReferenceBrandTile(host: link.url.host, style: style, size: 50)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(style.name)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(style.accent)
                        if link.isExactMatch { MatchBadge(accent: style.accent) }
                        Spacer(minLength: 0)
                    }
                    Text(link.title.isEmpty ? link.label : link.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metaLine
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(HomeDesign.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// 부제 + 가격 한 줄. subtitle 없으면 호스트 폴백(흐리게), 가격은 있을 때만 accent 강조.
    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(link.subtitle ?? (link.url.host ?? ""))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(link.subtitle != nil
                                 ? HomeDesign.Color.textMuted : HomeDesign.Color.textFaint)
                .lineLimit(1)
            if let price = link.priceText {
                Text(price)
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(style.accent)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 관련 링크 섹션 (ResourceFinder 산출물)

/// Agent ResourceFinder 가 찾은 관련 링크를 메타 행카드로 보여준다.
/// ② "지금 할 수 있어요"·캘린더 탭과 같은 섹션 문법(라벨 + 흰 카드 행)을 공유한다.
struct ReferenceLinksSection: View {
    let links: [ReferenceLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.purple500)
                    Text("관련 링크")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HomeDesign.Spacing.xs)

                VStack(spacing: HomeDesign.Spacing.sm) {
                    ForEach(links) { link in
                        ReferenceMetaRowCard(link: link) { openURL(link.url) }
                    }
                }
            }
        }
    }
}

#Preview {
    let links = [
        ReferenceLink(
            url: URL(string: "https://www.oliveyoung.co.kr/store/goods/getGoodsDetail.do")!,
            title: "토리든 다이브인 저분자 히알루론산 세럼 50ml",
            label: "올리브영에서 보기", role: "buy", provider: "oliveyoung",
            rankProfile: "cosmetics", source: nil, usefulness: 5,
            subtitle: "토리든", priceText: "18,900원"
        ),
        ReferenceLink(
            url: URL(string: "https://www.coupang.com/np/search?q=토리든+세럼")!,
            title: "토리든 다이브인 세럼", label: "쿠팡에서 보기", role: "buy",
            provider: "coupang", rankProfile: "cosmetics", source: nil, usefulness: 3,
            subtitle: "토리든", priceText: "16,500원"
        ),
        ReferenceLink(
            url: URL(string: "https://blog.naver.com/review/torriden")!,
            title: "토리든 세럼 성분·발림성 솔직 리뷰", label: "관련 글 보기",
            role: "read", provider: "info", rankProfile: "general", source: nil, usefulness: 4,
            subtitle: "성분·발림성·3주 사용 후기 — 끈적임 없이 흡수 빠르고 속건조까지 잡아줌"
        ),
    ]
    return ScrollView {
        ReferenceLinksSection(links: links)
            .padding(HomeDesign.Spacing.lg)
    }
    .background(HomeDesign.Color.bg)
}
