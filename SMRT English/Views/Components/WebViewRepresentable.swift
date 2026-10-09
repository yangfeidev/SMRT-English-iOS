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

/// WebView 内部浏览历史返回控制（ObservableObject 供页面返回按钮订阅）：
/// WebView 有内部跳转历史时返回按钮先 goBack 逐级返回，无历史才退出页面。
/// canGoBack 由 WebViewRepresentable 的导航代理在 didCommit/didFinish 更新；
/// WebView 销毁（dismantleUIView）时 reset，避免残留状态误触发 goBack。
final class WebViewNavigationState: ObservableObject {
    @Published var canGoBack = false
    fileprivate weak var webView: WKWebView?

    /// 返回按钮动作：有内部历史先 goBack（并同步按钮态），否则执行退出闭包
    func goBackOrDismiss(dismiss: () -> Void) {
        if let webView, webView.canGoBack {
            webView.goBack()
            canGoBack = webView.canGoBack
        } else {
            dismiss()
        }
    }

    func reset() {
        canGoBack = false
        webView = nil
    }
}

/// 宽表格页滚动轴锁：拖动开始时判定主导轴（水平/垂直），本次拖动只允许
/// 该轴滚动——避免斜向拖动时 x/y 同时滚产生"360 度转圈"的失控感。
/// WebKit 内部持有 webView.scrollView.delegate，直接替换会丢其内部逻辑
/// （键盘避让等），故用转发 delegate：只拦截拖动相关回调做轴锁，
/// 其余方法经 forwardingTarget 转发给原 delegate。
final class AxisLockScrollDelegate: NSObject, UIScrollViewDelegate {
    weak var originalDelegate: UIScrollViewDelegate?

    private enum Axis { case horizontal, vertical }
    private var dragStartOffset: CGPoint = .zero
    private var lockedAxis: Axis?
    private var lockedOffset: CGPoint = .zero

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDelegate
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartOffset = scrollView.contentOffset
        lockedAxis = nil
        originalDelegate?.scrollViewWillBeginDragging?(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking, lockedAxis == nil {
            let dx = scrollView.contentOffset.x - dragStartOffset.x
            let dy = scrollView.contentOffset.y - dragStartOffset.y
            // 拖动超过 6pt 后锁定主导轴（之后本次拖动不再变更）
            if abs(dx) > 6, abs(dx) >= abs(dy) {
                lockedAxis = .horizontal
                lockedOffset = dragStartOffset
            } else if abs(dy) > 6 {
                lockedAxis = .vertical
                lockedOffset = dragStartOffset
            }
        }
        switch lockedAxis {
        case .horizontal:
            // 水平主导：钉住纵向（含边界回弹，只沿 x 弹）
            scrollView.contentOffset.y = lockedOffset.y
        case .vertical:
            scrollView.contentOffset.x = lockedOffset.x
        case nil:
            break
        }
        originalDelegate?.scrollViewDidScroll?(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        lockedAxis = nil
        originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
    }
}

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
    /// 数据表格页宽视口（教师端宽表格页用）：documentStart 先按官网原生
    /// device-width 渲染，页面 load 后**仅在存在数据表格时**（.rightside table）
    /// 把视口收缩到 [下限, 上限] 区间内的内容真实宽——命中官网桌面媒体查询
    /// 断点，完整列/操作按钮原生显示（手机断点会把 Start/Due 列、文字按钮
    /// 藏进简化块），竖屏屏宽不够时 WebView 内左右滑动查看。
    /// 无表格的页面（如 Attendance 打卡模式的卡片流）保持官网手机版自适应
    /// 不切换——卡片是流式全宽元素，宽视口下会被拉超宽在窄屏上残缺。
    var fixedViewportWidth: CGFloat? = nil
    /// 视口收缩下限（配合 fixedViewportWidth）：官网断点安全线——Assignments
    /// 的 Start/Due 列 hidden-xs hidden-sm（需 ≥992）、Attendance 的 Ref 列
    /// hidden-xs（需 ≥768），低于下限会触发官网手机断点把列藏掉；
    /// nil = 固定视口不收缩
    var viewportShrinkLowerBound: CGFloat? = nil
    /// 宽视口的显示缩放（配合 fixedViewportWidth，默认 nil=1）：
    /// 1:1 渲染在手机上偏大，切宽视口时用 initial-scale/minimum-scale=该值
    /// 整体等比缩小（如 0.75 → 992 内容缩至 744pt 宽，可见列更多、字号适中）
    var viewportScale: CGFloat? = nil
    /// WebView 内部浏览历史返回控制：传入后页面返回按钮可先 goBack
    /// （WebView 内跳转后逐级返回上一页），无历史再退出页面
    var navigationState: WebViewNavigationState? = nil
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

