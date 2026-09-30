//
//  ClassCourseView.swift
//  SMRT English
//
//  班级课程页（对齐官网 /sunshine/class/{id}/course/ 的 Course tab）
//  - 数据：SMRTClient.classCourse(classId:) 抓取登录态 HTML 解析
//  - 头部：课程名（点击回 Classes 列表，官网同款）+ 班级名
//  - 单元树：手风琴（单元头=封面图+单元名+序号；展开=分组+课时行）
//    课时行含练习/共享状态（官网 lesson-status：In Progress / Lesson only / Not shared）
//  - 点击课时 → 原生 LessonDetailView（课时内容 + Exercises 练习深链已支持）
//  - 子 tab（Class List / Attendance / Assignments / Assessments / Class Info）
//    本轮未做，仅渲染 Course 主内容
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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle(klass.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
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
