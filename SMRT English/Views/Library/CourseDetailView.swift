//
//  CourseDetailView.swift
//  SMRT English
//
//  课程详情页（单元树）
//  - 顶部课程封面横幅
//  - 单元列表：单元头（封面 + 名称 + 序号）→ 分组（Conversation and Practice / Reading …）
//    → 课时条目（编号 + 标题），点击进入课时详情
//

import SwiftUI
import Kingfisher

struct CourseDetailView: View {
    let course: LibraryCourse

    @State private var units: [CourseUnit] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    banner

                    if isLoading && units.isEmpty {
                        HStack {
                            Spacer(); ProgressView(); Spacer()
                        }
                        .padding(.top, 60)
                    } else if let errorMessage, units.isEmpty {
                        VStack(spacing: 12) {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            Button("重试") { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(units) { unit in
                            unitSection(unit)
                        }
                    }
                }
            .padding(.bottom, 24)
            .centeredContent(maxWidth: 760)
            }
        }
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 封面横幅

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            KFImage(course.imageURL)
                .resizable()
                .placeholder {
                    Rectangle().fill(Theme.accentGradient)
                }
                .fade(duration: 0.25)
                .aspectRatio(contentMode: .fill)
            .frame(height: 140)
            .clipped()
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(course.title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    if !course.code.isEmpty {
                        Text(course.code)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.9))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }
                }
                Text(course.courseDescription)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }

    // MARK: - 单元区块

    private func unitSection(_ unit: CourseUnit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 单元头
            HStack(spacing: 12) {
                KFImage(unit.imageURL)
                    .resizable()
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 144, height: 108)))
                    .placeholder {
                        Rectangle().fill(Theme.accent.opacity(0.2))
                            .overlay { Image(systemName: "number.square").foregroundStyle(Theme.accent) }
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(unit.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Unit \(unit.number)")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            .padding(12)
            .cardStyle()
            .padding(.horizontal, 16)

            // 分组 + 课时
            ForEach(unit.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 6)

                    ForEach(section.lessons) { lesson in
                        if lesson.locked {
                            LessonRow(lesson: lesson)
                        } else {
                            NavigationLink(destination: LessonDetailView(course: course, lesson: lesson)) {
                                LessonRow(lesson: lesson)
                            }
                            .buttonStyle(.plain)
                            // 点击瞬间预取：转场期间完成下载+解析，push 进来秒开
                            .simultaneousGesture(TapGesture().onEnded {
                                SMRTClient.shared.prefetchLesson(courseId: course.id, lessonId: lesson.id)
                            })
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            units = try await SMRTClient.shared.courseUnits(courseId: course.id)
        } catch {
            if error.isCancellation { return }
            units = []
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 课时行

struct LessonRow: View {
    let lesson: LessonItem

    var body: some View {
        HStack(spacing: 12) {
            Text(lesson.number)
                .font(.caption.bold())
                .foregroundStyle(lesson.locked ? Theme.textSecondary.opacity(0.6) : Theme.accent)
                .frame(minWidth: 34)
                .padding(.vertical, 6)
                .background(lesson.locked ? Color(.systemGray5) : Theme.accent.opacity(0.1))
                .clipShape(Capsule())

            Text(lesson.title)
                .font(.subheadline)
                .foregroundStyle(lesson.locked ? Theme.textSecondary.opacity(0.6) : Theme.textPrimary)
                .multilineTextAlignment(.leading)

            Spacer()

            if lesson.locked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }
}
