//
//  CafeView.swift
//  SMRT English
//
//  Cafe 视频流页面
//  - 顶部分级 Tab（All / Adults / Youth / Kids / Children，沿用官网原版顺序）
//  - 搜索框固定在 Cafe 标题右侧常驻显示，回车后进入搜索 Tab（/cafe/all/search?s=关键词）
//  - 卡片分类标签可点击：点击后分类名填入搜索框并按该分类过滤（与原版一致）
//  - 双列卡片网格 + 滚动到底自动加载下一页（?page=N）
//
//  刷新机制：.task(id: tab.path) 在 Tab/搜索/分类切换时重置分页并重新加载；
//  navigationDestination 挂在稳定节点（ZStack）上，避免条件分支重建导致路由失效。
//

import SwiftUI
import Kingfisher
import os

struct CafeView: View {
    private static let log = Logger(subsystem: "com.yangfei.smrtenglish", category: "CafeView")

    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var tab: CafeTab = .all
    @State private var videos: [CafeVideo] = []
    @State private var currentPage = 1
    @State private var hasNextPage = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    // 搜索
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool

    /// 列数自适应：iPhone 2 列，iPad（regular）4 列
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: hSizeClass == .regular ? 4 : 2)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    levelPicker
                    content
                }
            }
            // 标题栏自绘（Cafe + 搜索框同行），隐藏系统导航栏；
            // 推入的播放页自行显示导航栏与返回按钮，不受影响
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: tab.path) {
            Self.log.info("tab switched → \(tab.path, privacy: .public), reload page 1")
            await load()
        }
    }

    // MARK: - 标题栏（Cafe 标题 + 固定搜索框）

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Cafe")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 12)

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search", text: $searchText)
                .font(.subheadline)
                .focused($searchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { commitSearch() }
            if !searchText.isEmpty {
                Button {
                    // 清空输入框：若当前正停在搜索/分类筛选上，同步清除筛选并刷新列表
                    clearDynamicFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .accessibilityIdentifier("cafe.search.clear")
            } else {
                // 无输入时保留「搜索」提交入口，占位对称
                Button {
                    commitSearch()
                } label: {
                    Text("搜索")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        }
        .frame(maxWidth: 220)
    }

    /// 提交搜索：关键词 → 搜索 Tab
    private func commitSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        searchFieldFocused = false
        tab = .search(keyword)
    }

    /// 点击分类标签：分类名填入搜索框 + 切到分类 Tab（与原版行为一致）
    private func selectCategory(_ category: CafeCategory) {
        searchText = category.name
        searchFieldFocused = false
        tab = .category(category)
    }

    // MARK: - 分级 Tab

    private var levelPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CafeTab.levels, id: \.path) { lv in
                        tabButton(lv)
                            .id(lv.path)
                    }
                    // 搜索/分类 Tab 以胶囊形式追加显示（当前激活）
                    if !CafeTab.levels.contains(where: { $0.path == tab.path }) {
                        tabButton(tab)
                            .id(tab.path)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: tab.path) { path in
                // 选中变化（含点胶囊 ×/搜索/分类）后把选中胶囊滚到视口居中
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(path, anchor: .center)
                }
            }
        }
    }

    private func tabButton(_ lv: CafeTab) -> some View {
        let isActive = tab.path == lv.path
        let isDynamic = !CafeTab.levels.contains(where: { $0.path == lv.path })

        // 固定分级 Tab：整个胶囊一个点击区
        guard isDynamic else {
            return AnyView(
                Button {
                    guard tab.path != lv.path else { return }
                    tab = lv
                } label: {
                    Text(lv.title)
                        .font(.subheadline.weight(isActive ? .bold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isActive ? Theme.accent : Theme.card)
                        .foregroundStyle(isActive ? .white : Theme.textSecondary)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                }
                .accessibilityIdentifier("cafe.tab.\(lv.title)")
            )
        }

        // 动态 Tab（搜索/分类）：文字区 = 切换查看；× 独立点击区 = 清除筛选
        // （原实现 × 只是标签一部分，点击胶囊任何位置都无法清除）
        return AnyView(
            HStack(spacing: 4) {
                Button {
                    tab = lv
                } label: {
                    Text(lv.title)
                        .font(.subheadline.weight(.bold))
                        .padding(.leading, 16)
                        .padding(.vertical, 8)
                }
                .accessibilityIdentifier("cafe.tab.\(lv.title)")

                Button {
                    clearDynamicFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                }
                .accessibilityIdentifier("cafe.tab.close.\(lv.title)")
            }
            .background(isActive ? Theme.accent : Theme.card)
            .foregroundStyle(isActive ? .white : Theme.textSecondary)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }

    /// 清除动态筛选（搜索/分类）：回 All 并刷新列表；搜索关键词同步清空
    private func clearDynamicFilter() {
        searchText = ""
        searchFieldFocused = false
        tab = .all
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if isLoading && videos.isEmpty {
            Spacer()
            ProgressView("加载中…")
            Spacer()
        } else if let errorMessage, videos.isEmpty {
            Spacer()
            errorView(errorMessage)
            Spacer()
        } else if videos.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textSecondary)
                Text("No results")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(videos) { video in
                        CafeVideoCard(video: video) { category in
                            selectCategory(category)
                        }
                        .onAppear {
                            // 滚动到最后一张时加载下一页
                            if video.id == videos.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)

                if hasNextPage {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(isLoadingMore ? "加载更多…" : "上滑加载更多")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 16)
                } else if !videos.isEmpty {
                    Text("没有更多了")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 16)
                }
            }
            .refreshable { await load() }
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

    /// 首屏 / 切 Tab / 搜索：重置分页后加载第 1 页
    private func load() async {
        isLoading = true
        errorMessage = nil
        currentPage = 1
        hasNextPage = true
        defer { isLoading = false }
        do {
            let result = try await SMRTClient.shared.cafeVideos(tab: tab, page: 1)
            videos = result.videos
            hasNextPage = result.hasNext
            Self.log.info("loaded page 1: \(result.videos.count) videos, hasNext=\(result.hasNext)")
        } catch {
            if error.isCancellation { return }
            videos = []
            hasNextPage = false
            errorMessage = error.localizedDescription
            Self.log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 加载下一页并追加（按 id 去重）
    private func loadMore() async {
        guard hasNextPage, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = currentPage + 1
            Self.log.info("loadMore → page \(nextPage)")
            let result = try await SMRTClient.shared.cafeVideos(tab: tab, page: nextPage)
            let existing = Set(videos.map(\.id))
            let fresh = result.videos.filter { !existing.contains($0.id) }
            videos += fresh
            currentPage = nextPage
            hasNextPage = result.hasNext && !fresh.isEmpty
            Self.log.info("page \(nextPage): +\(fresh.count) videos, total=\(videos.count), hasNext=\(hasNextPage)")
        } catch {
            if error.isCancellation { return }
            // 追加失败不打断现有列表，保留 hasNextPage 以便重试
            Self.log.error("loadMore failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 视频卡片
//
// 结构说明：缩略图与标题各自包 NavigationLink（点击进播放页），
// 分类 chips 独立于 NavigationLink —— SwiftUI 中嵌套在 NavigationLink
// 里的 Button 会被整卡导航吞掉点击（实测），必须放在外层。

struct CafeVideoCard: View {
    let video: CafeVideo
    var onCategoryTap: ((CafeCategory) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(destination: VideoPlayerScreen(video: video)) {
                thumbnail
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                NavigationLink(destination: VideoPlayerScreen(video: video)) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // 分类标签：可点击，点击后把分类名填入搜索框并过滤（原版行为）
                // 级别标签（第一个）按原版配色实色显示，普通分类用品牌色淡底
                if !video.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(video.categories) { category in
                                Button {
                                    onCategoryTap?(category)
                                } label: {
                                    Text(category.name)
                                        .font(.caption2.weight(category.levelColor != nil ? .semibold : .regular))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(category.levelColor ?? Theme.accent.opacity(0.12))
                                        .foregroundStyle(category.levelColor != nil ? .white : Theme.accent)
                                        .clipShape(Capsule())
                                }
                                .accessibilityIdentifier("cafe.category.\(category.name)")
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(cornerRadius: 10)
    }

    private var thumbnail: some View {
        ZStack(alignment: .center) {
            KFImage(video.thumbnailURL)
                .resizable()
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 640, height: 420)))
                .placeholder {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .overlay {
                            Image(systemName: "film")
                                .foregroundStyle(Theme.textSecondary)
                        }
                }
                .fade(duration: 0.25)
                .aspectRatio(contentMode: .fill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()

            Image(systemName: "play.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 6)
        }
    }
}
