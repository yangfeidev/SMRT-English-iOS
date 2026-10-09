//
//  SMRTEnglishApp.swift
//  SMRT English
//
//  App 入口
//

import SwiftUI
import AVFoundation
import UIKit

/// 页面级方向锁：App 默认竖屏；教师端宽表格 WebView 页（Assignments/Attendance）
/// 进入时锁横屏（官网桌面表格布局在手机竖屏 390pt 挤不下，横屏完整还原）。
/// ObservableObject：ClassCourseView 据此切换「导航栏+tab 两行」/「返回按钮+tab 一行」布局
final class OrientationLock: ObservableObject {
    static let shared = OrientationLock()
    /// true = 强制横屏（左/右任一）
    @Published var landscapeOnly = false
}

/// 通过 supportedInterfaceOrientationsFor 与 OrientationLock 协作实现页面级横竖屏
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.landscapeOnly ? .landscape : .portrait
    }
}

@main
struct SMRTEnglishApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
