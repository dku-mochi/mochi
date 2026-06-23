import SwiftUI
import UIKit
import WebKit

/// 설정 §정보 의 법무 문서(개인정보처리방침)를 앱 안에서 보여주는 WKWebView 래퍼.
///
/// 외부 Safari 로 튕기지 않고 시트 안에서 표시한다 — 호스팅된 단일 페이지가 진실의
/// 원천이라 페이지만 갱신하면 앱 재배포 없이 반영된다.
struct LegalWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 설정 §정보 에서 인앱으로 띄울 법무 문서(제목 + URL). ``View/sheet(item:onDismiss:content:)`` 용 Identifiable.
struct LegalPage: Identifiable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

