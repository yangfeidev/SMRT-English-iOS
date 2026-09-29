//
//  ClassesView.swift
//  SMRT English
//
//  我的班级页（第三个 Tab，对齐官网 /sunshine/classes）
//  - 标题栏：My Classes + 右上角头像按钮（进入 Me 页，对齐官网右上角头像下拉）
//  - 班级卡片：班级名 + 课程 pill + 成员头像列表，点击进原生班级课程页（ClassCourseView）
//  - Join a Class 卡片：add_box 图标 + 文案，点击打开官网 Classes 页弹窗
//    （官网 join-class-modal 由前端注入，App 内以带登录态的 WebView 承载）
//  - 数据：SMRTClient.myClasses() 抓取登录态 HTML 解析（新账号无班级为正常态）
//

import SwiftUI
import Kingfisher
import os

struct ClassesView: View {
    private static let log = Logger(subsystem: "com.yangfei.smrtenglish", category: "ClassesView")

    @State private var classes: [StudentClass] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showJoinSheet = false
    /// 当前登录账号显示名（中式「姓+名」，如 杨谨灿），用于在成员列表中标记自己
    @State private var myDisplayName: String?

    var body: some View {
        CompatNavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showJoinSheet) {
                CompatNavigationStack {
                    WebPageScreen(
                        title: "Join a Class",
                        url: SMRTClient.shared.baseURL.appendingPathComponent("/sunshine/classes")
                    )
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showJoinSheet = false }
                        }
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            // 全屏登录页登录成功后自动刷新班级数据
            .onReceive(NotificationCenter.default.publisher(for: .smrtSessionRestored)) { _ in
                Task { await load() }
            }
        }
    }

    // MARK: - 标题栏

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("My Classes")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 12)

            // 头像入口：对齐官网右上角头像 → Me 页（账号信息 / 退出登录）
            NavigationLink {
                ProfileView()
            } label: {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("classes.profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if isLoading && classes.isEmpty {
            Spacer()
            ProgressView("加载中…")
            Spacer()
        } else if let errorMessage {
            Spacer()
            errorView(errorMessage)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(classes) { klass in
                        NavigationLink(destination: ClassCourseView(klass: klass)) {
                            classCard(klass)
                        }
                        .buttonStyle(.plain)
                    }

                    // Join a Class：官网空态卡片（add_box + 文案）。
                    // 仅无班级时显示——已有班级后官网本就不渲染 join 弹窗（实测点击无效），入口随之隐藏
                    if classes.isEmpty {
                        Button {
                            showJoinSheet = true
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "plus.square.dashed")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(Theme.textSecondary)
                                Text("Join a Class")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 150)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Theme.textSecondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6]))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("classes.join")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    /// 班级卡片：班级名 + 课程 pill + 成员头像列表（对齐官网 classblock 结构）
    private func classCard(_ klass: StudentClass) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(klass.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)

            if !klass.course.isEmpty {
                Text(klass.course)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12))
                    .foregroundStyle(Theme.accent)
                    .clipShape(Capsule())
            }

            if !klass.members.isEmpty {
                memberGrid(klass.members)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
    }

    /// 成员列表：圆形头像（首字兜底）+ 名字，自适应列宽网格（官网 4 列/行）；
    /// 当前登录账号高亮 + 「我」徽标
    private func memberGrid(_ members: [ClassMember]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 64), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(members) { member in
                let isSelf = myDisplayName != nil && member.name == myDisplayName
                VStack(spacing: 4) {
                    KFImage(member.avatarURL)
                        .resizable()
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 88, height: 88)))
                        .placeholder {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(isSelf ? 0.22 : 0.12))
                                Text(String(member.name.prefix(1)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .fade(duration: 0.25)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(isSelf ? Theme.accent.opacity(0.7) : Theme.accent.opacity(0.12),
                                        lineWidth: isSelf ? 2 : 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelf {
                                Text("我")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .background(Color(hex: 0x64B5F6))
                                    .clipShape(Capsule())
                                    .offset(x: 5, y: -4)
                            }
                        }

                    Text(member.name)
                        .font(.caption2.weight(isSelf ? .bold : .regular))
                        .foregroundStyle(isSelf ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            classes = try await SMRTClient.shared.myClasses()
            Self.log.info("loaded \(classes.count) classes")
        } catch {
            if error.isCancellation { return }
            classes = []
            errorMessage = error.localizedDescription
            Self.log.error("load classes failed: \(error.localizedDescription, privacy: .public)")
        }
        // 显示名独立 best-effort 拉取：失败时回退缓存，不影响班级列表展示
        myDisplayName = await SMRTClient.shared.refreshMyDisplayName()
    }
}

// MARK: - 网页承载页（班级课程页 / 官网页面）

/// 用内嵌 WKWebView 打开官网页面；syncCookies 保证登录态带入
struct WebPageScreen: View {
    let title: String
    let url: URL

    var body: some View {
        WebViewRepresentable(url: url, syncCookies: true)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
