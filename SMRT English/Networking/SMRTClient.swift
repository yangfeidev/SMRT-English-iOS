//
//  SMRTClient.swift
//  SMRT English
//
//  网络客户端：登录 / 会话保持 / 页面抓取
//  ============================================================
//  已实测验证的接口事实（2026-09-29）：
//  - 登录：POST https://smrtenglish.cn/process.php
//      表单字段: email / password / sublogin=1 / school_key=sunshine
//      成功返回 302 → /sunshine/cafe，并种下
//      PHPSESSID + cookname + cookid 三个 cookie
//  - 会话判断：登录后页面头部不再出现 "Create Account" 入口
//  - 内容页均为服务端渲染 HTML，媒体直连公开 CDN（hw-cdn.smrtenglish.cn）
//
//  Cookie 通过 HTTPCookieStorage.shared 持久化（App 重启自动恢复会话）。
//

import Foundation
import os

extension Error {
    /// 任务被取消：Task.cancel 抛 CancellationError，
    /// URLSession 请求被取消抛 URLError.cancelled（-999）。
    /// SwiftUI 的 refreshable/task 在手势中断、重复触发时会取消任务，
    /// 属正常生命周期，静默处理，不应作为错误展示给用户。
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

enum SMRTError: LocalizedError {
    case badResponse
    case loginFailed
    case notLoggedIn
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .badResponse:   return "网络响应异常"
        case .loginFailed:   return "邮箱或密码错误"
        case .notLoggedIn:   return "登录已过期，请重新登录"
        case .parseFailed:   return "页面解析失败，网站结构可能已变更"
        }
    }
}

final class SMRTClient {

    static let shared = SMRTClient()

    static let log = Logger(subsystem: "com.yangfei.smrtenglish", category: "SMRTClient")

    let baseURL = URL(string: "https://smrtenglish.cn")!
    let schoolKey = "sunshine"

    private let session: URLSession
    private let guestSession: URLSession
    /// 最近一次打开的课时页路径（练习 AJAX 的 Referer 用）
    private var lastLessonPath = ""

