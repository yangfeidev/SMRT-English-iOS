//
//  LessonDetailView.swift
//  SMRT English
//
//  课时详情页（WebView 承载官网页面）
//  - 整页 WKWebView 登录态加载官网课时页 /sunshine/lesson/{courseId}/{lessonId}
//  - 课时切换、练习、视频等交互全部由官网页面自理（网页右上角自带课时菜单）
//  - 原生 HTML 解析块方案与顶部自定义切换 chips 均已移除（解析稳定性差，
//    网页自带导航可满足切换需求）
//

import SwiftUI

struct LessonDetailView: View {
    let course: LibraryCourse
    /// 课时条目（title 做导航栏标题，courseId+id 拼 WebView URL）
    let lesson: LessonItem

    /// 官网课时页 URL（Library 与班级课程两个入口的 courseId 都是课程库 id，
    /// 与官网链接一致）
    private var lessonURL: URL {
        SMRTClient.shared.baseURL.appendingPathComponent(
            "sunshine/lesson/\(lesson.courseId)/\(lesson.id)")
    }

    var body: some View {
        WebViewScreen(title: lesson.title) { navState in
            WebViewRepresentable(url: lessonURL,
                                 syncCookies: true,
                                 pageBackgroundColor: .white,
                                 hideSiteHeader: true,
                                 navigationState: navState)
        }
        // 底部不忽略安全区：练习弹窗的进度条/Complete 按钮条是网页内 fixed
        // 定位，视口延伸到 tabbar 下面会被遮挡；止于 tabbar 上沿即可完整显示
    }
}
