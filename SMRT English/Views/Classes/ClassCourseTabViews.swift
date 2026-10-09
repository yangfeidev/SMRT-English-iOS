//
//  ClassCourseTabViews.swift
//  SMRT English
//
//  班级页子 Tab 的原生视图（对齐官网 /sunshine/class/{id}/ 的子页面）
//  - 每个视图自带懒加载（.task 首次出现时拉取），结构简单均为只读展示
//  - Class List / Assignments / Class Info 原生解析渲染；
//    Attendance / Assessments 学生端改 WebView 承载（见各视图注释）
//

import SwiftUI

// MARK: - 通用加载容器

/// 子 Tab 页通用骨架：加载中 / 错误重试 / 内容
struct ClassTabPageContainer<Content: View>: View {
    let load: () async -> Void
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content()
            }
        }
    }
}

// MARK: - Class List（成员列表）

struct ClassListTabView: View {
    let classId: String

    @State private var members: [String]?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ClassTabPageContainer(load: { await load() },
                              isLoading: $isLoading,
                              errorMessage: $errorMessage) {
            if let members {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(Array(members.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Theme.accent.opacity(0.12))
                                    Text(String(name.prefix(1)))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .frame(width: 36, height: 36)

                                Text(name)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .task { if members == nil { await load() } }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let html = try await SMRTClient.shared.classPageHTML(classId: classId, tab: .classList)
            members = await Task.detached(priority: .userInitiated) {
                SMRTHTMLParser.parseClassListMembers(html: html)
            }.value
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Assignments（作业列表）

struct AssignmentsTabView: View {
    let classId: String

    @State private var items: [ClassAssignment]?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ClassTabPageContainer(load: { await load() },
                              isLoading: $isLoading,
                              errorMessage: $errorMessage) {
            if let items {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { assignment in
                            assignmentRow(assignment)
                        }
                        if items.isEmpty {
                            Text("No Assignments")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .task { if items == nil { await load() } }
    }

    private func assignmentRow(_ a: ClassAssignment) -> some View {
        let row = HStack(spacing: 12) {
            // 状态：Complete 绿色对勾，其余灰色时钟
            if a.status.lowercased().contains("complete") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.green)
            } else {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(a.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                if !a.section.isEmpty {
                    Text(a.section)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !a.dueDate.isEmpty {
                    Text("Due \(a.dueDate)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
            }

            Spacer(minLength: 8)

            if !a.score.isEmpty {
                Text(a.score)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(a.score == "100%" ? Color.green : Theme.accent)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)

        // 有课时链接 → 原生课时详情
        if let path = a.lessonPath,
           let range = path.range(of: #"lesson/(\d+)/(\d+)"#, options: .regularExpression) {
            let parts = path[range].split(separator: "/")
            if parts.count == 3 {
                return AnyView(
                    NavigationLink {
                        LessonDetailView(
                            course: LibraryCourse(id: String(parts[1]), title: "", code: "",
                                                  courseDescription: "", imageURL: nil),
                            lesson: LessonItem(id: String(parts[2]), courseId: String(parts[1]),
                                               number: "", title: a.title)
                        )
                    } label: {
                        row
                    }
                    .buttonStyle(.plain)
                )
            }
        }
        return AnyView(row)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let html = try await SMRTClient.shared.classPageHTML(classId: classId, tab: .assignments)
            items = await Task.detached(priority: .userInitiated) {
                SMRTHTMLParser.parseClassAssignments(html: html)
            }.value
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Attendance（考勤，WebView 承载）

/// 学生端 Attendance：官网按角色返回内容（学生=本人考勤记录），
/// 此前解析器未覆盖记录结构（一直空态占位），改 WebView 登录态承载，
/// 隐藏站点 chrome 只留内容，结构随官网改版免维护
struct AttendanceTabView: View {
    let classId: String
    var navigationState: WebViewNavigationState? = nil

    var body: some View {
        WebViewRepresentable(
            url: SMRTClient.shared.baseURL.appendingPathComponent("/sunshine/class/\(classId)/attendance/"),
            syncCookies: true,
            pageBackgroundColor: .white,
            hideSiteHeader: true,
            extraCSS: WebViewRepresentable.classPageHideChromeCSS,
            navigationState: navigationState,
            pageLoadJS: WebViewRepresentable.chineseNameNormalizeJS)
    }
}

// MARK: - Assessments（测评，WebView 承载）

/// 学生端 Assessments：官网按角色返回内容（学生=本人测评结果），
/// 同 Attendance 改 WebView 承载（官网路径是 evaluation）
struct AssessmentsTabView: View {
    let classId: String
    var navigationState: WebViewNavigationState? = nil

    var body: some View {
        WebViewRepresentable(
            url: SMRTClient.shared.baseURL.appendingPathComponent("/sunshine/class/\(classId)/evaluation/"),
            syncCookies: true,
            pageBackgroundColor: .white,
            hideSiteHeader: true,
            extraCSS: WebViewRepresentable.classPageHideChromeCSS,
            navigationState: navigationState,
            pageLoadJS: WebViewRepresentable.chineseNameNormalizeJS)
    }
}

// MARK: - Class Info（班级信息键值对）

struct ClassInfoTabView: View {
    let classId: String

    @State private var items: [ClassInfoItem]?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ClassTabPageContainer(load: { await load() },
                              isLoading: $isLoading,
                              errorMessage: $errorMessage) {
            if let items {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(item.value)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .task { if items == nil { await load() } }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let html = try await SMRTClient.shared.classPageHTML(classId: classId, tab: .classInfo)
            items = await Task.detached(priority: .userInitiated) {
                SMRTHTMLParser.parseClassInfo(html: html)
            }.value
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}
