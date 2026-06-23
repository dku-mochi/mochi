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

/// 호스팅 법무 페이지(`dku-mochi/legal` `style.css` 의 `--bg: #FAF8FF`)와 맞춘 시트·네비 배경.
/// `LegalWebView` 가 투명(`.clear`)이라 이 색이 페이지 배경과 이어져 이음매가 없다.
public enum LegalPalette {
    public static let background = Color(red: 250.0 / 255.0, green: 248.0 / 255.0, blue: 255.0 / 255.0)
}

public extension View {
    /// 이용약관·개인정보처리방침을 앱 톤 시트로 띄운다 — 설정·로그인이 공유해 스타일을 단일화한다.
    /// 배경 = 웹 페이지 색(#FAF8FF), tint = 브랜드 퍼플, 우상단 원형 X(``CircularGlyph``) 닫기.
    func legalSheet(item: Binding<LegalPage?>) -> some View {
        sheet(item: item) { page in
            LegalSheetContent(page: page) { item.wrappedValue = nil }
        }
    }
}

private struct LegalSheetContent: View {
    let page: LegalPage
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LegalPalette.background.ignoresSafeArea()
                LegalWebView(url: page.url)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        CircularGlyph("xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbarBackground(LegalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(HomeDesign.Color.purple500)
    }
}
