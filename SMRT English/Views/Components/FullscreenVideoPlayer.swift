//
//  FullscreenVideoPlayer.swift
//  SMRT English
//
//  全屏视频播放器（fullScreenCover 弹出）
//  - 复用调用方的同一个 AVPlayer 实例：弹出/退出全屏时播放进度、播放状态无缝衔接
//  - 黑底 + AVKit 系统控制栏（播放/暂停/进度/音量/PiP），横竖屏均可（工程已支持横屏）
//  - 顶部：左上角关闭按钮 + 标题
//  - 使用方：LessonVideoBlock（课时视频块）、VideoPlayerScreen（Cafe 播放页）
//

import SwiftUI
import AVKit

struct FullscreenVideoPlayer: View {
    let player: AVPlayer
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // 与关闭按钮等宽的透明占位，让标题在剩余空间居左、视觉平衡
                    Color.clear
                        .frame(width: 30, height: 30)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()
            }
        }
    }
}
