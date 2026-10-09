//
//  ClassCourseView.swift
//  SMRT English
//
//  班级课程页（对齐官网 /sunshine/class/{id}/ 的 6 个子页面）
//  - 顶部 Tab：Course / Class List / Attendance / Assignments / Assessments / Class Info
//    （对应官网左侧菜单；注意 Assessments 的官网路径是 evaluation）
//  - Course tab：原生实现——SMRTClient.classCourse(classId:) 抓取解析单元树，
//    手风琴（单元头=封面图+单元名+序号；展开=分组+课时行），
//    课时行含练习/共享状态（官网 lesson-status：In Progress / Lesson only / Not shared）
//    点击课时 → 原生 LessonDetailView
//  - 其余 5 个 tab：WebView 登录态承载官网对应页面（低频查看型页面，
//    不做原生解析，跟随官网改版免维护）
//

import SwiftUI
import Kingfisher
import os

struct ClassCourseView: View {
    private static let log = Logger(subsystem: "com.yangfei.smrtenglish", category: "ClassCourseView")

    let klass: StudentClass

    @State private var course: ClassCourse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 展开的单元（官网手风琴默认展开第一个）
    @State private var expandedUnitIDs: Set<String> = []
    /// 当前子 Tab
    @State private var selectedTab: ClassTab = .course
    /// 是否教师端（course 页解析出的侧栏 Gradebook 标记；加载前按学生端展示）
    @State private var isTeacher = false
    /// 横屏状态（教师宽表格页锁横屏时切换紧凑顶栏）
    @ObservedObject private var orientationLock = OrientationLock.shared
    @Environment(\.dismiss) private var dismiss

