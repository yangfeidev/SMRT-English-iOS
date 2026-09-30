//
//  WebViewRepresentable.swift
//  SMRT English
//
//  WKWebView 的 SwiftUI 包装
//  - syncCookies: true 时把 URLSession 侧（HTTPCookieStorage）的站点 cookie
//    同步进 WKHTTPCookieStore 再加载，使 WKWebView 携带登录会话
//    （两套 cookie 存储互不相通，不同步会以游客态打开页面）。
//    登录 cookie 只需同步一次，后续页面跳转/URL 变化由 WKWebView 自带会话自理。
//  - url 变化时自动重新加载（如课时切换），同 URL 不重载
//  - pageBackgroundColor: 页面底色（黑色适合视频 iframe；普通内容页传白色，
//    避免加载瞬间/过度滚动露出黑底）
//  - hideSiteHeader: 隐藏官网站点头部（<header>：logo 长条 + 汉堡菜单 + 抽屉），
//    避免与 App 导航形成双头部；配套隐藏 header 的内容补偿 + 课时页栅格修复
//  - extraCSS: 追加注入的 CSS（跟在 hideHeader 样式后，同一次注入生效）
//  - isolatedStorage: 使用独立非持久 WKWebsiteDataStore（Cafe 游客态专用：
//    防止 lesson 页同步进默认存储的登录 cookie 泄入，且不留任何站点数据）
//

import SwiftUI
import WebKit

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    /// 是否同步登录 cookie（需要登录态的页面传 true）
    var syncCookies: Bool = false
    /// WebView 底色
    var pageBackgroundColor: UIColor = .black
    /// 隐藏官网站点头部
    var hideSiteHeader: Bool = false
    /// 追加注入的 CSS
    var extraCSS: String = ""
    /// 页面加载完成后执行的 JS（documentEnd 注入主框架，仅首次导航触发；
    /// 用于自动触发页面交互，如弹出官网视频播放器）
    var pageLoadJS: String? = nil
    /// 独立非持久存储（游客态/隐私隔离用）
    var isolatedStorage: Bool = false

    /// 隐藏站点头部 + 课时页布局修复的基础 CSS（详见各规则注释）
    ///
    /// 1) header 整个 display:none（含 logo/汉堡/抽屉菜单）；配套
    ///    #content{margin-top:0}：官网给 #content 留了 60px margin-top 补偿
    ///    固定 header（实测 lesson 页 header 60px + margin 60px = 顶部 120px 空白）。
    ///
    /// 2) 课时内容栅格：官网 @media (max-width:480px) 把 #lesson-content.v2 的
    ///    .col1~.col12 全改 width:100%（手机上单词卡等一列一个占满屏）。
    ///    按桌面端数值用 !important 声明回去，手机上与桌面网页同排布。
    ///
    /// 3) 手机端（≤480px）专属微调（均经 iframe 390px 实测）：
    ///    - 单词卡 col3 一排 2 个（22.75% 一排 4 个太挤；47%+3% 边距=50% 恰好两个）
    ///    - 点图活动（col3>figure.view 题图 + col3+.col9 选项区）大小失衡修复
    ///    - 画板 col6:has(>.draw) 撑满整行（官网两侧是空占位列）
    ///
    /// 4) 多图行 figure.image25/30/35：官网 @media(max-width:768px) 强制全宽，
    ///    恢复桌面宽度（html 前缀抬高特异性压过官网同属性 !important）。
    private static let baseHideCSS = [
        "header{display:none !important;}",
        "#content{margin-top:0 !important;}",
        "#content #lesson-content.v2 .col1{width:5.5833333% !important;}",
        "#content #lesson-content.v2 .col2{width:14.1666666% !important;}",
        "#content #lesson-content.v2 .col2-4{width:17.6% !important;}",
        "#content #lesson-content.v2 .col3{width:22.75% !important;}",
        "#content #lesson-content.v2 .col4{width:31.333333% !important;}",
        "#content #lesson-content.v2 .col5{width:39.916666% !important;}",
        "#content #lesson-content.v2 .col6{width:48.5% !important;}",
        "#content #lesson-content.v2 .col7{width:57.083333% !important;}",
        "#content #lesson-content.v2 .col8{width:65.666666% !important;}",
        "#content #lesson-content.v2 .col9{width:74.25% !important;}",
        "#content #lesson-content.v2 .col10{width:82.833333% !important;}",
        "#content #lesson-content.v2 .col11{width:91.416666% !important;}",
        "#content #lesson-content.v2 .col12{width:100% !important;}",
        "html #content #lesson-content.v2 figure.image25{width:25% !important;}",
        "html #content #lesson-content.v2 figure.image30{width:30% !important;}",
        "html #content #lesson-content.v2 figure.image35{width:35% !important;}",
        "@media only screen and (max-width:480px){#content #lesson-content.v2 .col3{width:47% !important;}}",
        "@media only screen and (max-width:480px){"
            + "#content #lesson-content.v2 .col3 > figure.view{width:63% !important;margin:0 auto !important;}"
            + "#content #lesson-content.v2 .col3 + .col9{width:50% !important;}"
            + "#content #lesson-content.v2 .col3 + .col9 .click.col2{width:46% !important;}"
            + "#content #lesson-content.v2 .col6:has(> .draw){width:100% !important;}"
            + "}",
    ].joined()

    /// documentStart 注入脚本：head 一就绪就挂上 style，首屏渲染前生效、无闪烁
    private static func hideHeaderScript(extraCSS: String) -> String {
        // CSS 里不含单引号，可直接拼进 JS 字符串
        let css = baseHideCSS + extraCSS
        return """
        (function() {
          var style = document.createElement('style');
          style.textContent = '\(css)';
          (function append() {
            if (document.head) { document.head.appendChild(style); }
            else { setTimeout(append, 0); }
          })();
        })();
        """
    }

    final class Coordinator {
        /// 当前已加载/正在加载的 URL（用于判断 SwiftUI 重绘是否伴随 URL 变化）
        var currentURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if isolatedStorage {
            // 独立非持久存储：与默认存储（lesson 页登录 cookie）完全隔离
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        if hideSiteHeader {
            config.userContentController.addUserScript(
                WKUserScript(source: Self.hideHeaderScript(extraCSS: extraCSS),
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true))
        }
        if let pageLoadJS {
            config.userContentController.addUserScript(
                WKUserScript(source: pageLoadJS,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = pageBackgroundColor
        webView.isOpaque = false

        context.coordinator.currentURL = url
        if syncCookies {
            syncLoginCookies(into: webView) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 同一 URL 不重载（SwiftUI 重绘频繁）；URL 变化（如课时切换）→ 重新加载
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
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
