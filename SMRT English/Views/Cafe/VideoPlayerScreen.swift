//
//  VideoPlayerScreen.swift
//  SMRT English
//
//  视频播放页（Cafe）
//  - 详情页始终为原生布局（标题/分类/描述 + 播放区），不跳网页
//  - 编码自适应：播放前探测 mp4 的编码（Range 拉取 moov box 搜 fourcc）——
//    官网近期视频使用 AV1 编码，AVPlayer 不支持 AV1（真机实测同一列表
//    H.264 卡片正常、AV1 卡片黑屏）：
//      · H.264/其余编码 → 原生 AVPlayer（系统控制栏 + 全屏按钮）
//      · AV1 → 播放区嵌 HTML5 <video> 播放器（WebKit 有 AV1 软解，
//        iOS 17+ 可播；内嵌在原生详情页里，不离开 App 布局）
//  - 探测失败（网络异常等）按非 AV1 处理，维持原生 AVPlayer
//

import SwiftUI
import AVKit
import WebKit

struct VideoPlayerScreen: View {
    let video: CafeVideo

    /// 编码探测状态：nil=探测中
    @State private var isAV1: Bool?
    @State private var player: AVPlayer?
    @State private var isFullscreen = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    playerArea

                    VStack(alignment: .leading, spacing: 10) {
                        Text(video.title)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.textPrimary)
                        if !video.categories.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(video.categories) { category in
                                        Text(category.name)
                                            .font(.caption.weight(category.levelColor != nil ? .semibold : .medium))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(category.levelColor ?? Theme.accent.opacity(0.12))
                                            .foregroundStyle(category.levelColor != nil ? .white : Theme.accent)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        if !video.description.isEmpty {
                            Text(video.description)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
                .centeredContent(maxWidth: 760)
            }
        }
        .navigationTitle(video.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { isAV1 = await detectAV1(url: video.videoURL) }
        .fullScreenCover(isPresented: $isFullscreen) {
            if let player {
                FullscreenVideoPlayer(player: player, title: video.title)
            }
        }
        .onDisappear { player?.pause() }
    }

    // MARK: - 播放区（按编码选择渲染器）

    @ViewBuilder
    private var playerArea: some View {
        switch isAV1 {
        case nil:
            // 探测中（Range 请求 moov，通常 <1s）
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
                .aspectRatio(16 / 9, contentMode: .fit)
                .padding(.horizontal, 16)
                .overlay { ProgressView().tint(.white) }
        case .some(true):
            // AV1：AVPlayer 不支持，内嵌 HTML5 video（WebKit 解码）
            if let url = chooseURL() {
                HTMLVideoPlayer(videoURL: url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            }
        case .some(false):
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        // 右上角全屏按钮（常显，半透明圆底）
                        Button {
                            isFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .padding(.horizontal, 16)
                    .overlay { ProgressView().tint(.white) }
            }
        }
    }

    // MARK: - 编码探测

    /// 判断 mp4 是否为 AV1 编码：Range 拉取文件头 1KB 解析 box 得 moov 位置（窗口
    /// 取 1KB 而非 64B，防止个别文件 moov 前还有其它 box 导致漏判），
    /// 下载 moov 全量后搜索 av01 fourcc。任何一步失败按非 AV1 处理。
    private func detectAV1(url: URL?) async -> Bool {
        guard let url else { return false }
        guard let head = await fetchBytes(url, 0, 1023) else { return false }
        guard head.count >= 16,
              String(data: head.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else { return false }

        // 顺序解析顶层 box，定位 moov
        var offset = 0
        var moovRange: Range<Int>?
        while offset + 8 <= head.count {
            let sizeData = head.subdata(in: offset..<offset + 4)
            let sizeBytes = [UInt8](sizeData)
            let b0 = Int(sizeBytes[0])
            let b1 = Int(sizeBytes[1])
            let b2 = Int(sizeBytes[2])
            let b3 = Int(sizeBytes[3])
            let size = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            let typeData = head.subdata(in: offset + 4..<offset + 8)
            let type = String(data: typeData, encoding: .ascii) ?? ""
            if type == "moov" {
                moovRange = offset..<(offset + size)
                break
            }
            if size <= 0 { break }
            offset += size
        }
        guard let moovRange else { return false }

        let moovSize = moovRange.upperBound - moovRange.lowerBound
        guard let moov = await fetchBytes(url, moovRange.lowerBound, moovRange.upperBound - 1),
              moov.count == moovSize else { return false }

        return moov.range(of: Data("av01".utf8)) != nil
    }

    /// Range 请求 [start, end] 闭区间的字节
    private func fetchBytes(_ url: URL, _ start: Int, _ end: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 206 || http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - 播放

    private func setupPlayer() {
        // 仅原生分支需要 AVPlayer；AV1 走内嵌 HTML5 video
        guard isAV1 == false else { return }
        let url = chooseURL()
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        // Cafe 视频是 28~54MB 的单源大文件：AVPlayer 默认
        // automaticallyWaitsToMinimizeStalling = true 会先缓冲一大段「最小化卡顿」
        // 才开播，表现为点开半天黑屏。关掉 + playImmediately = 网页 <video>
        // 同款的「边下边播」策略（课程详情页 WebView 里顺畅就是因为它）
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        p.playImmediately(atRate: 1)
    }

    private func chooseURL() -> URL? {
        video.videoURL ?? video.audioURL
    }
}

// MARK: - HTML5 <video> 播放器（AV1 兜底：WebKit 具备 AV1 解码，AVPlayer 没有）

struct HTMLVideoPlayer: UIViewRepresentable {
    let videoURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black

        // src 绝对地址 + loadHTMLString（baseURL nil，纯本地装载）
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>html,body{margin:0;padding:0;height:100%;background:#000}
        video{width:100%;height:100%;object-fit:contain}</style>
        </head><body>
        <video src="\(videoURL.absoluteString)" controls autoplay playsinline></video>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