    /// 班级子页通用隐藏 CSS（教师端 WebView 承载页 & 学生端补齐页共用）：
    /// - .leftside：页面内左侧栏（含手机形态的汉堡按钮 navbar-toggle、班级名、
    ///   #menu 折叠菜单——由官网 JS 注入 DOM，CSS 选择器对动态元素同样生效）；
    ///   隐藏后 .rightside 撑满整行，避免右侧空出 25% 列宽
    /// - footer：站点深色页脚（链接矩阵 + logo）
    /// - h1.page-title：页面大标题（App 顶部导航已有班级名，避免重复）
    static let classPageHideChromeCSS = [
        ".leftside{display:none !important;}",
        ".rightside{width:100% !important;}",
        "footer{display:none !important;}",
        "h1.page-title{display:none !important;}",
    ].joined()

    /// Assessments 页右上角 Add Assessment / Help 圆形图标按钮
    /// （教师端操作入口，App 内不用 → 去掉图标只留内容）
    static let classPageHideCircleButtonsCSS =
        ".rightside div[class*='col-'] > a.btn-circle{display:none !important;}"

    /// 教师端 Attendance 记录表列宽修正：
    /// 官网 th 自带 width 属性（Date/Full Name/Ref/Status 四列各 20%/40%/20%/20%），
    /// Ref 列手机端常为空仍占 ~205px——解除 width 属性按内容分配，
    /// Ref 列（td 内 .ellipsis.s75）单独限宽 90px
    static let teacherAttendanceColumnsCSS = [
        ".rightside table th[width],.rightside table td[width]{width:auto !important;}",
        ".rightside table td:has(> div.ellipsis.s75){width:90px !important;}",
    ].joined()

    /// 教师端宽表格收缩：官网 table width:100% 拉满固定视口（1024），
    /// 内容窄的列（如 Attendance 的 Date "Oct 8th 2026"）被均分拉出大片列间
    /// 空白——收缩为按内容自适应宽度，配合 viewportShrinkLowerBound 收缩
    /// 视口，消除空旷区域与超长横向滚动
    static let teacherTableShrinkCSS =
        ".rightside table{width:auto !important;min-width:0 !important;}"

    /// 官网姓名西式「名 姓」→ 中式「姓名」（仅两段纯汉字时交换，
    /// 与 Swift 侧 normalizeChineseName 规则一致）。
    /// 覆盖两类服务端静态输出：打卡卡片 p.miniprofile-title、
    /// 记录表 a[href*="view=student"] strong span
    static let chineseNameNormalizeJS = """
    (function() {
      function cnName(s) {
        var parts = s.replace(/\\s+/g, ' ').trim().split(' ');
        if (parts.length === 2 &&
            /^[\\u4e00-\\u9fa5]{1,4}$/.test(parts[0]) &&
            /^[\\u4e00-\\u9fa5]{1,4}$/.test(parts[1])) {
          return parts[1] + parts[0];
        }
        return null;
      }
      function fix(el) {
        var name = cnName(el.textContent);
        if (name) { el.textContent = name; }
      }
      function run() {
        document.querySelectorAll('p.miniprofile-title').forEach(fix);
        document.querySelectorAll('a[href*="view=student"] strong span').forEach(fix);
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run);
      } else { run(); }
      window.addEventListener('load', run);
    })();
    """

    /// documentStart 注入脚本：head 一就绪就挂上 style，首屏渲染前生效、无闪烁。
    /// CSS 经 JSON 编码为合法 JS 字符串字面量——内容含单引号/双引号/换行均安全
    /// （踩坑：extraCSS 的 [class*='col-'] 单引号会截断单引号 JS 字符串，
    /// 整段注入脚本 SyntaxError，header 隐藏与 extraCSS 一起失效）
    private static func hideHeaderScript(extraCSS: String) -> String {
        let css = baseHideCSS + extraCSS
        let literal: String
        if let data = try? JSONEncoder().encode(css),
           let s = String(data: data, encoding: .utf8) {
            literal = s
        } else {
            literal = "\"\""
        }
        return """
        (function() {
          var style = document.createElement('style');
          style.textContent = \(literal);
          (function append() {
            if (document.head) { document.head.appendChild(style); }
            else { setTimeout(append, 0); }
          })();
        })();
        """
    }

