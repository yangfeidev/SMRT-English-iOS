//
//  TeacherDebugUITests.swift
//  SMRT EnglishUITests
//
//  教师端 WebView 承载页布局排查（2026-10-08 深夜自主修复用）：
//  基于模拟器已有教师登录态，自动导航到各子 Tab，测试内 sleep 留出
//  外部 simctl 截图窗口；截图由后台循环采集，测试只负责走到页面。
//

import XCTest

final class TeacherDebugUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func launchAndOpenClass() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let classesTab = app.tabBars.buttons["Classes"].firstMatch
        XCTAssertTrue(classesTab.waitForExistence(timeout: 30), "Tab 未出现（登录态丢失？）")
        classesTab.tap()
        sleep(3)

        let classCard = app.staticTexts["EE1段周一班EE1上半年"]
        XCTAssertTrue(classCard.waitForExistence(timeout: 15), "班级卡未出现")
        classCard.tap()
        sleep(3)
        return app
    }

    /// Attendance 竖屏（1024 固定视口布局排查）
    func testAAAttendancePortrait() throws {
        let app = launchAndOpenClass()
        let tab = app.buttons["class.tab.Attendance"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        sleep(14)
    }

    /// Assignments 竖屏
    func testABAssignmentsPortrait() throws {
        let app = launchAndOpenClass()
        let tab = app.buttons["class.tab.Assignments"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        sleep(14)
    }

    /// Attendance 横屏 + 横屏互切 Assignments（保持横屏回归）
    func testACAttendanceLandscapeAndSwitch() throws {
        let app = launchAndOpenClass()
        let tab = app.buttons["class.tab.Attendance"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        sleep(10)

        let rotate = app.buttons["teacher.rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "旋转按钮未出现")
        rotate.tap()
        sleep(8) // 横屏 Attendance 截图窗口

        // 横屏切 Assignments 应保持横屏（紧凑顶栏 tab 可点）
        let assignments = app.buttons["class.tab.Assignments"]
        XCTAssertTrue(assignments.waitForExistence(timeout: 5), "横屏紧凑顶栏 tab 未出现")
        assignments.tap()
        sleep(10) // 横屏 Assignments 截图窗口

        // 切回 Attendance 再旋转回竖屏
        let attendance = app.buttons["class.tab.Attendance"]
        XCTAssertTrue(attendance.waitForExistence(timeout: 5))
        attendance.tap()
        sleep(3)
        app.buttons["teacher.rotate"].tap()
        sleep(5)
    }

    /// 把顶部胶囊 tab 栏拖到最右（7 个 tab 溢出屏幕，Assessments/Gradebook 需先滚出）
    private func scrollTabBarToEnd(_ app: XCUIApplication) {
        // 用窗口坐标从右往左拖（元素坐标对屏外元素无效）
        let win = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = win.withOffset(CGVector(dx: 350, dy: 146))
        let end = win.withOffset(CGVector(dx: 20, dy: 146))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
        }
    }

    /// 学生侧占位 WebView 页（教师号下渲染教师视图）：Assessments / Gradebook
    func testADAssessmentsGradebook() throws {
        let app = launchAndOpenClass()
        scrollTabBarToEnd(app)
        for name in ["Assessments", "Gradebook"] {
            let tab = app.buttons["class.tab.\(name)"]
            if tab.waitForExistence(timeout: 8) {
                tab.tap()
                sleep(10)
            }
        }
    }

    /// WebView 内跳转后返回：应 goBack 回本页，而非整体退出班级页
    func testAEWebViewInnerBack() throws {
        let app = launchAndOpenClass()
        let tab = app.buttons["class.tab.Assignments"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        sleep(10)

        // 点击屏内的作业标题链接（WebView 内部跳转到作业/课时子页）；
        // Class Results 等操作按钮在 Actions 列（屏外，WebKit accessibility
        // 不暴露离屏元素），不适合做内跳入口
        let titleLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '1-4 Dialogue A'"))
            .firstMatch
        if titleLink.waitForExistence(timeout: 8) {
            titleLink.tap()
            sleep(6)

            // 点自定义返回钮：应 goBack 回 Assignments，班级页未退出
            let back = app.buttons["class.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "返回钮未出现")
            back.tap()
            sleep(4)
            XCTAssertTrue(app.buttons["class.tab.Assignments"].exists,
                          "goBack 后仍在班级页")

            // 再点返回：无更多历史，应退出班级页回到 Classes 列表
            app.buttons["class.back"].firstMatch.tap()
            sleep(4)
            XCTAssertFalse(app.buttons["class.tab.Assignments"].exists,
                           "无历史时返回应退出班级页")
        } else {
            print("UITEST no Class Results link (页面无可跳转行), skip")
        }
    }
}
