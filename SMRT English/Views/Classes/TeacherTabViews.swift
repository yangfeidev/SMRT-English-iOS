//
//  TeacherTabViews.swift
//  SMRT English
//
//  教师端班级子 Tab 视图（教师号与学生在 classes 各模块的差异页）
//  - Course：原生单元树（ClassCourseView 共用，解析器对教师页同样兼容）
//  - Class List：原生简单列表（官网为表格视图 Current/Removed 两子页）
//  - Assignments / Attendance / Assessments / Gradebook：重交互页面
//    （布置作业多步弹窗 / 点图打卡 / 成绩管理），WebView 登录态承载官网自理；
//    注入 CSS 隐藏站点 chrome——站点 header（logo 长条 + 汉堡菜单）、
//    页面内左侧栏（含手机形态汉堡按钮/班级名/折叠菜单）、footer、
//    h1 大标题、Assessments 右上角圆钮——只留内容信息
//  - Assignments / Attendance 为官网宽表格：固定布局视口（Assignments 992
//    保 Start/Due 列+文字按钮、Attendance 768 保 Ref 列）命中桌面/平板断点，
//    页面 load 后量内容真实宽把视口收缩到 [下限, 1024]（表格收缩后列紧贴
//    内容，消除官网 width:100% 拉满视口产生的列间大空白）；竖屏左右滑动查看；
//    右下角悬浮按钮切横屏（横屏 ClassCourseView 自动切紧凑顶栏）
//

import SwiftUI
import Kingfisher

// MARK: - 教师端 WebView 承载页共用修饰

/// 班级子页 WebView 统一入口：登录态 + 隐藏站点 chrome（只留内容）+
/// 官网西式「名 姓」转中式「姓名」
private struct TeacherPageWebView: View {
    let classId: String
    /// 官网路径段（assignments / attendance / evaluation / gradebook）
    let segment: String
    /// 追加的页面级隐藏 CSS（如 Assessments 的圆钮）
    var extraCSS: String = ""
    /// 固定布局视口宽度（宽表格页传 1024 命中桌面断点，nil = 官网自适应）
    var fixedViewportWidth: CGFloat? = nil
    /// 视口收缩下限（见 WebViewRepresentable.viewportShrinkLowerBound 注释）
    var viewportShrinkLowerBound: CGFloat? = nil
    /// 宽视口显示缩放（0.75 = 内容整体缩小到 75%，手机观感更合适）
    var viewportScale: CGFloat? = nil

    var body: some View {
        WebViewRepresentable(
            url: SMRTClient.shared.baseURL
                .appendingPathComponent("/sunshine/class/\(classId)/\(segment)/"),
            syncCookies: true,
            pageBackgroundColor: .white,
            hideSiteHeader: true,
            extraCSS: WebViewRepresentable.classPageHideChromeCSS + extraCSS,
            fixedViewportWidth: fixedViewportWidth,
            viewportShrinkLowerBound: viewportShrinkLowerBound,
            viewportScale: viewportScale,
            pageLoadJS: WebViewRepresentable.chineseNameNormalizeJS)
    }
}

// MARK: - 横竖屏切换

/// 设置页面方向（配合 AppDelegate/OrientationLock：右下角按钮调用，
/// requestGeometryUpdate 立即旋转无需用户手动转设备）
func setInterfaceOrientation(_ landscape: Bool) {
    OrientationLock.shared.landscapeOnly = landscape
    let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// 教师端宽表格页横竖屏切换：默认竖屏（1024 布局视口左右滚动看完整列），
/// 右下角悬浮按钮点击切横屏（横屏 ClassCourseView 自动切紧凑顶栏+隐藏底部
/// tabbar）；恢复竖屏收敛在 ClassCourseView 的 onDisappear/onChange
/// （不放这里——横屏 Attendance↔Assignments 互切时旧页 onDisappear 会把方向打回竖屏）
private struct TeacherWideTableModifier: ViewModifier {
    @ObservedObject private var orientationLock = OrientationLock.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                Button {
                    setInterfaceOrientation(!orientationLock.landscapeOnly)
                } label: {
                    Image(systemName: orientationLock.landscapeOnly
                          ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.card)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .padding(.bottom, 14)
                .accessibilityIdentifier("teacher.rotate")
            }
    }
}

// MARK: - 教师端 Assignments（三态 tab + 布置/删除/成绩查看，官网自理）

struct TeacherAssignmentsTabView: View {
    let classId: String

