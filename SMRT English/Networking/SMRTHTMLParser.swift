//
//  SMRTHTMLParser.swift
//  SMRT English
//
//  轻量 HTML 解析器（纯 Foundation，无第三方依赖）
//  ============================================================
//  smrtenglish.cn 为服务端渲染页面，结构规整。本文件用
//  「标记扫描 + 正则提取」的方式解析四类页面：
//
//  1. Cafe 视频流     /sunshine/cafe[/levels]
//  2. Library 课程列表 /sunshine/library?s={type}
//  3. 课程页（单元树）  /sunshine/library/{courseId}
//  4. 课时页（内容块流） /sunshine/lesson/{courseId}/{lessonId}
//  5. 我的班级        /sunshine/classes
//  6. 班级课程页      /sunshine/class/{classId}/course/
//
//  已验证的页面结构（2026-09 抓取样本，见 /tmp/smrt_ref）：
//  - Cafe 卡片:  div.blog > a[data-src="#8200"] + postimage bg(vidXXXX.jpg)
//                + h3 标题 + a.category 分类 + div.content 描述
//                + 隐藏 div#8200 内 flowplayer source(vidXXXX.mp4)
//  - 课程卡:     div.course > a[href=/library/{id}] + img data-src
//                + h4.heading(+span.code) + p 描述
//  - 单元头:     span.unitdesc + span.unitnumber + unitphoto url('IMG')
//  - 课时链接:   div.lesson-section > a.lesson-link[href=/lesson/{cid}/{lid}]
//                > span.lessonnum(1-1) + 标题
//  - 课时内容:   div#lesson-wrapper 内按序出现
//                h2 / div.group>p / div.video(figure) / div.js-audio
//                / figure.playaudio(单词卡) / div.reveal(翻卡) / p / img
//  注意：视频块成对出现——country_1 为 iframe 嵌入版、country_2 为
//  多码率 mp4 直链版，标题相同，解析时按标题合并。
//

import Foundation

/// 正则匹配结果：完整匹配 + 全部捕获组
struct RegexMatch {
    let full: Substring
    let groups: [Substring?]   // groups[0] 对应捕获组 1
    subscript(_ i: Int) -> Substring? { groups[i - 1] }
}

enum SMRTHTMLParser {

    // MARK: - 基础工具

