import SwiftUI
import Kingfisher

/// 도메인 파비콘 미니 타일 — 링크가 "어느 사이트였는지"를 글자보다 빨리 떠올리게 하는 회수 단서.
///
/// `https://<host>/favicon.ico` 를 직접 로드한다 — Google 류 파비콘 프록시가 히트율은
/// 높지만 저장된 링크의 도메인 전체를 제3자에 노출하므로 쓰지 않는다.
/// 로드 전·실패 시엔 도메인 첫 글자 타일 폴백, 성공분은 Kingfisher 디스크 캐시로 재방문 즉시.
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

    private var faviconURL: URL? {
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
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
