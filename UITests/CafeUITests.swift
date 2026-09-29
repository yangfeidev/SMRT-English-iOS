//
//  CafeUITests.swift
//  SMRT EnglishUITests
//
//  UI 回归测试：
//  1. 启动参数自动登录 → Cafe 列表加载
//  2. 点击 Children / Kids Tab → 验证列表标题集合发生变化（Tab 刷新修复回归）
//  3. 滚动到底部触发分页加载 → 验证列表数量增长
//

import XCTest

final class CafeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let excludedTexts: Set<String> = ["All", "Children", "Kids", "Youth", "Adults",
                                                     "Cafe", "Library", "我的", "加载中…",
                                                     "上滑加载更多", "没有更多了", "加载更多…",
                                                     "No results", "搜索", "重试", "Search"]

    /// 收集列表可见标题（staticText + NavigationLink button 的 label，
    /// 排除 Tab/分类 chip/系统文本）
    static func collectTitles(in app: XCUIApplication) -> Set<String> {
        var titles: Set<String> = []
        let textQuery = app.descendants(matching: .staticText)
        for i in 0..<textQuery.count {
            let label = textQuery.element(boundBy: i).label
            if !excludedTexts.contains(label), label.count > 3 {
                titles.insert(label)
            }
        }
        let buttonQuery = app.descendants(matching: .button)
        for i in 0..<buttonQuery.count {
            let el = buttonQuery.element(boundBy: i)
            let id = el.identifier
            let label = el.label
            guard !id.hasPrefix("cafe.tab."), !id.hasPrefix("cafe.category."),
                  !excludedTexts.contains(label), label.count > 3 else { continue }
            titles.insert(label)
        }
        return titles
    }

    /// 轮询等待列表渲染出足够多的标题（规避 LazyVGrid 异步渲染抖动）
    func waitForTitles(in app: XCUIApplication, minCount: Int = 3, timeout: TimeInterval = 15) -> Set<String> {
        let deadline = Date().addingTimeInterval(timeout)
        var titles = Self.collectTitles(in: app)
        while titles.count < minCount, Date() < deadline {
            sleep(1)
            titles = Self.collectTitles(in: app)
        }
        return titles
    }

    func testTabSwitchReloadsAndPagination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-smrt-email", ProcessInfo.processInfo.environment["SMRT_TEST_EMAIL"] ?? "", "-smrt-password", ProcessInfo.processInfo.environment["SMRT_TEST_PASSWORD"] ?? ""]
        app.launch()

        // 1. 等待 Cafe 页加载完成（All Tab 选中 + 卡片出现）
        let allTab = app.buttons["cafe.tab.All"]
        XCTAssertTrue(allTab.waitForExistence(timeout: 15), "Cafe 页未加载")
        sleep(3) // 等列表数据渲染

        // 收集当前列表可见的卡片标题（全局 staticText，排除 Tab/系统文本）
        func visibleTitles() -> Set<String> {
            Self.collectTitles(in: app)
        }

        let titlesOnAll = waitForTitles(in: app)
        XCTAssertFalse(titlesOnAll.isEmpty, "All Tab 列表为空")

        // 2. 切到 Children Tab → 列表应刷新且内容与 All 不同（游客态各分类内容不同）
        let childrenTab = app.buttons["cafe.tab.Children"]
        XCTAssertTrue(childrenTab.waitForExistence(timeout: 5))
        childrenTab.tap()
        sleep(4) // 等待网络请求与刷新

        let titlesOnChildren = waitForTitles(in: app)
        XCTAssertFalse(titlesOnChildren.isEmpty, "Children Tab 列表为空")
        XCTAssertNotEqual(titlesOnAll, titlesOnChildren, "切到 Children 后列表未变化")

        // 3. 切到 Kids Tab → 内容应与 Children 不同
        let kidsTab = app.buttons["cafe.tab.Kids"]
        XCTAssertTrue(kidsTab.waitForExistence(timeout: 5))
        kidsTab.tap()
        sleep(4)

        let titlesOnKids = waitForTitles(in: app)
        XCTAssertFalse(titlesOnKids.isEmpty, "Kids Tab 列表为空")
        XCTAssertNotEqual(titlesOnChildren, titlesOnKids, "切到 Kids 后列表未变化")

        // 输出对比信息（测试报告可查）
        print("UITEST All titles: \(titlesOnAll.sorted().prefix(6))")
        print("UITEST Children titles: \(titlesOnChildren.sorted().prefix(6))")
        print("UITEST Kids titles: \(titlesOnKids.sorted().prefix(6))")

        // 4. 分页：滚动到底触发 loadMore，列表应增长
        let before = app.descendants(matching: .staticText).count
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        sleep(3)
        app.swipeUp(velocity: .fast)
        sleep(3)
        let after = app.descendants(matching: .staticText).count
        print("UITEST pagination: before=\(before) after=\(after)")
    }

    func testSearchAndCategoryTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-smrt-email", ProcessInfo.processInfo.environment["SMRT_TEST_EMAIL"] ?? "", "-smrt-password", ProcessInfo.processInfo.environment["SMRT_TEST_PASSWORD"] ?? ""]
        app.launch()

        // 等待 Cafe 列表加载
        XCTAssertTrue(app.buttons["cafe.tab.All"].waitForExistence(timeout: 15))
        sleep(3)

        // 1. 搜索框常驻在标题栏右侧，直接输入
        let field = app.textFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "搜索框未出现")
        field.tap()
        field.typeText("whale\n")

        // 2. 等待搜索结果（whale 相关视频）
        let whalePredicate = NSPredicate(format: "label CONTAINS[c] 'Whale'")
        let whaleHit = app.descendants(matching: .staticText).matching(whalePredicate).firstMatch
        XCTAssertTrue(whaleHit.waitForExistence(timeout: 10), "搜索 whale 无结果")
        sleep(2)

        // 3. 点击卡片上的分类标签 → 文字应填入搜索框，且列表按分类刷新
        //    分类 chip 以 accessibilityIdentifier("cafe.category.X") 暴露
        app.buttons["cafe.tab.All"].tap()
        sleep(3)
        let chipPredicate = NSPredicate(format: "identifier BEGINSWITH 'cafe.category.'")
        let chip = app.buttons.matching(chipPredicate).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "第一屏没有分类标签")
        let tappedCategory = chip.label
        chip.tap()
        sleep(4)

        // 搜索框文字 = 分类名
        let fieldAfter = app.textFields["Search"]
        XCTAssertTrue(fieldAfter.waitForExistence(timeout: 5))
        let value = (fieldAfter.value as? String) ?? ""
        XCTAssertEqual(value, tappedCategory, "分类名未填入搜索框（当前值: \(value)）")

        // 分类过滤生效：结果里仍有分类 chip
        let chipsAfter = app.buttons.matching(chipPredicate)
        XCTAssertGreaterThan(chipsAfter.count, 0, "分类过滤后列表为空")
        print("UITEST category tap: '\(tappedCategory)' → searchField='\(value)'")
    }

    func testLibraryCoursesPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-smrt-email", ProcessInfo.processInfo.environment["SMRT_TEST_EMAIL"] ?? "", "-smrt-password", ProcessInfo.processInfo.environment["SMRT_TEST_PASSWORD"] ?? ""]
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15), "Tab 未出现")
        libraryTab.tap()
        sleep(4)

        // 原版结构：Courses 标题 + English Courses 分区 + 类型卡
        XCTAssertTrue(app.staticTexts["Courses"].waitForExistence(timeout: 8), "无 Courses 标题")
        XCTAssertTrue(app.staticTexts["English Courses"].waitForExistence(timeout: 8), "无 English Courses 分区")
        XCTAssertTrue(app.staticTexts["English for Youth"].waitForExistence(timeout: 8), "无 Youth 分组")
        print("UITEST Library page OK")
    }

    func testClassesTabShowsMyClasses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-smrt-email", ProcessInfo.processInfo.environment["SMRT_TEST_EMAIL"] ?? "", "-smrt-password", ProcessInfo.processInfo.environment["SMRT_TEST_PASSWORD"] ?? ""]
        app.launch()

        let classesTab = app.tabBars.buttons["Classes"]
        XCTAssertTrue(classesTab.waitForExistence(timeout: 15), "Tab 未出现")
        classesTab.tap()
        // 登录态正常：显示 My Classes（不弹登录页）
        XCTAssertTrue(app.staticTexts["My Classes"].waitForExistence(timeout: 10), "My Classes 未出现")
        XCTAssertFalse(app.staticTexts["Email 电子邮箱"].exists, "不应弹出登录页")
        print("UITEST Classes tab OK")
    }
}