    /// 可见 tab：教师端多一个 Gradebook（学生端 6 项、教师端 7 项）
    private var visibleTabs: [ClassTab] {
        ClassTab.allCases.filter { $0 != .gradebook || isTeacher }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 横屏：返回按钮与胶囊 tab 合并一行（系统导航栏整条隐藏，
            // 竖向空间让给内容）；竖屏：系统导航栏 + 胶囊 tab 两行
            if orientationLock.landscapeOnly {
                compactTopBar
            } else {
                tabBar
            }
            Group {
                switch selectedTab {
                case .course:
                    ZStack {
                        Theme.background.ignoresSafeArea()
                        courseContent
                    }
                case .classList:
                    if isTeacher {
                        TeacherClassListTabView(classId: klass.id)
                    } else {
                        ClassListTabView(classId: klass.id)
                    }
                case .attendance:
                    if isTeacher {
                        TeacherAttendanceTabView(classId: klass.id)
                    } else {
                        AttendanceTabView(classId: klass.id)
                    }
                case .assignments:
                    if isTeacher {
                        TeacherAssignmentsTabView(classId: klass.id)
                    } else {
                        AssignmentsTabView(classId: klass.id)
                    }
                case .assessments:
                    if isTeacher {
                        TeacherAssessmentsTabView(classId: klass.id)
                    } else {
                        AssessmentsTabView(classId: klass.id)
                    }
                case .gradebook:
                    TeacherGradebookTabView(classId: klass.id)
                case .classInfo:
                    ClassInfoTabView(classId: klass.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(klass.name)
        .navigationBarTitleDisplayMode(.inline)
        // 横屏隐藏系统导航栏（大标题+返回按钮条），由 compactTopBar 的返回按钮接管；
        // 横屏同时隐藏底部 tab bar，显示区域更大
        .toolbar(orientationLock.landscapeOnly ? .hidden : .visible, for: .navigationBar)
        .toolbar(orientationLock.landscapeOnly ? .hidden : .visible, for: .tabBar)
        .task {
            if selectedTab == .course, course == nil { await load() }
        }
        .onDisappear {
            // 离开班级页（返回列表/push 课时详情）恢复竖屏；
            // tab 间互切不在此处（横屏时 Attendance↔Assignments 互切保持横屏）
            if orientationLock.landscapeOnly {
                setInterfaceOrientation(false)
            }
        }
        .onChange(of: selectedTab) { tab in
            // 横屏时切到不支持横屏的 tab（Course/Class List/Assessments/Gradebook）
            // 恢复竖屏；Assignments↔Attendance 互切保持横屏
            if orientationLock.landscapeOnly,
               !(isTeacher && (tab == .assignments || tab == .attendance)) {
                setInterfaceOrientation(false)
            }
        }
        .onChange(of: selectedTab) { tab in
            // 切回 Course 且无数据（如上次加载失败）时补拉
            if tab == .course, course == nil, !isLoading {
                Task { await load() }
            }
        }
    }

    // MARK: - 子 Tab 栏

    /// 竖屏顶栏：系统导航栏（标题+返回）下方单独一行胶囊 tab
    private var tabBar: some View {
        tabScroll(horizontalPadding: 16)
            .background(Theme.background)
    }

    /// 横屏紧凑顶栏：返回按钮与胶囊 tab 合并一行（系统导航栏已隐藏，
    /// 大标题不再显示，竖向空间让给内容）。
    /// 横屏下点返回不直接退出：先恢复竖屏（再点系统返回才真正返回）
    private var compactTopBar: some View {
        HStack(spacing: 10) {
            Button {
                if orientationLock.landscapeOnly {
                    setInterfaceOrientation(false)
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Theme.card)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .accessibilityIdentifier("class.back")

            tabScroll(horizontalPadding: 4)
        }
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    private func tabScroll(horizontalPadding: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleTabs) { tab in
                        let isActive = selectedTab == tab
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.title)
                                .font(.subheadline.weight(isActive ? .bold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(isActive ? Theme.accent : Theme.card)
                                .foregroundStyle(isActive ? .white : Theme.textSecondary)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
                        }
                        .id(tab)
                        .accessibilityIdentifier("class.tab.\(tab.title)")
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedTab) { tab in
                // 点击后把选中的胶囊滚动到视口居中，避免点边缘的 tab 够不着
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(tab, anchor: .center)
                }
            }
        }
        .background(Theme.background)
    }

    // MARK: - Course 内容区（原生）

    @ViewBuilder
    private var courseContent: some View {
        if isLoading && course == nil {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, course == nil {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let course {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(course.courseName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    if course.units.isEmpty {
                        Text("暂无课程内容")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(course.units) { unit in
                            unitCard(unit)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 单元手风琴

    private func unitCard(_ unit: ClassUnit) -> some View {
        let isExpanded = expandedUnitIDs.contains(unit.id)
        return VStack(alignment: .leading, spacing: 0) {
            // 单元头：封面 + 名 + 序号（点击折叠/展开）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedUnitIDs.remove(unit.id)
                    } else {
                        expandedUnitIDs.insert(unit.id)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    unitThumbnail(unit)

                    Text(unit.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 8)

                    Text(unit.number)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.accent.opacity(0.5))

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(unit.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 14)

                            ForEach(section.lessons) { lesson in
                                lessonRow(lesson)
                            }
                        }
                    }
                }
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    private func unitThumbnail(_ unit: ClassUnit) -> some View {
        Group {
            if let url = unit.imageURL {
                KFImage(url)
                    .resizable()
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 104, height: 104)))
                    .placeholder {
                        ZStack {
                            Rectangle().fill(Theme.accent.opacity(0.12))
                            Image(systemName: "book.closed")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Theme.accent.opacity(0.12))
                    Image(systemName: "book.closed")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 课时行

    private func lessonRow(_ lesson: ClassLesson) -> some View {
        NavigationLink {
            LessonDetailView(
                course: LibraryCourse(
                    id: course?.courseLibraryId ?? "",
                    title: course?.courseName ?? "",
                    code: "",
                    courseDescription: "",
                    imageURL: nil
                ),
                lesson: LessonItem(id: lesson.id, courseId: lesson.courseId,
                                   number: lesson.number, title: lesson.title)
            )
        } label: {
            HStack(spacing: 10) {
                Text(lesson.number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 28, alignment: .leading)

                Text(lesson.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                // 状态点+文案（来源：官网 lesson-status 的 tippy 文案）。
                // Complete 高亮：绿色对勾 + 绿字，一眼可辨已完成；
                // 其余状态（In Progress / Lesson only / Not shared）维持灰色系。
                if lesson.status.lowercased().contains("complete") {
                    Label(lesson.status, systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Circle()
                        .fill(lesson.hasExercises ? Theme.accent
                              : lesson.status == "Not shared" ? Theme.textSecondary.opacity(0.35)
                              : Theme.textSecondary.opacity(0.15))
                        .frame(width: 8, height: 8)

                    if !lesson.status.isEmpty {
                        Text(lesson.status)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await SMRTClient.shared.classCourse(classId: klass.id)
            course = result
            isTeacher = result.isTeacher
            // 默认展开第一个单元（官网 accordion 行为）
            if let first = result.units.first {
                expandedUnitIDs = [first.id]
            }
            Self.log.info("loaded class course: \(result.units.count) units")
        } catch {
            if error.isCancellation { return }
            course = nil
            errorMessage = error.localizedDescription
            Self.log.error("load class course failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