    /// PHPSESSID 是会话 cookie（无过期时间），HTTPCookieStorage 不持久化，
    /// App 重启即丢 → 手动序列化到 UserDefaults，启动时恢复。
    private static let cookieKey = "smrt.persisted.cookies"

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)

        let guestConfig = URLSessionConfiguration.ephemeral
        guestConfig.httpCookieStorage = nil
        guestConfig.httpShouldSetCookies = false
        guestConfig.timeoutIntervalForRequest = 30
        guestConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        guestSession = URLSession(configuration: guestConfig)

        restoreCookies()
    }

    // MARK: - Cookie 持久化

    private func persistCookies() {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: baseURL), !cookies.isEmpty else { return }
        let list: [[String: String]] = cookies.map {
            ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path]
        }
        UserDefaults.standard.set(list, forKey: Self.cookieKey)
    }

    private func restoreCookies() {
        guard let list = UserDefaults.standard.array(forKey: Self.cookieKey) as? [[String: String]] else { return }
        let existing = Set((HTTPCookieStorage.shared.cookies(for: baseURL) ?? []).map(\.name))
        for d in list {
            guard let name = d["name"], let value = d["value"],
                  let domain = d["domain"], let path = d["path"],
                  !existing.contains(name) else { continue }
            if let cookie = HTTPCookie(properties: [
                .domain: domain, .path: path, .name: name, .value: value,
                .expires: Date.distantFuture,
            ]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    // MARK: - 登录 / 会话

    /// 登录。成功返回 true；账号密码错误抛 SMRTError.loginFailed
    func login(email: String, password: String) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("process.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "sublogin", value: "1"),
            URLQueryItem(name: "school_key", value: schoolKey),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SMRTError.badResponse }

        // 302 → /sunshine/cafe 表示登录成功；否则服务端回渲染登录页
        if let url = http.url, url.path.hasPrefix("/sunshine/cafe"),
           let html = String(data: data, encoding: .utf8),
           !isLoggedOutHTML(html) {
            let account = SMRTAccount(email: email)
            UserDefaults.standard.set(account.email, forKey: "smrt.account.email")
            persistCookies()
            return true
        }
        throw SMRTError.loginFailed
    }

    /// 检查已有 cookie 会话是否有效
    func checkSession() async -> Bool {
        // 单次请求同时完成"可达性 + 登录态"判断（此前 guard 预检 + 正式请求重复拉了两遍）
        do {
            // requirePathContains：会话失效时 302 → /smrt/ 营销首页，靠最终路径判定
            let html = try await getHTML(path: "/sunshine/library",
                                         requirePathContains: "/sunshine/library")
            return !isLoggedOutHTML(html)
        } catch {
            return false
        }
    }

    /// 会话失效后用 Keychain 记住的账密静默重登（记住密码开启时）
    func autoReloginIfNeeded() async -> Bool {
        guard let email = savedEmail,
              let password = Keychain.read(account: email),
              !password.isEmpty else { return false }
        do {
            return try await login(email: email, password: password)
        } catch {
            return false
        }
    }

    /// 忘记密码：请求官网向邮箱发送重置邮件（对齐官网 forgotpass 表单：
    /// POST /process.php，email + subforgot=1 + school_key=sunshine）
    func forgotPassword(email: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("process.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "subforgot", value: "1"),
            URLQueryItem(name: "school_key", value: "sunshine"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SMRTError.badResponse
        }
        // 服务端对不存在账号会返回错误提示；未检出错误标记即认为邮件已发
        let html = (String(data: data, encoding: .utf8) ?? "").lowercased()
        if html.contains("alert-danger") || html.contains("no account") {
            throw SMRTError.loginFailed
        }
    }

    /// 页面是否为「未登录」状态（头部出现 Create Account 入口）
    private func isLoggedOutHTML(_ html: String) -> Bool {
        html.contains(">Create Account<") || html.contains("Create Account</a>")
    }

    /// 退出登录：清 cookie 与本地账号
    func logout() {
        if let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        UserDefaults.standard.removeObject(forKey: "smrt.account.email")
        UserDefaults.standard.removeObject(forKey: "smrt.account.displayName")
    }

    var savedEmail: String? {
        UserDefaults.standard.string(forKey: "smrt.account.email")
    }

    // MARK: - 当前账号显示名

    /// 缓存的当前账号显示名（中式「姓+名」，如 杨谨灿）
    var cachedDisplayName: String? {
        UserDefaults.standard.string(forKey: "smrt.account.displayName")
    }

    /// 拉取并缓存当前账号显示名（Me 页 name 字段，西式「名 姓」转中式）。
    /// 任何失败都回退到缓存值，不阻断调用方。
    func refreshMyDisplayName() async -> String? {
        guard let html = try? await getHTML(path: "/sunshine/me",
                                            requirePathContains: "/sunshine/me") else { return cachedDisplayName }
        if isLoggedOutHTML(html) { return cachedDisplayName }
        let name = await Task.detached(priority: .utility) {
            SMRTHTMLParser.parseMyDisplayName(html: html)
        }.value
        if let name, !name.isEmpty {
            let normalized = SMRTHTMLParser.normalizeChineseName(name)
            UserDefaults.standard.set(normalized, forKey: "smrt.account.displayName")
            return normalized
        }
        return cachedDisplayName
    }

    // MARK: - 页面抓取

    /// GET 指定路径（可含 query，如 /sunshine/cafe?page=2），返回 HTML 字符串。
    /// 注意：不能用 appendingPathComponent——它会把 "?" 编码成 %3F，必须字符串拼接。
    /// - Parameter asGuest: true 时走游客会话（无登录 cookie），用于 Cafe 公开内容。
    /// - Parameter requirePathContains: 校验重定向后最终 URL 路径必须包含此片段，
    ///   否则抛 notLoggedIn。**会话失效的判定关键**：官网在会话被顶掉（如网页端
    ///   单点登录互踢）或过期时，访问登录态页面会 302 到营销首页 /smrt/（该页
    ///   无 "Create Account" 标记，isLoggedOutHTML 检测不到），只看内容会误判
    ///   为「登录有效但数据为空」。
    /// - Parameter extraHeaders: 额外请求头（对齐官网请求行为时使用）。
    func getHTML(path: String, asGuest: Bool = false, extraHeaders: [String: String] = [:],
                 requirePathContains: String? = nil) async throws -> String {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw SMRTError.badResponse
        }
        var request = URLRequest(url: url)
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        Self.log.info("GET[\(asGuest ? "guest" : "auth")] \(url.absoluteString, privacy: .public)")
        let (data, response) = try await (asGuest ? guestSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw SMRTError.badResponse
        }
        if let finalURL = http.url, finalURL.absoluteString != url.absoluteString {
            Self.log.info("redirected → \(finalURL.absoluteString, privacy: .public)")
        }
        // 被重定向离开原路径 = 会话失效（302 踢到营销首页/登录页）
        if let requirePathContains, let finalURL = http.url,
           !finalURL.path.contains(requirePathContains) {
            throw SMRTError.notLoggedIn
        }
        if !asGuest { persistCookies() }
        return html
    }

    // MARK: - Cafe

    // Cafe 已整体改 WebView 承载官网页面（游客态、独立 WK 存储由 CafeView 处理），
    // App 不再解析视频流。

    // MARK: - Cafe

    /// Cafe 视频流（分页，游客态）。返回该页视频 + 是否还有下一页。
    /// 分页规则（实测）：?page=N，末页时分页控件 Next 项带 class="disabled"。
    /// 注意：搜索/分类结果不足一页时页面无分页控件 → 视为无下一页。
    func cafeVideos(tab: CafeTab, page: Int) async throws -> (videos: [CafeVideo], hasNext: Bool) {
        let separator = tab.path.contains("?") ? "&" : "?"
        let html = try await getHTML(path: "\(tab.path)\(separator)page=\(page)", asGuest: true)
        let videos = SMRTHTMLParser.parseCafeVideos(html: html, levelPath: tab.path)
        guard !videos.isEmpty else { throw SMRTError.parseFailed }
        let hasPagination = html.contains("pagination")
        let nextDisabled = html.contains("<li class=\"disabled\"><a href=\"#\">Next</a>")
        return (videos, hasPagination && !nextDisabled)
    }

    // MARK: - Library

    /// 课程类型（Library 顶部分类）
    enum CourseType: String, CaseIterable, Identifiable {
        case youth = "youth"
        case kids = "kids"
        case children = "children"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .youth: return "青少年"
            case .kids: return "儿童"
            case .children: return "幼儿"
            }
        }
    }

    func courses(type: CourseType) async throws -> [LibraryCourse] {
        let html = try await getHTML(path: "/sunshine/library?s=\(type.rawValue)")
        let courses = SMRTHTMLParser.parseCourses(html: html)
        guard !courses.isEmpty else { throw SMRTError.parseFailed }
        return courses
    }

    /// Library 首页（原版纵向结构：English Courses 类型卡 + 各类型分组课程卡）
    func libraryHome() async throws -> LibraryHome {
        let html = try await getHTML(path: "/sunshine/library")
        let home = SMRTHTMLParser.parseLibraryHome(html: html)
        guard !home.groups.isEmpty else { throw SMRTError.parseFailed }
        return home
    }

    func courseUnits(courseId: String) async throws -> [CourseUnit] {
        let html = try await getHTML(path: "/sunshine/library/\(courseId)")
        let units = SMRTHTMLParser.parseCourseUnits(html: html)
        guard !units.isEmpty else { throw SMRTError.parseFailed }
        return units
    }

    // MARK: - 课时

    // 课时详情已整体改 WebView 加载官网页面（正文/练习/切换均由网页自理），
    // App 侧不再有课时解析与预取缓存。

    // MARK: - Classes（我的班级）

    /// 我的班级列表（登录态）。新账号无班级时返回空数组。
    func myClasses() async throws -> [StudentClass] {
        // requirePathContains：会话失效时 302 → /smrt/，靠最终路径判定登出
        let html = try await getHTML(path: "/sunshine/classes",
                                     requirePathContains: "/sunshine/classes")
        if isLoggedOutHTML(html) { throw SMRTError.notLoggedIn }
        return SMRTHTMLParser.parseMyClasses(html: html)
    }

    /// 班级课程页（Course tab，单元树）
    func classCourse(classId: String) async throws -> ClassCourse {
        let html = try await getHTML(path: "/sunshine/class/\(classId)/course/",
                                     requirePathContains: "/sunshine/class/")
        if isLoggedOutHTML(html) { throw SMRTError.notLoggedIn }
        return try await Task.detached(priority: .userInitiated) {
            let course = SMRTHTMLParser.parseClassCourse(html: html)
            guard !course.units.isEmpty else { throw SMRTError.parseFailed }
            return course
        }.value
    }

    /// 班级子页面 HTML（Class List / Attendance / Assignments / Assessments / Class Info）
    /// - Parameter tab: 子 Tab（rawValue 即官网路径段）
    func classPageHTML(classId: String, tab: ClassTab) async throws -> String {
        try await getHTML(path: "/sunshine/class/\(classId)/\(tab.rawValue)/",
                          requirePathContains: "/sunshine/class/")
    }

    // MARK: - 练习

    // 练习的原生解析/作答/提交已整体移除：课时正文改 WebView 加载官网页面后，
    // 练习直接在网页内完成（官网 JS 自理登录态参数与提交），App 不再参与。
}