    /// 提取标签内属性值
    static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: name)
            + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }
        let ns = tag as NSString
        for i in 2...3 {
            if m.range(at: i).location != NSNotFound, m.range(at: i).length > 0 {
                return ns.substring(with: m.range(at: i))
            }
        }
        return nil
    }

    /// 去掉所有标签，仅保留文本
    static func stripTags(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解码常见 HTML 实体
    static func decodeEntities(_ s: String) -> String {
        var result = s
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"",
                     "apos": "'", "nbsp": " ", "#39": "'", "hellip": "…",
                     "mdash": "—", "ndash": "–",
                     "rsquo": "\u{2019}", "lsquo": "\u{2018}"]
        for (k, v) in named {
            result = result.replacingOccurrences(of: "&\(k);", with: v)
        }
        // 数字实体 &#123; 循环替换直到无匹配
        while let r = result.range(of: "&#(\\d+);", options: .regularExpression) {
            let token = String(result[r])
            let digits = token.dropFirst(2).dropLast()
            if let n = UInt32(digits), let scalar = Unicode.Scalar(n) {
                result.replaceSubrange(r, with: String(Character(scalar)))
            } else {
                result.replaceSubrange(r, with: " ")
            }
        }
        return result
    }

    /// 提取页面某标记之后的区域（到下一个标记或结尾）
    static func region(after marker: String, until endMarker: String, in html: String) -> String {
        guard let start = html.range(of: marker)?.upperBound else { return "" }
        let end = html.range(of: endMarker, range: start..<html.endIndex)?.lowerBound ?? html.endIndex
        return String(html[start..<end])
    }

    /// 正则全部匹配（含捕获组）
    static func matches(_ pattern: String, in s: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        let results = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        return results.compactMap { m in
            guard let fullRange = Range(m.range, in: s) else { return nil }
            var groups: [Substring?] = []
            for i in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: s) {
                    groups.append(s[r])
                } else {
                    groups.append(nil)
                }
            }
            return RegexMatch(full: s[fullRange], groups: groups)
        }
    }

    /// 正则第一个匹配的捕获组 1
    static func firstGroup(_ pattern: String, _ s: String) -> String? {
        matches(pattern, in: s).first.flatMap { $0[1] }.map(String.init)
    }

    // MARK: - 1. Cafe 视频流

    static func parseCafeVideos(html: String, levelPath: String) -> [CafeVideo] {
        var videos: [CafeVideo] = []
        // 按 div.blog 切卡片块
        let cardMarker = "<div class=\"blog "
        let positions = html.ranges(of: cardMarker).map { $0.lowerBound }
        guard !positions.isEmpty else { return [] }
        var chunks: [String] = []
        for (i, pos) in positions.enumerated() {
            let end = i + 1 < positions.count ? positions[i + 1] : html.endIndex
            chunks.append(String(html[pos..<end]))
        }
        for chunk in chunks {
            guard chunk.contains("videothumb") else { continue }
            let modalId = firstGroup(##"data-src="#(\d+)""##, chunk)
            let thumb = firstGroup(#"url\((https://[^)]+?\.jpg)\)"#, chunk)
            let title = firstGroup(#"<h3>([\s\S]*?)</h3>"#, chunk).map(stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let desc = firstGroup(#"<div class="content">([\s\S]*?)</div>"#, chunk).map(stripTags) ?? ""
            // 分类标签：class("category adult"——第一个常为级别标签) + href + 文本
            let categories: [CafeCategory] = matches(#"<a class="category([^"]*)" href="([^"]*)">([\s\S]*?)</a>"#, in: chunk)
                .compactMap { m in
                    guard let classRest = m[1], let path = m[2], let name = m[3] else { return nil }
                    let n = stripTags(String(name))
                    guard !n.isEmpty else { return nil }
                    let levelPart = String(classRest).trimmingCharacters(in: .whitespaces)
                    let level = ["adult", "youth", "kids", "children"].contains(levelPart) ? levelPart : nil
                    return CafeCategory(name: n, path: decodeEntities(String(path)), level: level)
                }

            var videoURL: URL? = nil
            // 优先：modal 容器里的 flowplayer source
            if let id = modalId, let modalRange = html.range(of: "<div id=\"\(id)\"") {
                let modalEnd = html.range(of: "</div>\n</div>", range: modalRange.upperBound..<html.endIndex)?
                    .lowerBound ?? html.endIndex
                let modal = String(html[modalRange.upperBound..<modalEnd])
                let src = firstGroup(#"<source[^>]*type="video/mp4"[^>]*src="([^"]+)""#, modal)
                    ?? firstGroup(#"<source[^>]*src="([^"]+)"[^>]*type="video/mp4""#, modal)
                    ?? firstGroup(#"<source[^>]*src="([^"]+\.mp4[^"]*)""#, modal)
                if let src {
                    videoURL = URL(string: decodeEntities(src))
                }
            }
            // 兜底：缩略图 vid 号 = 视频文件名（实测同编号规律）
            if videoURL == nil, let thumb = thumb, thumb.contains("/vid") {
                let mp4 = thumb.replacingOccurrences(of: ".jpg", with: ".mp4")
                videoURL = URL(string: mp4)
            }
            videos.append(CafeVideo(id: modalId ?? UUID().uuidString,
                                    title: title,
                                    description: desc,
                                    categories: categories,
                                    thumbnailURL: thumb.flatMap(URL.init(string:)),
                                    videoURL: videoURL,
                                    levelPath: levelPath))
        }
        return videos
    }

    // MARK: - 2. Library 课程列表

    static func parseCourses(html: String) -> [LibraryCourse] {
        var courses: [LibraryCourse] = []
        let pattern = #"<a href="/sunshine/library/(\d+)">[\s\S]*?data-src="([^"]+)"[\s\S]*?<h4 class="heading">([\s\S]*?)</h4>[\s\S]*?<p>([\s\S]*?)</p>"#
        for m in matches(pattern, in: html) {
            guard let id = m[1], let img = m[2], let heading = m[3], let desc = m[4] else { continue }
            let code = firstGroup(#"<span class="code">([^<]*)</span>"#, String(heading)) ?? ""
            let noCode = heading.replacingOccurrences(of: #"<span class="code">[^<]*</span>"#,
                                                      with: "", options: .regularExpression)
            courses.append(LibraryCourse(id: String(id),
                                         title: stripTags(String(noCode)),
                                         code: code,
                                         courseDescription: stripTags(String(desc)),
                                         imageURL: URL(string: decodeEntities(String(img)))))
        }
        return courses
    }

    // MARK: - 2b. Library 首页（原版纵向结构）

    /// 解析 /sunshine/library 首页：
    /// h1 "Courses" + English Courses 类型卡（.coursetype）+ 各类型分组（.title h3 + 课程封面卡）
    static func parseLibraryHome(html: String) -> LibraryHome {
        // 类型卡
        let types: [LibraryTypeCard] = matches(
            #"<a href="/sunshine/library\?s=(\w+)">\s*<div class="typeimg">\s*<img[^>]*data-src="([^"]+)"[^>]*>\s*<p>([^<]*)</p>"#,
            in: html
        ).compactMap { m in
            guard let key = m[1], let img = m[2], let name = m[3] else { return nil }
            return LibraryTypeCard(name: stripTags(String(name)),
                                   key: String(key),
                                   imageURL: URL(string: decodeEntities(String(img))))
        }

        // 类型分组：.title h3 到下一个 .title / footer 之间是课程卡
        var groups: [LibraryGroup] = []
        let groupPattern = #"<div class="title"><a href="[^"]*\?s=(\w+)"><h3>([\s\S]*?)</h3></a></div>([\s\S]*?)(?=<div class="title">|<footer)"#
        for m in matches(groupPattern, in: html) {
            guard let key = m[1], let titleHTML = m[2], let body = m[3] else { continue }
            let title = stripTags(String(titleHTML))
            let courses: [LibraryCourseCard] = matches(
                #"<a href="/sunshine/library/(\d+)">\s*<img[^>]*data-src="([^"]+)""#,
                in: String(body)
            ).compactMap { cm in
                guard let cid = cm[1], let img = cm[2] else { return nil }
                return LibraryCourseCard(id: String(cid),
                                         imageURL: URL(string: decodeEntities(String(img))))
            }
            guard !courses.isEmpty else { continue }
            groups.append(LibraryGroup(title: title, key: String(key), courses: courses))
        }
        return LibraryHome(types: types, groups: groups)
    }

    // MARK: - 3. 课程页（单元树）

    static func parseCourseUnits(html: String) -> [CourseUnit] {
        let unitsRegion = region(after: "<div id=\"units\">", until: "<div id=\"mobile-", in: html)
        guard !unitsRegion.isEmpty else { return [] }
        let unitMarker = "<div class=\"lesson-unit row\">"
        let positions = unitsRegion.ranges(of: unitMarker).map { $0.lowerBound }
        guard !positions.isEmpty else { return [] }
        var units: [CourseUnit] = []
        for (i, pos) in positions.enumerated() {
            let end = i + 1 < positions.count ? positions[i + 1] : unitsRegion.endIndex
            let chunk = String(unitsRegion[pos..<end])
            let name = firstGroup(#"<span class="unitdesc">([\s\S]*?)</span>"#, chunk).map(stripTags) ?? "Unit \(i + 1)"
            let number = firstGroup(#"<span class="unitnumber">([\s\S]*?)</span>"#, chunk) ?? String(format: "%02d", i + 1)
            let photo = firstGroup(#"unitphoto[^>]*background-image:\s*url\('([^']+)'["\)]"#, chunk)

            var sections: [LessonSection] = []
            var currentTitle = ""
            var currentLessons: [LessonItem] = []

            func flushSection() {
                if !currentLessons.isEmpty {
                    sections.append(LessonSection(title: currentTitle.isEmpty ? "课时" : currentTitle,
                                                  lessons: currentLessons))
                    currentLessons = []
                }
            }

            // 顺序扫描 category-header / 可用课时 / 未解锁课时（disabled-lesson 无链接）
            let tokenPattern = #"<div class="category-header"><h4>([\s\S]*?)</h4></div>|<div class="lesson-section"><a href="/sunshine/lesson/(\d+)/(\d+)"[^>]*>[\s\S]*?<span class="lessonnum">([\s\S]*?)</span>([\s\S]*?)</span>|<div class="lesson-section"><div class="lesson-link disabled-lesson">[\s\S]*?<span class="lessonnum">([\s\S]*?)</span>([\s\S]*?)</span>"#
            for m in matches(tokenPattern, in: chunk) {
                if let sectionTitle = m[1] {
                    // 遇到新分组：先落盘上一组
                    flushSection()
                    currentTitle = stripTags(String(sectionTitle))
                } else if let cid = m[2], let lid = m[3], let num = m[4], let title = m[5] {
                    currentLessons.append(LessonItem(id: String(lid),
                                                     courseId: String(cid),
                                                     number: stripTags(String(num)),
                                                     title: stripTags(String(title))))
                } else if let num = m[6], let title = m[7] {
                    let numStr = stripTags(String(num))
                    currentLessons.append(LessonItem(id: "locked-\(numStr)",
                                                     courseId: "",
                                                     number: numStr,
                                                     title: stripTags(String(title)),
                                                     locked: true))
                }
            }
            flushSection()
            units.append(CourseUnit(name: name, number: number,
                                    imageURL: photo.flatMap(URL.init(string:)),
                                    sections: sections))
        }
        return units
    }

    // MARK: - 4. 课时页（内容块流）

    static func parseLesson(html: String, lessonId: String) -> LessonDetail {
        let pageTitle = firstGroup(#"<h1 class="page-title">([\s\S]*?)</h1>"#, html).map(stripTags) ?? ""
        let siblings = parseSiblings(html: html)
        let content = region(after: "<div id=\"lesson-wrapper\">",
                             until: "<div id=\"exercise-list\"", in: html)
        let blocks = parseBlocks(content)
        let exercises = parseExercises(html: html)
        return LessonDetail(id: lessonId, title: pageTitle, siblings: siblings,
                            blocks: blocks, exercises: exercises)
    }

    /// 练习列表：exercise-list 区的 openBtn（data-ssi + 标题文本 + 请求上下文参数）。
    /// 页面里有两个 id="exercise-list"：unit-modal 内的空壳（无 openBtn）和
    /// 真实列表（class 含 exercise-group）；对空壳区域匹配 openBtn 得空集，无副作用。
    static func parseExercises(html: String) -> [LessonExercise] {
        let region = self.region(after: "id=\"exercise-list\"", until: "mobile-768px", in: html)
        guard !region.isEmpty else { return [] }
        var exercises: [LessonExercise] = []
        for m in matches(#"<button[^>]*class="openBtn"[^>]*>([\s\S]*?)</button>"#, in: region) {
            guard let ssi = attr("data-ssi", in: String(m.full)) else { continue }
            // 按钮内含 material 图标 span（ligature 文本如 keyboard_arrow_right），剥掉再取标题
            let label = String(m[1] ?? "")
                .replacingOccurrences(of: #"<span class="ico[^"]*">[\s\S]*?</span>"#,
                                      with: "", options: .regularExpression)
            let title = stripTags(label)
            guard !title.isEmpty else { continue }
            // 请求上下文参数：官网 JS 用这些 data-* 拼练习 AJAX URL；缺失时
            // jQuery .attr() 返回 undefined，拼进 URL 是字面 "undefined" —— 保持一致
            func webAttr(_ name: String) -> String { attr(name, in: String(m.full)) ?? "undefined" }
            exercises.append(LessonExercise(
                id: String(ssi),
                title: title,
                school: webAttr("data-school"),
                country: webAttr("data-country"),
                custom: webAttr("data-custom"),
                unit: webAttr("data-unit"),
                answers: webAttr("data-answers"),
                paid: webAttr("data-paid"),
                userId: webAttr("data-userid"),
                resultId: webAttr("data-resultid"),
                classId: webAttr("data-classid"),
                assignId: webAttr("data-assignid")
            ))
        }
        return exercises
    }

    /// 侧边栏课时导航（当前课时所在分组列表，去重）
    static func parseSiblings(html: String) -> [LessonItem] {
        let navRegion = region(after: "<div class=\"lesson-columns-wrapper\">",
                               until: "<div id=\"lesson-content\"", in: html)
        guard !navRegion.isEmpty else { return [] }
        var items: [LessonItem] = []
        var seen = Set<String>()
        let pattern = #"<a href="/sunshine/lesson/(\d+)/(\d+)"[^>]*class="lesson-link[^"]*"[\s\S]*?<span class="lessonnum">([\s\S]*?)</span>([\s\S]*?)</span>"#
        for m in matches(pattern, in: navRegion) {
            guard let cid = m[1], let lid = m[2], let num = m[3], let title = m[4] else { continue }
            let lidStr = String(lid)
            guard !seen.contains(lidStr) else { continue }
            seen.insert(lidStr)
            items.append(LessonItem(id: lidStr, courseId: String(cid),
                                    number: stripTags(String(num)),
                                    title: stripTags(String(title))))
        }
        return items
    }

    /// 内容块顺序扫描
    static func parseBlocks(_ html: String) -> [LessonBlock] {
        var blocks: [LessonBlock] = []

        // 视频块成对出现（country_1 iframe + country_2 mp4，标题相同），先收集再合并。
        // 注意：figcaption 标题级别不固定（iframe 版用 h4、mp4 版可能用 h2，
        // 如 lesson/1339/13180），个别块甚至没有 figcaption —— 合并条件放宽为
        // 「标题相同 或 当前块标题为空」，避免配对失败导致 mp4 源整块丢失。
        var pendingTitle = ""
        var pendingEmbed: String? = nil
        var pendingSources: [LessonVideoSource] = []
        var hasPendingVideo = false

        func flushVideo() {
            guard hasPendingVideo else { return }
            if !pendingTitle.isEmpty || !pendingSources.isEmpty || pendingEmbed != nil {
                blocks.append(.video(title: pendingTitle, sources: pendingSources, embedPath: pendingEmbed))
            }
            hasPendingVideo = false
            pendingTitle = ""
            pendingEmbed = nil
            pendingSources = []
        }

        let tokenRegex = #"<h2[^>]*>[\s\S]*?</h2>|<div class="video">|<div class="js-audio">|<figure class="playaudio">|<div class="reveal|<div class="photo[^"]*">|<div class="row">|<div class="click row">|<div class="write-inline">[\s\S]*?</div>|<div class="draw"[\s\S]*?</div>|<div data-answer="[^"]*" class="sort images">[\s\S]*?</div>|<div class="group">[\s\S]*?</div>|<p[^>]*>[\s\S]*?</p>"#
        var searchFrom = html.startIndex
        while let tokenRange = html.range(of: tokenRegex, options: .regularExpression,
                                          range: searchFrom..<html.endIndex) {
            let token = String(html[tokenRange])

            if token.hasPrefix("<h2") {
                let text = stripTags(firstGroup(#"<h2[^>]*>([\s\S]*?)</h2>"#, token) ?? "")
                if !text.isEmpty {
                    flushVideo()
                    blocks.append(.heading(text))
                }
                searchFrom = tokenRange.upperBound
                continue
            }

            if token == "<div class=\"video\">" {
                let end = html.range(of: "</figure>", range: tokenRange.upperBound..<html.endIndex)?
                    .upperBound ?? tokenRange.upperBound
                let chunk = String(html[tokenRange.upperBound..<end])
                // 标题级别不固定：h2~h5 都出现过（13180 课时 iframe 版 h4 / mp4 版 h2）
                let title = stripTags(firstGroup(#"<figcaption>\s*<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, chunk) ?? "")
                let embed = firstGroup(#"<iframe[^>]*src="(/embed/[^"?]+)"#, chunk)
                var sources: [LessonVideoSource] = []
                let srcPatternA = #"<source[^>]*type="video/mp4"[^>]*src="([^"]+)"[^>]*>"#
                let srcPatternB = #"<source[^>]*src="([^"]+)"[^>]*type="video/mp4"[^>]*>"#
                var srcMatches = matches(srcPatternA, in: chunk)
                if srcMatches.isEmpty { srcMatches = matches(srcPatternB, in: chunk) }
                for sm in srcMatches {
                    if let g = sm[1], let u = URL(string: decodeEntities(String(g))) {
                        let size = Int(attr("size", in: String(sm.full)) ?? "0") ?? 0
                        sources.append(LessonVideoSource(url: u, size: size))
                    }
                }
                if hasPendingVideo, title == pendingTitle || title.isEmpty {
                    // 成对块：合并
                    pendingSources += sources
                    if pendingEmbed == nil { pendingEmbed = embed }
                    if pendingTitle.isEmpty { pendingTitle = title }
                } else {
                    flushVideo()
                    pendingTitle = title
                    pendingEmbed = embed
                    pendingSources = sources
                    hasPendingVideo = true
                }
                searchFrom = end
                continue
            }

            if token == "<div class=\"js-audio\">" {
                let end = html.range(of: "</figure>", range: tokenRange.upperBound..<html.endIndex)?
                    .upperBound ?? tokenRange.upperBound
                let chunk = String(html[tokenRange.upperBound..<end])
                let src = firstGroup(#"<source[^>]*src="([^"]+)""#, chunk)
                    ?? firstGroup(#"<audio[^>]*src="([^"]+)""#, chunk)
                if let src = src, let u = URL(string: decodeEntities(src)) {
                    flushVideo()
                    blocks.append(.audio(title: nil, url: u))
                }
                searchFrom = end
                continue
            }

            if token == "<figure class=\"playaudio\">" {
                let end = html.range(of: "</figure>", range: tokenRange.upperBound..<html.endIndex)?
                    .upperBound ?? tokenRange.upperBound
                let chunk = String(html[tokenRange.upperBound..<end])
                let caption = stripTags(firstGroup(#"<figcaption>([\s\S]*?)</figcaption>"#, chunk) ?? "")
                let img = firstGroup(#"data-src="([^"]+)""#, chunk)
                let audio = firstGroup(#"<audio[^>]*src="([^"]+)""#, chunk)
                    ?? firstGroup(#"<source[^>]*src="([^"]+)""#, chunk)
                flushVideo()
                blocks.append(.vocabCard(caption: caption,
                                         imageURL: img.flatMap { URL(string: decodeEntities($0)) },
                                         audioURL: audio.flatMap { URL(string: decodeEntities($0)) }))
                searchFrom = end
                continue
            }

            // 单图块：<div class="photo full"><figure><img src alt /></figure></div>
            if token.hasPrefix("<div class=\"photo") {
                let end = html.range(of: "</figure>", range: tokenRange.upperBound..<html.endIndex)?
                    .upperBound ?? tokenRange.upperBound
                let chunk = String(html[tokenRange.upperBound..<end])
                for im in matches(#"<img[^>]*>"#, in: chunk) {
                    let tag = String(im.full)
                    guard let src = attr("src", in: tag),
                          let u = URL(string: decodeEntities(src)) else { continue }
                    let alt = stripTags(attr("alt", in: tag) ?? "")
                    flushVideo()
                    blocks.append(.image(url: u, caption: alt.isEmpty ? nil : alt))
                }
                searchFrom = end
                continue
            }

            // 多图行 / 点图活动行：<div class="row"> 或 <div class="click row">（听音选图，无题图）
            // 含 click/button 卡片 → 点图判对错活动；否则按图片行解析
            if token == "<div class=\"row\">" || token.hasPrefix("<div class=\"click") {
                let nextStart = html.range(of: #"<div class="group|<h2|<div class="video|<div class="js-audio|<figure class="playaudio|<div class="reveal|<div class="photo|<div class="write-inline"|<div class="draw"|<div data-answer"#,
                                           options: .regularExpression,
                                           range: tokenRange.upperBound..<html.endIndex)?.lowerBound
                let end = nextStart ?? html.endIndex
                let chunk = String(html[tokenRange.upperBound..<end])

                if chunk.contains("<div class=\"click") || chunk.contains("figure class=\"button") {
                    // 课堂活动（可能多个连排）：figure.view 题图开新活动，
                    // 其后的 figure.button(correct/incorrect) 归属当前活动
                    var pendingPrompt: URL?
                    var pendingChoices: [ActivityChoice] = []
                    func flushActivity() {
                        if !pendingChoices.isEmpty {
                            blocks.append(.activity(promptImageURL: pendingPrompt, choices: pendingChoices))
                        }
                        pendingChoices = []
                    }
                    // 注意：button 分支必须闭合到 </figure>，否则惰性匹配止于开标签，取不到 data-src
                    let actToken = #"<figure class="view">[\s\S]*?<img[^>]*src="([^"]+)"|<figure class="button ([a-z]+)"[^>]*>[\s\S]*?</figure>"#
                    for am in matches(actToken, in: chunk) {
                        if let promptSrc = am[1] {
                            flushActivity()
                            pendingPrompt = URL(string: decodeEntities(String(promptSrc)))
                        } else if let state = am[2] {
                            let fig = String(am.full)
                            let src = firstGroup(#"data-src="([^"]+)""#, fig)
                                ?? firstGroup(#"<img[^>]*src="([^"]+)""#, fig)
                            pendingChoices.append(ActivityChoice(
                                imageURL: src.flatMap { URL(string: decodeEntities($0)) },
                                isCorrect: String(state) == "correct"
                            ))
                        }
                    }
                    flushActivity()
                    // 活动行已整体消费，不再走图片行
                    searchFrom = end
                    continue
                }

                var rowImages: [LessonImage] = []
                for fm in matches(#"<figure[^>]*>([\s\S]*?)</figure>"#, in: chunk) {
                    let fig = String(fm[1] ?? "")
                    guard let src = firstGroup(#"<img[^>]*src="([^"]+)""#, fig),
                          let u = URL(string: decodeEntities(src)) else { continue }
                    // 图注优先取 figcaption，其次 img alt（官网列内 <p> 与 alt 一致）
                    let caption = stripTags(firstGroup(#"<figcaption>[\s\S]*?<h[34][^>]*>([\s\S]*?)</h[34]>"#, fig) ?? "")
                    let alt = stripTags(firstGroup(#"<img[^>]*alt="([^"]*)""#, fig) ?? "")
                    let cap = caption.isEmpty ? alt : caption
                    rowImages.append(LessonImage(url: u, caption: cap.isEmpty ? nil : cap))
                }
                if !rowImages.isEmpty {
                    flushVideo()
                    blocks.append(.imageRow(rowImages))
                }
                searchFrom = end
                continue
            }

            // 内联填空：<div class="write-inline"><p>Write your name. <span contenteditable>…</span>.</p></div>
            if token.hasPrefix("<div class=\"write-inline\"") {
                let pContent = firstGroup(#"<p[^>]*>([\s\S]*?)</p>"#, token) ?? token
                let editableRange = pContent.range(of: #"<span[^>]*contenteditable[^>]*>[\s\S]*?</span>"#,
                                                   options: .regularExpression)
                let before = stripTags(editableRange.map { String(pContent[..<$0.lowerBound]) } ?? pContent)
                let after = editableRange.map { stripTags(String(pContent[$0.upperBound...])) } ?? ""
                flushVideo()
                blocks.append(.writeInline(before: before, after: after))
                searchFrom = tokenRange.upperBound
                continue
            }

            // 描红画板：<div class="draw" data-name="Aa-Zz" data-img="底图"><canvas class="sketchpad">…</div>
            if token.hasPrefix("<div class=\"draw\"") {
                let name = stripTags(attr("data-name", in: token) ?? "")
                let bg = attr("data-img", in: token).flatMap { URL(string: decodeEntities($0)) }
                flushVideo()
                blocks.append(.drawBoard(name: name, backgroundImageURL: bg))
                searchFrom = tokenRange.upperBound
                continue
            }

            // 排序活动：<div data-answer="231" class="sort images"><figure id="1">…</figure>…</div>
            if token.hasPrefix("<div data-answer") && token.contains("class=\"sort") {
                let answer = attr("data-answer", in: token) ?? ""
                var items: [SortItem] = []
                for fm in matches(#"<figure id="([^"]+)">[\s\S]*?</figure>"#, in: token) {
                    let fig = String(fm.full)
                    let src = firstGroup(#"data-src="([^"]+)""#, fig)
                        ?? firstGroup(#"<img[^>]*src="([^"]+)""#, fig)
                    let alt = stripTags(firstGroup(#"alt="([^"]*)""#, fig) ?? "")
                    items.append(SortItem(id: String(fm[1] ?? ""),
                                          imageURL: src.flatMap { URL(string: decodeEntities($0)) },
                                          alt: alt))
                }
                flushVideo()
                if !items.isEmpty {
                    blocks.append(.sortActivity(items: items, answer: answer))
                }
                searchFrom = tokenRange.upperBound
                continue
            }

            if token.hasPrefix("<div class=\"reveal") {
                let nextStart = html.range(of: #"<div class="reveal|<div class="group|<h2|<div class="video|<div class="js-audio|<figure class="playaudio|<div class="photo|<div class="row|<div class="write-inline"|<div class="draw""#,
                                           options: .regularExpression,
                                           range: tokenRange.upperBound..<html.endIndex)?.lowerBound
                let end = nextStart ?? html.endIndex
                let chunk = String(html[tokenRange.upperBound..<end])
                let img = firstGroup(#"data-src="([^"]+)""#, chunk)
                let texts = matches(#"<div class="box">([\s\S]*?)</div>"#, in: chunk)
                    .compactMap { $0[1] }
                    .map { stripTags(String($0)) }
                    .filter { !$0.isEmpty }
                flushVideo()
                blocks.append(.revealCard(imageURL: img.flatMap { URL(string: decodeEntities($0)) },
                                          texts: texts))
                searchFrom = end
                continue
            }

            if token.hasPrefix("<div class=\"group\">") {
                let text = stripTags(token)
                if !text.isEmpty {
                    flushVideo()
                    blocks.append(.text(text))
                }
                searchFrom = tokenRange.upperBound
                continue
            }

            // 普通 <p>
            let text = stripTags(token)
            if !text.isEmpty {
                flushVideo()
                blocks.append(.text(text))
            }
            searchFrom = tokenRange.upperBound
        }
        flushVideo()
        return blocks
    }
}

// MARK: - String 扩展

extension String {
    /// 非重叠查找子串范围
    func ranges(of needle: String) -> [Range<Index>] {
        var result: [Range<Index>] = []
        var from = startIndex
        while let r = range(of: needle, range: from..<endIndex) {
            result.append(r)
            from = r.upperBound
        }
        return result
    }
}

// MARK: - 5. 我的班级（/sunshine/classes）
//
// 页面结构（2026-09-29 抓取样本）：
//   <div id="classes">
//     <a href="/sunshine/class/25057/course/">
//       <div class="classblock">
//         <h2>EE1段周一班EE1上半年</h2>
//         <span class="coursepill">ELEMENTARY ENGLISH ONE</span>
//         <div class="row">
//           <div class="... profile"><div class="piclittle classes"
//                data-tippy-content="欣夏 张" style="background-image: url(...)"></div></div>
//           ...
//         </div>
//       </div>
//     </a>
//     <a ... data-target="#join-class-modal">…Join a Class…</a>  ← 加入班级卡，非班级数据
//   </div>

extension SMRTHTMLParser {

    /// 官网成员名为西式「名 姓」顺序（如 谨灿 杨），转为中式「姓+名」（杨谨灿）。
    /// 仅当两段均为汉字时才交换，英文名（Jim Clark）原样保留。
    static func normalizeChineseName(_ s: String) -> String {
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return s }
        func isCJK(_ str: String) -> Bool {
            !str.isEmpty && str.unicodeScalars.allSatisfy { scalar in
                (0x4E00...0x9FFF).contains(scalar.value)
            }
        }
        if isCJK(parts[0]) && isCJK(parts[1]) {
            return parts[1] + parts[0]
        }
        return s
    }

    /// 解析 Me 页当前账号显示名（<input name="name" type="text" value="谨灿 杨">）
    static func parseMyDisplayName(html: String) -> String? {
        guard let raw = firstGroup(#"name="name"[^>]*value="([^"]*)""#, html) else { return nil }
        let name = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 解析 Classes 列表页。新账号可能没有任何班级，返回空数组属正常情况。
    static func parseMyClasses(html: String) -> [StudentClass] {
        let region = self.region(after: "id=\"classes\"", until: "<footer", in: html)
        guard !region.isEmpty else { return [] }

        var classes: [StudentClass] = []
        // 按班级链接切块：每个 <a href="/sunshine/class/{id}/course/"> 起一个块
        let linkPattern = #"<a href="/sunshine/class/(\d+)/course/">"#
        let linkMatches = matches(linkPattern, in: region)

        for (index, link) in linkMatches.enumerated() {
            guard let id = link[1] else { continue }
            // link.full 是 region 的切片，startIndex 即该班级链接在 region 中的起点
            let chunkStart = link.full.startIndex
            let chunkEnd: String.Index
            if index + 1 < linkMatches.count {
                chunkEnd = linkMatches[index + 1].full.startIndex
            } else {
                chunkEnd = region.endIndex
            }
            let chunk = String(region[chunkStart..<chunkEnd])

            // 班级名（h2）与课程名（coursepill）
            let name = stripTags(firstGroup(#"<h2[^>]*>([\s\S]*?)</h2>"#, chunk) ?? "")
            let course = stripTags(firstGroup(#"class="coursepill"[^>]*>([\s\S]*?)</span>"#, chunk) ?? "")

            // 成员：piclittle 头像的 data-tippy-content = 成员名，style 内为头像图
            var members: [ClassMember] = []
            for m in matches(#"class="piclittle classes"[^>]*"#, in: chunk) {
                let tag = String(m.full)
                guard let memberName = attr("data-tippy-content", in: tag), !memberName.isEmpty else { continue }
                let avatarPath = attr("style", in: tag).flatMap { style -> String? in
                    firstGroup(#"url\((['"]?)([^'")]+)\1\)"#, style)
                }
                let avatarURL = avatarPath.flatMap(URL.init(string:))
                members.append(ClassMember(id: memberName,
                                           name: normalizeChineseName(memberName),
                                           avatarURL: avatarURL))
            }

            // 服务端成员顺序不稳定（每次请求可能变化，UI 上表现为每次进 Tab 跳动），
            // 本地按姓名固定排序，并生成与顺序绑定的稳定 id
            let sortedMembers = members
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .enumerated()
                .map { index, member in
                    ClassMember(id: "\(index)-\(member.name)",
                                name: member.name,
                                avatarURL: member.avatarURL)
                }

            classes.append(StudentClass(
                id: String(id),
                name: name,
                course: course,
                coursePath: "/sunshine/class/\(id)/course/",
                members: sortedMembers
            ))
        }
        return classes
    }
}

// MARK: - 6. 班级课程页（/sunshine/class/{classId}/course/）
//
// 页面结构（2026-09-29 抓取样本）：
//   课程名: <h1 class="page-title"><a href="/sunshine/classes">Elementary English One</a></h1>
//   班级名: <div class="classtext compact"><h3 class="compact">EE1段周一班EE1上半年</h3></div>
//   课程入口: <a class="btn btn-circle ..." href="/sunshine/library/346">
//   单元树: <div class="panel-group" id="accordion">
//     <div class="unit-section">
//       <a class="unit-header" href="#unit1339">
//         <h3 class="unit-title"><span class="unit-image" style="background-image: url(IMG)"/>My Day<span class="unit-number-right">01</span></h3>
//       </a>
//       <div id="unit1339" class="unit-content unit-open ...">
//         <div class="lesson-columns-wrapper"><div class="lesson-column">
//           <div class="category-header"><h4>Conversation and Practice</h4></div>
//           <div class="lesson-section"><a href="/sunshine/lesson/1339/13180" class="lesson-link">
//             <div class="lesson-item"><div><span class="lesson-status has-exercises" data-tippy-content="In Progress"></span>
//               <span class="lesson-title"><span class="lessonnum">1-1</span> Vocabulary &amp; Listening A</span></div></div>
//           </a></div>...

extension SMRTHTMLParser {

    /// 解析班级课程页。无单元（未开课班级）返回空数组。
    static func parseClassCourse(html: String) -> ClassCourse {
        let className = stripTags(firstGroup(#"classtext[^>]*>\s*<h3[^>]*>([\s\S]*?)</h3>"#, html) ?? "")
        let courseName = stripTags(firstGroup(#"<h1 class="page-title"><a[^>]*>([\s\S]*?)</a>"#, html) ?? "")
        let courseLibraryId = firstGroup(#"href="/sunshine/library/(\d+)""#, html) ?? ""

        let accordion = region(after: "id=\"accordion\"", until: "<div id=\"mobile-", in: html)
        let unitMarker = "<div class=\"unit-section\">"
        let positions = accordion.ranges(of: unitMarker).map { $0.lowerBound }

        var units: [ClassUnit] = []
        for (i, pos) in positions.enumerated() {
            let end = i + 1 < positions.count ? positions[i + 1] : accordion.endIndex
            let chunk = String(accordion[pos..<end])

            // 单元头：unit-title 内剥掉 unit-image / unit-number-right span 后即单元名
            let titleChunk = firstGroup(#"<h3 class="unit-title">([\s\S]*?)</h3>"#, chunk) ?? ""
            let imageURL = firstGroup(#"class="unit-image"[^>]*background-image:\s*url\(([^)]+)\)"#, titleChunk)
                .flatMap { URL(string: decodeEntities($0.trimmingCharacters(in: .whitespaces))) }
            let number = stripTags(firstGroup(#"<span class="unit-number-right">([\s\S]*?)</span>"#, titleChunk) ?? "")
            let name = stripTags(titleChunk
                .replacingOccurrences(of: #"<span class="unit-image"[\s\S]*?</span>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<span class="unit-number-right">[\s\S]*?</span>"#, with: "", options: .regularExpression))

            // 单元内容：从 unit-content 起到块尾；顺序扫描分组头 / 课时链接
            let contentStart = chunk.range(of: "unit-content")?.upperBound ?? chunk.startIndex
            let content = String(chunk[contentStart...])
            var sections: [ClassSection] = []
            var currentTitle = ""
            var currentLessons: [ClassLesson] = []

            func flushSection() {
                if !currentLessons.isEmpty {
                    sections.append(ClassSection(title: currentTitle.isEmpty ? "Lessons" : currentTitle,
                                                 lessons: currentLessons))
                    currentLessons = []
                }
            }

            let tokenPattern = #"<div class="category-header"><h4>([\s\S]*?)</h4></div>|<a href="/sunshine/lesson/(\d+)/(\d+)"[^>]*class="lesson-link"#
            for m in matches(tokenPattern, in: content) {
                if let sectionTitle = m[1] {
                    flushSection()
                    currentTitle = stripTags(String(sectionTitle))
                } else if let cid = m[2], let lid = m[3] {
                    // 课时块从链接起点到下一个 token（分组头/下一课时），避免吞掉下一分组头
                    let linkStart = m.full.startIndex
                    let linkEnd: String.Index
                    if let next = content.range(of: tokenPattern, options: .regularExpression,
                                                range: m.full.endIndex..<content.endIndex)?.lowerBound {
                        linkEnd = next
                    } else {
                        linkEnd = content.endIndex
                    }
                    let lessonChunk = String(content[linkStart..<linkEnd])
                    let statusClass = firstGroup(#"class="lesson-status ([^"]*)""#, lessonChunk) ?? ""
                    let status = stripTags(firstGroup(#"data-tippy-content="([^"]*)""#, lessonChunk) ?? "")
                    let num = stripTags(firstGroup(#"<span class="lessonnum">([\s\S]*?)</span>"#, lessonChunk) ?? "")
                    let title = stripTags(firstGroup(#"<span class="lesson-title"><span class="lessonnum">[\s\S]*?</span>([\s\S]*?)</span>"#, lessonChunk) ?? "")
                    currentLessons.append(ClassLesson(
                        id: String(lid),
                        courseId: String(cid),
                        number: num,
                        title: title,
                        status: status,
                        hasExercises: statusClass.contains("has-exercises")
                    ))
                }
            }
            flushSection()

            units.append(ClassUnit(id: firstGroup(##"href="#unit(\d+)""##, chunk) ?? String(i),
                                   name: name.isEmpty ? "Unit \(i + 1)" : name,
                                   number: number,
                                   imageURL: imageURL,
                                   sections: sections))
        }
        return ClassCourse(className: className, courseName: courseName,
                           courseLibraryId: courseLibraryId, units: units)
    }
}

// MARK: - 7. 练习（/sunshine/exercise/{ssi} AJAX 片段）
//
// 页面结构（2026-09-29 抓取样本 ssi=4419）：
//   <form action="/process.php" id="exercise_4419">
//     <div id="exercise">
//       <h1 class="page-title">1-1 Alphabet (Aa - Zz)</h1>
//       <div id="119463" class="question" display-type="group" question-type="6">  ← 题干
//         <div class="group"><p><span class="number">1)</span> Match the picture to the letter.</p></div>
//       </div>
//       <div id="119467" display-type="dropdown" class="question" question-type="2">  ← 下拉子题
//         <div class="dropdown">
//           <div class="question-image"><figure><div class="figimg" style="background-image: url('...ex-119467.png')"></div></figure></div>
//           <div class="question-block"><p><span class="number">a.</span><span class="answer"><select name="q119467">
//             <option></option><option value="qa235159">Aa</option>...</select></span></p>
//           <span class="option">Aa</span> ...</div>
//         </div>
//       </div> × N
//     </div>
//     <input type="hidden" name="exercise_id" value="4419" /> / user_id / status / result_id / assign_results_comment
//   </form>
//   提交（站点 JS）：POST /json/exercise_save.php，serialize 整表单；
//   Submit 时 status=1；Save 响应体为新 result_id。
//   老师未分享时片段为 <div class="alert info">…No Access…</div>，无 question 块。

extension SMRTHTMLParser {

    /// 解析练习片段。未分享（No Access）或无下拉题时 questions 为空。
    static func parseExercise(html: String, ssi: String) -> ExerciseData {
        let title = stripTags(firstGroup(#"<h1 class="page-title">([\s\S]*?)</h1>"#, html) ?? "")
        let exerciseRegion = region(after: "id=\"exercise\"", until: "</form>", in: html)

        // 题干：display-type="group" 块内的段落文本
        var instruction = ""
        if let groupChunk = html.range(of: "display-type=\"group\"") {
            let tail = String(html[groupChunk.upperBound...])
            if let end = tail.range(of: "display-type=\"dropdown\"")?.lowerBound {
                instruction = stripTags(firstGroup(#"<p[^>]*>([\s\S]*?)</p>"#, String(tail[..<end])) ?? "")
            }
        }

        // 子题：按完整开标签 <div id="119467" display-type="dropdown" ...> 切块，
        // 保证块内 id / 题图 / select 同属一题
        var questions: [ExerciseQuestion] = []
        let tagPattern = #"<div id="(\d+)" display-type="dropdown""#
        let tagMatches = matches(tagPattern, in: exerciseRegion)
        for (i, m) in tagMatches.enumerated() {
            let start = m.full.startIndex
            let end = i + 1 < tagMatches.count ? tagMatches[i + 1].full.startIndex : exerciseRegion.endIndex
            let chunk = String(exerciseRegion[start..<end])
            guard let qid = m[1] else { continue }
            let number = stripTags(firstGroup(#"<span class="number">([^<]*)</span>"#, chunk) ?? "")
            let image = firstGroup(#"class="figimg"[^>]*background-image:\s*url\('([^']+)'\)"#, chunk)
                .flatMap { URL(string: decodeEntities($0)) }
            let options = matches(#"<option value="(qa\d+)">([\s\S]*?)</option>"#, in: chunk)
                .compactMap { m -> ExerciseOption? in
                    guard let v = m[1], let label = m[2] else { return nil }
                    return ExerciseOption(value: String(v), label: stripTags(String(label)))
                }
            if !options.isEmpty {
                questions.append(ExerciseQuestion(id: String(qid), number: number, imageURL: image, options: options))
            }
        }

        let hidden = ExerciseHidden(
            exerciseId: firstGroup(#"name="exercise_id" value="([^"]*)""#, html) ?? ssi,
            userId: firstGroup(#"name="user_id" value="([^"]*)""#, html) ?? "",
            status: firstGroup(#"name="status" value="([^"]*)""#, html) ?? "0",
            resultId: firstGroup(#"name="result_id" value="([^"]*)""#, html) ?? "",
            comment: firstGroup(#"name="assign_results_comment" value="([^"]*)""#, html) ?? ""
        )

        return ExerciseData(ssi: ssi, title: title, instruction: instruction,
                            questions: questions, hidden: hidden)
    }
}
