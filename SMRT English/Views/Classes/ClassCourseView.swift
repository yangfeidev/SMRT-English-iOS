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

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch selectedTab {
                case .course:
                    ZStack {
                        Theme.background.ignoresSafeArea()
                        courseContent
                    }
                case .classList:
                    ClassListTabView(classId: klass.id)
                case .attendance:
                    AttendanceTabView(classId: klass.id)
                case .assignments:
                    AssignmentsTabView(classId: klass.id)
                case .assessments:
                    AssessmentsTabView(classId: klass.id)
                case .classInfo:
                    ClassInfoTabView(classId: klass.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(klass.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if selectedTab == .course, course == nil { await load() }
        }
        .onChange(of: selectedTab) { tab in
            // 切回 Course 且无数据（如上次加载失败）时补拉
            if tab == .course, course == nil, !isLoading {
                Task { await load() }
            }
        }
    }

    // MARK: - 子 Tab 栏

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClassTab.allCases) { tab in
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
                .padding(.horizontal, 16)
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
