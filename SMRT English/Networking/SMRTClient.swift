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
    case exerciseNoAccess

    var errorDescription: String? {
        switch self {
        case .badResponse:   return "网络响应异常"
        case .loginFailed:   return "邮箱或密码错误"
        case .notLoggedIn:   return "登录已过期，请重新登录"
        case .parseFailed:   return "页面解析失败，网站结构可能已变更"
        case .exerciseNoAccess: return "暂无权限访问该练习（老师可能未分享）"
        }
    }
}

final class SMRTClient {

    static let shared = SMRTClient()

    static let log = Logger(subsystem: "com.yangfei.smrtenglish", category: "SMRTClient")

    let baseURL = URL(string: "https://smrtenglish.cn")!
    let schoolKey = "sunshine"

    private let session: URLSession
    /// Cafe 专用游客会话：Cafe 内容公开且无需登录，而服务器对「登录用户」
    /// 会按账号绑定的分类过滤 Cafe（忽略 URL 分类路径），导致各 Tab 内容相同。
    /// 实测（2026-09-29）：登录 session 请求 /cafe/adults 也返回 children 内容；
    /// 游客态则各分类正确区分。因此 Cafe 走独立无 cookie 会话，与网页游客行为一致。
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
            let html = try await getHTML(path: "/sunshine/library")
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
        guard let html = try? await getHTML(path: "/sunshine/me") else { return cachedDisplayName }
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
    /// - Parameter extraHeaders: 额外请求头（练习 AJAX 需带 Referer / X-Requested-With 对齐官网）。
    func getHTML(path: String, asGuest: Bool = false, extraHeaders: [String: String] = [:]) async throws -> String {
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
        if !asGuest { persistCookies() }
        return html
    }

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

    // MARK: - 课时预取缓存（会话级：点击课时行瞬间预取，push 后命中秒开）

    private let lessonCacheLock = NSLock()
    private var lessonCache: [String: LessonDetail] = [:]

