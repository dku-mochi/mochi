import SwiftUI
import UIKit
import WebKit

/// 호스팅된 법무 문서(이용약관·개인정보처리방침)를 앱 안에서 보여주는 WKWebView 래퍼.
///
/// 외부 Safari 로 튕기지 않고 시트 안에서 표시한다 — 호스팅된 단일 페이지가 진실의
/// 원천이라 페이지만 갱신하면 앱 재배포 없이 반영된다. 설정·로그인 양쪽에서 공유한다.
public struct LegalWebView: UIViewRepresentable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 법무 문서 호스팅 URL 단일 원천(공개 repo `dku-mochi/legal` GitHub Pages).
/// 설정·로그인 양쪽이 이걸 참조한다 — 도메인 이전(`mochi.app` CNAME) 시 여기만 고친다.
public enum LegalLinks {
    public static let terms = URL(string: "https://dku-mochi.github.io/legal/terms.html")!
    public static let privacy = URL(string: "https://dku-mochi.github.io/legal/privacy.html")!
}

/// 인앱으로 띄울 법무 문서(제목 + URL). ``View/sheet(item:onDismiss:content:)`` 용 Identifiable.
public struct LegalPage: Identifiable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}