    /// documentStart 注入脚本：先按官网原生 device-width 渲染；load 后若
    /// 页面含数据表格（.rightside table）→ 量内容真实宽把视口切到
    /// [下限, 上限]（可选 viewportScale 等比缩放），无表格（打卡卡片流/
    /// 空态）→ 保持手机版自适应不切换。
    /// （官网 JS 可能后写 viewport，故 DOMContentLoaded/load 后再设）
    private static func viewportScript(width: CGFloat,
                                       shrinkToLowerBound: CGFloat?,
                                       displayScale: CGFloat?) -> String {
        let shrinkBlock: String
        if let shrinkToLowerBound {
            let scale = displayScale ?? 1
            shrinkBlock = """
              // 有数据表格才切宽视口：#content 临时 max-content 量宽后还原
              function adjust() {
                var c = document.querySelector('#content');
                var table = document.querySelector('.rightside table');
                if (!c || !table) { return; }
                c.style.width = 'max-content';
                var w = Math.ceil(c.getBoundingClientRect().width);
                c.style.width = '';
                if (w > 320) {
                  // minimum-scale 阻止 WebKit 的 fit-to-width 自动缩小：
                  // 动态切宽视口时 WebKit 会把整页缩小塞进屏幕，
                  // initial-scale/minimum-scale=指定值 强制等比渲染 + 左右滚动
                  var spec = 'width=' + Math.max(\(Int(shrinkToLowerBound)), Math.min(w, \(Int(width)))) +
                             ', initial-scale=\(scale), minimum-scale=\(scale)';
                  setViewport(spec);
                }
                window.scrollTo(0, 0);
              }
              window.addEventListener('load', adjust);
              setTimeout(adjust, 900);
            """
        } else {
            shrinkBlock = ""
        }
        return """
        (function() {
          function setViewport(spec) {
            var metas = document.querySelectorAll('meta[name="viewport"]');
            for (var i = 0; i < metas.length; i++) { metas[i].remove(); }
            var m = document.createElement('meta');
            m.name = 'viewport';
            m.content = spec;
            (document.head || document.documentElement).appendChild(m);
          }
          setViewport('width=device-width, initial-scale=1');
          document.addEventListener('DOMContentLoaded', function() {
            setViewport('width=device-width, initial-scale=1');
          });
          \(shrinkBlock)
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// 当前已加载/正在加载的 URL（用于判断 SwiftUI 重绘是否伴随 URL 变化）
        var currentURL: URL?
        /// WKUIDelegate 需弱引用持有者，由 Coordinator 持有保证生命周期
        let dialogDelegate = DialogDelegate()
        /// 内部浏览历史返回控制（页面返回按钮先 goBack 用）
        weak var navState: WebViewNavigationState?
        /// 滚动轴锁 delegate（必须保活——scrollView.delegate 是弱引用）
        var axisLockDelegate: AxisLockScrollDelegate?

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // didCommit 时 back/forward list 已更新，canGoBack 即当前准确值
            navState?.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navState?.canGoBack = webView.canGoBack
        }
    }

    /// WKUIDelegate：把网页 JS 的 alert / confirm / prompt 桥接为原生弹窗。
    /// 不实现时 WebKit 静默吞掉（confirm 返回 false），官网依赖 confirm 的
    /// 提交按钮（练习「Complete」等）会点不出来。
    final class DialogDelegate: NSObject, WKUIDelegate {

        /// 从 WebView 沿 responder 链找宿主 VC（弹窗 present 用）
        private func hostVC(for webView: WKWebView) -> UIViewController? {
            var responder: UIResponder? = webView
            while let r = responder {
                if let vc = r as? UIViewController { return vc }
                responder = r.next
            }
            return webView.window?.rootViewController
                ?? UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                    .first
        }

        private func present(message: String, webView: WKWebView,
                             addTextField: ((UITextField) -> Void)? = nil,
                             confirmTitle: String = "确定",
                             completion: @escaping (String?) -> Void) {
            guard let vc = hostVC(for: webView) else {
                completion(addTextField == nil ? "" : nil)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let addTextField {
                alert.addTextField { addTextField($0) }
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completion(nil)
            })
            alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { _ in
                completion(addTextField == nil ? "" : alert.textFields?.first?.text ?? "")
            })
            vc.present(alert, animated: true)
        }

        /// window.alert(...)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            present(message: message, webView: webView) { _ in completionHandler() }
        }

        /// window.confirm(...) —— 取消→false，确定→true（官网练习 Complete 依赖此返回值）
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            present(message: message, webView: webView) { result in
                completionHandler(result != nil)
            }
        }

        /// window.prompt(...)
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            present(message: prompt, webView: webView, addTextField: { $0.text = defaultText }) {
                completionHandler($0)
            }
        }
    }

    /// 全局共享的 WebKit 进程池：所有 WebView 实例共用同一个 WebContent 进程，
    /// 避免每次新建 WebView 都冷启动进程（首个课时详情 push 卡顿的根因之一）
    static let sharedProcessPool = WKProcessPool()

    /// 预热用的临时 WebView（warmUp 创建，加载完成后置 nil 释放）
    private static var warmUpWebView: WKWebView?

    /// App 启动后调用：后台创建一个加载 about:blank 的 WebView，
    /// 提前拉起 WebKit 渲染进程，把首次冷启动成本挪出用户点击路径
    static func warmUp() {
        guard warmUpWebView == nil else { return }
        let config = WKWebViewConfiguration()
        config.processPool = sharedProcessPool
        let webView = WKWebView(frame: .zero, configuration: config)
        warmUpWebView = webView
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        // 2s 后释放（进程已拉起，WebView 本身不再需要）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            warmUpWebView = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 共享进程池（isolatedStorage 的 Cafe 页除外——独立存储配套独立进程更干净）
        if !isolatedStorage {
            config.processPool = Self.sharedProcessPool
        }
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
        if let fixedViewportWidth {
            config.userContentController.addUserScript(
                WKUserScript(source: Self.viewportScript(width: fixedViewportWidth,
                                                         shrinkToLowerBound: viewportShrinkLowerBound,
                                                         displayScale: viewportScale),
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
        if fixedViewportWidth != nil {
            // 固定视口下禁 WebKit 缩放适配：内容 1:1 渲染，靠 scrollView 左右滚动
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = 1
            // 滚动轴锁：宽内容页禁止斜向拖动 x/y 同滚（"360 度转圈"），
            // 每次拖动只允许主导轴（横向或纵向）
            let axisLock = AxisLockScrollDelegate()
            axisLock.originalDelegate = webView.scrollView.delegate
            webView.scrollView.delegate = axisLock
            context.coordinator.axisLockDelegate = axisLock
        }
        // JS 对话框桥接：官网练习「Complete」提交走 confirm()，未实现 uiDelegate 时
        // WebKit 静默返回 false → 提交永远不执行（真机踩坑）
        webView.uiDelegate = context.coordinator.dialogDelegate
        // 导航代理：跟踪 canGoBack 供页面返回按钮先 goBack 再退出
        webView.navigationDelegate = context.coordinator
        context.coordinator.navState = navigationState
        navigationState?.webView = webView

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

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // WebView 销毁（push 出去/tab 切走）时清掉返回状态，
        // 避免外层返回按钮拿到残留的 canGoBack 误 goBack
        coordinator.navState?.reset()
        coordinator.navState = nil
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

/// WebView 承载页通用骨架（push 进来的独立页面用）：
/// 返回按钮 = WebView 有内部浏览历史先 goBack 逐级返回，无历史才退出页面
/// （系统返回按钮无法拦截 NavigationStack pop，故统一改自定义返回钮）。
/// 用法：WebViewScreen(title:) { state in WebViewRepresentable(..., navigationState: state, ...) }
struct WebViewScreen: View {
    let title: String
    @ViewBuilder let webView: (WebViewNavigationState) -> WebViewRepresentable

    @StateObject private var navState = WebViewNavigationState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        webView(navState)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        navState.goBackOrDismiss { dismiss() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityIdentifier("web.back")
                }
            }
    }
}
