//
//  RootView.swift
//  SMRT English
//
//  根视图：负责登录态判断与主 Tab 路由
//  - 启动时异步校验 cookie 会话（SMRTClient.checkSession）
//  - 有效 → MainTabView；无效 → LoginView
//  - 监听 smrt.session.invalid 通知，任意页面会话失效时弹回登录页
//

import SwiftUI

struct RootView: View {
    @State private var phase: Phase = .checking

    enum Phase { case checking, loggedIn, loggedOut }

    var body: some View {
        Group {
            switch phase {
            case .checking:
                checkingView
            case .loggedIn:
                MainTabView()
            case .loggedOut:
                LoginView(onLoginSuccess: {
                    withAnimation { phase = .loggedIn }
                })
            }
        }
        .task { await restoreSession() }
        .onReceive(NotificationCenter.default.publisher(for: .smrtSessionInvalid)) { _ in
            withAnimation { phase = .loggedOut }
        }
    }

    private var checkingView: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "book.pages")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Theme.accentGradient)
                Text("SMRT English")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                ProgressView()
            }
        }
    }

    private func restoreSession() async {
        var valid = await SMRTClient.shared.checkSession()
        if !valid {
            // cookie 过期：记住过密码则静默重登一次
            valid = await SMRTClient.shared.autoReloginIfNeeded()
        }
        withAnimation {
            phase = valid ? .loggedIn : .loggedOut
        }
    }
}

/// 登录成功后的主界面
/// 底部 Tab 对齐官网导航（Material home/school/groups）：
/// Cafe=房子、Library=学士帽、Classes=三人组；
/// 个人入口（Me/退出登录）在 Classes 页右上角头像，与官网一致。
struct MainTabView: View {
    @State private var selection: Tab = .cafe
    /// Classes 需要登录态：切到该 tab 时校验会话，失效则弹出全屏登录页盖住内容
    @State private var showLoginCover = false
    @State private var lastSessionCheck: Date?

    enum Tab: Hashable {
        case cafe, library, classes
    }

    var body: some View {
        TabView(selection: $selection) {
            CafeView()
                .tabItem {
                    Label("Cafe", systemImage: selection == .cafe ? "house.fill" : "house")
                }
                .tag(Tab.cafe)
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: selection == .library ? "graduationcap.fill" : "graduationcap")
                }
                .tag(Tab.library)
            ClassesView()
                .tabItem {
                    Label("Classes", systemImage: selection == .classes ? "person.3.fill" : "person.3")
                }
                .tag(Tab.classes)
        }
        .tint(Theme.tabBlue)
        .onChange(of: selection) { newTab in
            // Classes 依赖登录态（PHPSESSID 服务端约 1-2 小时过期）：
            // 切入时校验，失效直接弹全屏登录页；5 分钟内不重复校验
            guard newTab == .classes else { return }
            if let last = lastSessionCheck, Date().timeIntervalSince(last) < 300 {
                return
            }
            Task { await validateSessionForClasses() }
        }
        .fullScreenCover(isPresented: $showLoginCover) {
            LoginView(onLoginSuccess: {
                lastSessionCheck = Date()
                showLoginCover = false
                // 登录后刷新 Classes 数据
                NotificationCenter.default.post(name: .smrtSessionRestored, object: nil)
            })
        }
    }

    private func validateSessionForClasses() async {
        lastSessionCheck = Date()
        var valid = await SMRTClient.shared.checkSession()
        if !valid {
            // cookie 过期：记住过密码则静默重登一次，成功不打扰用户
            valid = await SMRTClient.shared.autoReloginIfNeeded()
        }
        if !valid {
            showLoginCover = true
        }
    }
}

extension Notification.Name {
    static let smrtSessionInvalid = Notification.Name("smrt.session.invalid")
    /// 登录恢复（全屏登录页登录成功），需要登录态的页面监听刷新
    static let smrtSessionRestored = Notification.Name("smrt.session.restored")
}
