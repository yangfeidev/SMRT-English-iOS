//
//  SMRTEnglishApp.swift
//  SMRT English
//
//  App 入口
//

import SwiftUI
import AVFoundation

@main
struct SMRTEnglishApp: App {
    init() {
        // 音频会话设为 playback：课程音频/视频在静音键打开时也能出声
        // （默认 .soloAmbient 遵循静音键，真机上表现为"播放音频听不到声音"）
        // setActive 是阻塞调用，放后台线程，避免主线程 UI 无响应警告
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}
