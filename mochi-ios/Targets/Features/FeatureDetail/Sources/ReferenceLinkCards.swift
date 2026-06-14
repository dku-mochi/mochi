import SwiftUI
import CoreDomain
import DesignSystem

// MARK: - Brand / role 매핑 (세 변형이 공유)

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

// MARK: - "딱 맞아요" 뱃지 (세 변형 공유)

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

// MARK: - 브랜드 타일 (favicon + 브랜드 링, 변형 A·C 공유)

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

// MARK: - 변형 A · 브랜드 풀카드

/// provider 브랜드 액센트를 가장 강하게 살린 전폭 카드. 좌측 브랜드 바 + 제목 + CTA 캡슐.
/// 상위 랭크(첫 카드)는 살짝 더 또렷한 테두리, usefulness 5 는 "딱 맞아요" 뱃지.
struct ReferenceBrandCard: View {
    let link: ReferenceLink
    let isPrimary: Bool
    let action: () -> Void

    private var style: ReferenceBrandStyle {
        ReferenceBrandStyle(provider: link.provider, role: link.role)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                // 좌측 브랜드 액센트 바 — 행이 어느 브랜드로 가는지의 색 단서.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(style.accent)
                    .frame(width: 3.5)
                    .frame(maxHeight: .infinity)

                ReferenceBrandTile(host: link.url.host, style: style, size: 52)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(style.name)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(style.accent)
                        if link.isExactMatch { MatchBadge(accent: style.accent) }
                        Spacer(minLength: 0)
                    }
                    Text(link.title.isEmpty ? link.label : link.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // CTA 캡슐 — label 은 서버가 provider 별로 완성("올리브영에서 보기").
                    HStack(spacing: 4) {
                        Image(systemName: style.roleIcon)
                            .font(.system(size: 10, weight: .bold))
                        Text(link.label)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(style.soft))
                }
            }
            .padding(.vertical, HomeDesign.Spacing.md)
            .padding(.horizontal, HomeDesign.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .stroke(isPrimary ? style.accent.opacity(0.45) : HomeDesign.Color.border,
                            lineWidth: isPrimary ? 1.5 : 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(isPrimary ? 0.08 : 0.05),
                    radius: isPrimary ? 14 : 8, x: 0, y: isPrimary ? 6 : 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 변형 B · 통일 행카드

/// 기존 ② 섹션 행 문법(leading 타일 + 제목·부제 + 흰 카드)을 그대로 잇는 컴팩트 행.
/// provider 색은 타일·부제 틴트로만 — 할 일·일정·쇼핑 행과 한 종으로 읽힌다.
struct ReferenceRowCard: View {
    let link: ReferenceLink
    let action: () -> Void

    private var style: ReferenceBrandStyle {
        ReferenceBrandStyle(provider: link.provider, role: link.role)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ReferenceBrandTile(host: link.url.host, style: style, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(link.label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                            .lineLimit(1)
                        if link.isExactMatch { MatchBadge(accent: style.accent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(link.title.isEmpty ? (link.url.host ?? "") : link.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.accent)
                        .lineLimit(1)
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
}

// MARK: - 변형 C · 가로 캐러셀 타일

/// 세로 브랜드 타일을 가로 스크롤로 — provider 썸네일 중심의 비주얼 우선 표현.
struct ReferenceCarouselTile: View {
    let link: ReferenceLink
    let action: () -> Void

    private var style: ReferenceBrandStyle {
        ReferenceBrandStyle(provider: link.provider, role: link.role)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                HStack {
                    ReferenceBrandTile(host: link.url.host, style: style, size: 44)
                    Spacer(minLength: 0)
                    if link.isExactMatch {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(style.accent)
                    }
                }
                Text(style.name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(style.accent)
                Text(link.title.isEmpty ? link.label : link.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: style.roleIcon)
                        .font(.system(size: 10, weight: .bold))
                    Text("열기")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(style.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(style.soft))
            }
            .padding(HomeDesign.Spacing.md)
            .frame(width: 158, height: 170, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 8, x: 0, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 변형 D · 메타 행카드 (favicon + 부제·가격 한 줄)

/// 행카드(B)에 검색 메타를 한 줄 보탠다 — 제목 아래 "업종·지역 / 요약문 / 브랜드" 부제와
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

// MARK: - 변형 E · 메타 매거진 카드 (요약문·가격을 살린 풀카드)

/// 풀카드(A)에 요약문(subtitle)을 2줄까지 본문처럼 싣고, 쇼핑 가격은 상단 우측 pill 로 강조한다.
/// 정보가 풍부한 링크(블로그 후기·상품)를 "미리 읽고" 누르게 하는 editorial 변형.
struct ReferenceMetaCard: View {
    let link: ReferenceLink
    let isPrimary: Bool
    let action: () -> Void

    private var style: ReferenceBrandStyle {
        ReferenceBrandStyle(provider: link.provider, role: link.role)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(style.accent)
                    .frame(width: 3.5)
                    .frame(maxHeight: .infinity)
                ReferenceBrandTile(host: link.url.host, style: style, size: 54)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(style.name)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(style.accent)
                        if link.isExactMatch { MatchBadge(accent: style.accent) }
                        Spacer(minLength: 0)
                        // 가격은 상단 우측 soft pill — 커머스 링크에서 "얼마"를 먼저 잡게 한다.
                        if let price = link.priceText {
                            Text(price)
                                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(style.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(style.soft))
                        }
                    }
                    Text(link.title.isEmpty ? link.label : link.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle = link.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: style.roleIcon)
                            .font(.system(size: 10, weight: .bold))
                        Text(link.label)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(style.soft))
                    .padding(.top, 1)
                }
            }
            .padding(HomeDesign.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .stroke(isPrimary ? style.accent.opacity(0.45) : HomeDesign.Color.border,
                            lineWidth: isPrimary ? 1.5 : 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(isPrimary ? 0.08 : 0.05),
                    radius: isPrimary ? 14 : 8, x: 0, y: isPrimary ? 6 : 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 비교용 컨테이너 (5종 동시 렌더 — 결정 후 나머지 제거)

/// 다섯 변형을 한 화면에 쌓아 실제 데이터로 비교한다. 작은 캡션으로 A~E 를 표시.
/// A·B·C 는 favicon 중심, D·E 는 검색 메타(부제·가격) 중심.
/// **임시** — 사용자가 하나를 고르면 나머지와 이 컨테이너를 걷어내고 승자만 ② 섹션에 합친다.
struct ReferenceLinksComparison: View {
    let links: [ReferenceLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.xl) {
                variant("A · 브랜드 풀카드") {
                    VStack(spacing: HomeDesign.Spacing.sm) {
                        ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                            ReferenceBrandCard(link: link, isPrimary: index == 0) {
                                openURL(link.url)
                            }
                        }
                    }
                }
                variant("B · 통일 행카드") {
                    VStack(spacing: HomeDesign.Spacing.sm) {
                        ForEach(links) { link in
                            ReferenceRowCard(link: link) { openURL(link.url) }
                        }
                    }
                }
                variant("C · 가로 캐러셀") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: HomeDesign.Spacing.sm) {
                            ForEach(links) { link in
                                ReferenceCarouselTile(link: link) { openURL(link.url) }
                            }
                        }
                        .padding(.horizontal, HomeDesign.Spacing.xs)
                    }
                    // 카드 그림자가 잘리지 않게 음수 패딩으로 가장자리 숨통.
                    .padding(.horizontal, -HomeDesign.Spacing.xs)
                }
                variant("D · 메타 행카드") {
                    VStack(spacing: HomeDesign.Spacing.sm) {
                        ForEach(links) { link in
                            ReferenceMetaRowCard(link: link) { openURL(link.url) }
                        }
                    }
                }
                variant("E · 메타 매거진") {
                    VStack(spacing: HomeDesign.Spacing.sm) {
                        ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                            ReferenceMetaCard(link: link, isPrimary: index == 0) {
                                openURL(link.url)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func variant(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                Text("관련 링크")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text(caption)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple500)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(HomeDesign.Color.purple50))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HomeDesign.Spacing.xs)
            content()
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
        ReferenceLinksComparison(links: links)
            .padding(HomeDesign.Spacing.lg)
    }
    .background(HomeDesign.Color.bg)
}
