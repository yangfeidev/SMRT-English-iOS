//
//  WebViewRepresentable.swift
//  SMRT English
//
//  WKWebView 的 SwiftUI 包装（用于 iframe 内嵌视频兜底、班级课程页等场景）
//  - syncCookies: true 时把 URLSession 侧（HTTPCookieStorage）的站点 cookie
//    同步进 WKHTTPCookieStore 再加载，使 WKWebView 携带登录会话
//    （两套 cookie 存储互不相通，不同步会以游客态打开页面）
//

import SwiftUI
import WebKit

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    /// 是否同步登录 cookie（需要登录态的页面传 true）
    var syncCookies: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        webView.isOpaque = false

        if syncCookies {
            syncLoginCookies(into: webView) {
                webView.load(URLRequest(url: url))
            }
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 首次加载在 makeUIView 内完成（cookie 同步后）；此处仅在无同步需求时兜底
        guard !syncCookies, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    /// 把 HTTPCookieStorage 里站点的 cookie 写入 WKHTTPCookieStore，
    /// 全部写完后再回调加载（setCookie 为异步操作）
    private func syncLoginCookies(into webView: WKWebView, completion: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}
