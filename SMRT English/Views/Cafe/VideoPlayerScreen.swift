//
//  VideoPlayerScreen.swift
//  SMRT English
//
//  视频播放页（Cafe / 课时视频共用）
//  - AVKit VideoPlayer，自动选择最接近 720p 的码率
//  - 顶部展示标题 / 描述 / 分类
//

import SwiftUI
import AVKit

struct VideoPlayerScreen: View {
    let video: CafeVideo

    @State private var player: AVPlayer?

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
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isFullscreen) {
            if let player {
                FullscreenVideoPlayer(player: player, title: video.title)
            }
        }
        .onAppear { setupPlayer() }
        .onDisappear { player?.pause() }
    }

    @State private var isFullscreen = false

    private var playerArea: some View {
        Group {
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

    private func setupPlayer() {
        // 优先选最接近 720p 的源；Cafe 只有单码率时只有一个
        let url = chooseURL()
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        p.play()
    }

    private func chooseURL() -> URL? {
        video.videoURL
    }
}
