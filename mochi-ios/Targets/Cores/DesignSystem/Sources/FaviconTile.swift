import SwiftUI
import Kingfisher

/// 도메인 파비콘 미니 타일 — 링크가 "어느 사이트였는지"를 글자보다 빨리 떠올리게 하는 회수 단서.
///
/// Google 파비콘 서비스(`s2/favicons`)로 가져온다 — `<link rel="icon">` 파싱·정규화·캐시를 구글이
/// 대신 해줘 `/favicon.ico` 직접 로드보다 적중률이 훨씬 높다(휑한 letterTile 폴백 최소화). 과거엔
/// "도메인을 제3자(구글)에 노출"을 우려해 직접 로드만 썼으나, favicon 요청은 도메인만 담기고 개인정보와
/// 매핑되지 않아 프라이버시 비용이 낮다고 판단(2026-06-15 결정). 네트워크 실패 시엔 도메인 첫 글자 타일
/// 폴백, 성공분은 Kingfisher 디스크 캐시로 재방문 즉시.
public struct FaviconTile: View {
    private let host: String?
    private let size: CGFloat

    public init(host: String?, size: CGFloat = 20) {
        self.host = host
        self.size = size
    }

    public var body: some View {
        Group {
            if let url = faviconURL {
                KFImage(url)
                    .placeholder { letterTile }
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
                    // 투명 배경 파비콘이 파스텔 타일 위에서 뭉개지지 않게 흰 바탕 깔기.
                    .background(Color.white)
            } else {
                letterTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }

    /// 구글 파비콘 서비스 URL — `sz=64` 로 작은 타일에도 또렷. 도메인만 전달(개인정보 무매핑).
    private var faviconURL: URL? {
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    private var letterTile: some View {
        ZStack {
            LinearGradient(
                colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(letter)
                .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var letter: String {
        let cleaned = (host ?? "").replacingOccurrences(of: "www.", with: "")
        guard let first = cleaned.first else { return "L" }
        return String(first).uppercased()
    }
}