    var body: some View {
        TeacherPageWebView(classId: classId, segment: "assignments",
                           extraCSS: WebViewRepresentable.teacherTableShrinkCSS,
                           fixedViewportWidth: 1024,
                           viewportShrinkLowerBound: 992,
                           viewportScale: 0.75)
            .modifier(TeacherWideTableModifier())
    }
}

// MARK: - 教师端 Attendance（点图打卡 / 记录表改状态 / 搜索，官网自理）

struct TeacherAttendanceTabView: View {
    let classId: String

    var body: some View {
        TeacherPageWebView(classId: classId, segment: "attendance",
                           extraCSS: WebViewRepresentable.teacherAttendanceColumnsCSS
                               + WebViewRepresentable.teacherTableShrinkCSS,
                           fixedViewportWidth: 1024,
                           viewportShrinkLowerBound: 768,
                           viewportScale: 0.75)
            .modifier(TeacherWideTableModifier())
    }
}

// MARK: - 教师端 Assessments（测评管理；官网路径是 evaluation）

struct TeacherAssessmentsTabView: View {
    let classId: String

    var body: some View {
        TeacherPageWebView(classId: classId, segment: "evaluation",
                           extraCSS: WebViewRepresentable.classPageHideCircleButtonsCSS)
    }
}

// MARK: - 教师端 Gradebook（成绩册，教师独有第 7 个 tab）

struct TeacherGradebookTabView: View {
    let classId: String

    var body: some View {
        TeacherPageWebView(classId: classId, segment: "gradebook")
    }
}

// MARK: - 教师端 Class List（原生简单列表）

/// 教师端 Class List：与学生端（头像名字网格）不同，官网为表格视图
/// （头像 / 姓名 / Id / Email），含 Current/Removed 两个 ?tab= 子页。
/// 原生简单列表：下划线双 tab（Current 灰色人数 badge）+ 成员行。
struct TeacherClassListTabView: View {
    let classId: String

    /// 子页（官网 ?tab= 值）
    private enum ListTab: String, CaseIterable {
        case current = "current-students"
        case removed = "removed-students"
    }

    @State private var selectedTab: ListTab = .current
    @State private var members: [TeacherClassListMember]?
    @State private var currentCount = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ClassTabPageContainer(load: { await load() },
                              isLoading: $isLoading,
                              errorMessage: $errorMessage) {
            VStack(spacing: 0) {
                tabBar
                if let members {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if members.isEmpty {
                                emptyState(selectedTab == .removed ? "No Removed Students" : "No Students",
                                           icon: "person.2")
                            }
                            ForEach(members) { member in
                                memberRow(member)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .task { if members == nil { await load() } }
    }

    /// 下划线双 tab（Current 灰色数字 badge 对齐官网默认 smrt-badge 样式）
    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(ListTab.allCases, id: \.rawValue) { tab in
                let isActive = tab == selectedTab
                Button {
                    guard tab != selectedTab else { return }
                    selectedTab = tab
                    Task { await load() }
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(tab == .current ? "Current" : "Removed")
                                .font(.subheadline.weight(isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                            if tab == .current, currentCount > 0 {
                                Text("\(currentCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.55))
                                    .clipShape(Capsule())
                            }
                        }
                        Rectangle()
                            .fill(isActive ? Theme.accent : Color.clear)
                            .frame(height: 2.5)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(Theme.background)
    }

    /// 成员行：头像（首字兜底）+ 姓名 + Id/Email
    private func memberRow(_ member: TeacherClassListMember) -> some View {
        HStack(spacing: 12) {
            KFImage(member.avatarURL)
                .resizable()
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 88, height: 88)))
                .placeholder {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.12))
                        Text(String(member.name.prefix(1)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .fade(duration: 0.25)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(member.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if !member.number.isEmpty {
                    Text("Id: \(member.number)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            if !member.email.isEmpty {
                Text(member.email)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = "/sunshine/class/\(classId)/classlist/?tab=\(selectedTab.rawValue)"
            let html = try await SMRTClient.shared.withSessionRecovery {
                try await SMRTClient.shared.getHTML(path: path, requirePathContains: "/sunshine/class/")
            }
            members = await Task.detached(priority: .userInitiated) {
                SMRTHTMLParser.parseTeacherClassList(html: html)
            }.value
            if selectedTab == .current {
                currentCount = members?.count ?? 0
            }
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 通用空态

@ViewBuilder
private func emptyState(_ text: String, icon: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 40))
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 40)
}