    /// 点击课时行时后台预取：转场动画期间完成下载+解析，push 进来直接命中
    func prefetchLesson(courseId: String, lessonId: String) {
        guard !hasCachedLesson(lessonId) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = try? await self?.lesson(courseId: courseId, lessonId: lessonId)
        }
    }

    private func hasCachedLesson(_ key: String) -> Bool {
        lessonCacheLock.lock()
        defer { lessonCacheLock.unlock() }
        return lessonCache[key] != nil
    }

    private func cachedLesson(_ key: String) -> LessonDetail? {
        lessonCacheLock.lock()
        defer { lessonCacheLock.unlock() }
        return lessonCache[key]
    }

    private func storeLesson(_ detail: LessonDetail, for key: String) {
        lessonCacheLock.lock()
        defer { lessonCacheLock.unlock() }
        lessonCache[key] = detail
    }

    func lesson(courseId: String, lessonId: String) async throws -> LessonDetail {
        if let cached = cachedLesson(lessonId) { return cached }

        // 记录最近一次课时页路径：练习 AJAX 请求要带它做 Referer（官网 jQuery .load 行为）
        lastLessonPath = "/sunshine/lesson/\(courseId)/\(lessonId)"
        let html = try await getHTML(path: lastLessonPath)
        // 解析显式丢到后台线程：大页面多轮正则扫描，避免任何潜在的主线程占用
        let detail = try await Task.detached(priority: .userInitiated) {
            let parsed = SMRTHTMLParser.parseLesson(html: html, lessonId: lessonId)
            guard !parsed.blocks.isEmpty else { throw SMRTError.parseFailed }
            return parsed
        }.value

        storeLesson(detail, for: lessonId)
        return detail
    }

    // MARK: - Classes（我的班级）

    /// 我的班级列表（登录态）。新账号无班级时返回空数组。
    func myClasses() async throws -> [StudentClass] {
        let html = try await getHTML(path: "/sunshine/classes")
        if isLoggedOutHTML(html) { throw SMRTError.notLoggedIn }
        return SMRTHTMLParser.parseMyClasses(html: html)
    }

    /// 班级课程页（Course tab，单元树）
    func classCourse(classId: String) async throws -> ClassCourse {
        let html = try await getHTML(path: "/sunshine/class/\(classId)/course/")
        if isLoggedOutHTML(html) { throw SMRTError.notLoggedIn }
        return try await Task.detached(priority: .userInitiated) {
            let course = SMRTHTMLParser.parseClassCourse(html: html)
            guard !course.units.isEmpty else { throw SMRTError.parseFailed }
            return course
        }.value
    }

    // MARK: - 练习

    /// 拉取练习内容。URL 构造与官网 JS 完全一致（smrt.ui.global.min.js 的 openBtn 点击处理）：
    ///   /{school}/exercise/{ssi}?answers=..&custom=..&country=..&unit=..
    ///   按 openBtn data-* 优先级分支追加：
    ///     data-userid 有值 → &userid=..&resultid=..&paid=..
    ///     data-classid 有值 → &classid=..&assignid=..
    ///     data-resultid 有值 → &resultid=..&paid=..
    ///     兜底 → &paid=..
    /// 缺失参数与网页行为一致传字面 "undefined"（登录用户练习走 userid 分支，
    /// 缺 userid 参数服务端会返回 No Access）。
    func exercise(_ ex: LessonExercise) async throws -> ExerciseData {
        let school = (ex.school == "undefined" || ex.school.isEmpty) ? schoolKey : ex.school
        var link = "/\(school)/exercise/\(ex.id)?answers=\(ex.answers)&custom=\(ex.custom)&country=\(ex.country)&unit=\(ex.unit)"
        // 官网分支判断是 `typeof attr < "u"`：属性存在即命中（即使值为空）
        if ex.userId != "undefined" {
            link += "&userid=\(ex.userId)&resultid=\(ex.resultId)&paid=\(ex.paid)"
        } else if ex.classId != "undefined" {
            link += "&classid=\(ex.classId)&assignid=\(ex.assignId)"
        } else if ex.resultId != "undefined" {
            link += "&resultid=\(ex.resultId)&paid=\(ex.paid)"
        } else {
            link += "&paid=\(ex.paid)"
        }
        // 请求头对齐官网 jQuery .load：练习 AJAX 校验来源，缺失返回 No Access
        var headers = [
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "text/html, */*; q=0.01",
        ]
        if !lastLessonPath.isEmpty {
            headers["Referer"] = baseURL.absoluteString + lastLessonPath
        }
        let html = try await getHTML(path: link, extraHeaders: headers)
        if isLoggedOutHTML(html) { throw SMRTError.notLoggedIn }
        // 服务端无权限片段：<div class="alert info"><strong>No Access</strong>…
        if html.contains("No Access") { throw SMRTError.exerciseNoAccess }
        return await Task.detached(priority: .userInitiated) {
            SMRTHTMLParser.parseExercise(html: html, ssi: ex.id)
        }.value
    }

    /// 保存/提交练习（对齐官网 JS：POST /json/exercise_save.php，serialize 整表单；
    /// Submit 时 status=1。Save 响应体为新 result_id。）
    /// - Returns: 服务端返回的新 result_id
    @discardableResult
    func saveExercise(_ data: ExerciseData,
                      selections: [String: String],
                      submit: Bool) async throws -> String {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "assign_results_comment", value: data.hidden.comment),
            URLQueryItem(name: "exercise_id", value: data.hidden.exerciseId),
            URLQueryItem(name: "user_id", value: data.hidden.userId),
            URLQueryItem(name: "status", value: submit ? "1" : data.hidden.status),
            URLQueryItem(name: "result_id", value: data.hidden.resultId),
        ]
        for (qid, value) in selections {
            items.append(URLQueryItem(name: "q\(qid)", value: value))
        }
        var components = URLComponents()
        components.queryItems = items

        var request = URLRequest(url: baseURL.appendingPathComponent("json/exercise_save.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SMRTError.badResponse
        }
        if !data.hidden.resultId.isEmpty {
            persistCookies()
        }
        return String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
