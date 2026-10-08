//
//  LibraryView.swift
//  SMRT English
//
//  Library 首页（严格按原版 /sunshine/library 纵向结构）：
//  - 顶部标题 Courses
//  - "English Courses" 分区：横滑类型卡（English for Youth / Kids / Children，封面图+文字叠加）
//  - 各类型分组分区：标题（English for Youth…）+ 横滑课程封面卡，点击进课程详情
//  - 类型卡点击 → 课程列表页（?s={type}，带标题/描述的课程卡）
//

import SwiftUI
import Kingfisher

struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var home: LibraryHome?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Courses")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await load() }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading && home == nil {
            Spacer()
            ProgressView("加载中…")
            Spacer()
        } else if let errorMessage, home == nil {
            Spacer()
            VStack(spacing: 12) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        } else if let home {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // English Courses 类型卡（横滑）
                    sectionHeader("English Courses")
                    typeCards(home.types)

                    // 各类型分组（横滑课程封面卡）
                    ForEach(home.groups) { group in
                        sectionHeader(group.title)
                        courseCards(group)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
    }

    // MARK: - English Courses 类型卡（横滑）

    private func typeCards(_ types: [LibraryTypeCard]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(types) { type in
                    NavigationLink(destination: CourseListScreen(typeCard: type)) {
                        ZStack(alignment: .bottomLeading) {
                            KFImage(type.imageURL)
                                .resizable()
                                .placeholder {
                                    Rectangle().fill(Theme.accent.opacity(0.2))
                                        .overlay { Image(systemName: "graduationcap").foregroundStyle(Theme.accent) }
                                }
                                .fade(duration: 0.25)
                                .aspectRatio(contentMode: .fill)
                            .frame(width: hSizeClass == .regular ? 320 : 250,
                                   height: hSizeClass == .regular ? 210 : 170)
                            .clipped()
                            .overlay {
                                LinearGradient(colors: [.clear, .black.opacity(0.45)],
                                               startPoint: .center, endPoint: .bottom)
                            }
                            Text(type.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 分组课程封面卡（横滑）

    private func courseCards(_ group: LibraryGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(group.courses) { course in
                    NavigationLink(destination: CourseDetailView(course: LibraryCourse(
                        id: course.id, title: "", code: "",
                        courseDescription: "", imageURL: course.imageURL
                    ))) {
                        KFImage(course.imageURL)
                            .resizable()
                            .placeholder {
                                Rectangle().fill(Color(.systemGray5))
                                    .overlay { Image(systemName: "book").foregroundStyle(Theme.textSecondary) }
                            }
                            .fade(duration: 0.25)
                            .aspectRatio(contentMode: .fill)
                        .frame(width: hSizeClass == .regular ? 200 : 150,
                                   height: hSizeClass == .regular ? 250 : 195)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 5, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            home = try await SMRTClient.shared.libraryHome()
        } catch {
            if error.isCancellation { return }
            home = nil
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 类型课程列表页（?s={type}，原版点击类型卡进入）

struct CourseListScreen: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    let typeCard: LibraryTypeCard

    @State private var courses: [LibraryCourse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// 列数自适应：iPhone 2 列，iPad（regular）3 列
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14),
              count: hSizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading && courses.isEmpty {
                Spacer(); ProgressView("加载中…"); Spacer()
            } else if let errorMessage, courses.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(courses) { course in
                            NavigationLink(destination: CourseDetailView(course: course)) {
                                CourseCard(course: course)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(typeCard.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            courses = try await SMRTClient.shared.courses(type: .init(rawValue: typeCard.key) ?? .youth)
        } catch {
            if error.isCancellation { return }
            courses = []
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 课程卡片（?s= 列表页用，含标题/描述）

struct CourseCard: View {
    let course: LibraryCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                KFImage(course.imageURL)
                    .resizable()
                    .placeholder {
                        Rectangle()
                            .fill(Theme.accent.opacity(0.15))
                            .overlay {
                                Image(systemName: "graduationcap")
                                    .font(.largeTitle)
                                    .foregroundStyle(Theme.accent)
                            }
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipped()

                if !course.code.isEmpty {
                    Text(course.code)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accentGradient)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(course.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(course.courseDescription)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
