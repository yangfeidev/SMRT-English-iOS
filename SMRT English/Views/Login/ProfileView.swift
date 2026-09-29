//
//  ProfileView.swift
//  SMRT English
//
//  Me 页（对齐官网右上角头像 → /sunshine/me）：账号信息 + 退出登录
//  入口：Classes 页标题栏右侧头像按钮（官网同位置）
//

import SwiftUI

struct ProfileView: View {
    @State private var showLogoutConfirm = false

    private var email: String {
        SMRTClient.shared.savedEmail ?? "已登录"
    }

    var body: some View {
        CompatNavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 20) {
                    // 账号卡片
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Theme.accentGradient)
                                .frame(width: 56, height: 56)
                            Text(String(email.prefix(1)).uppercased())
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(email)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("sunshine 校区")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .cardStyle()

                    // 退出登录
                    Button {
                        showLogoutConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("退出登录")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(.red)
                        .padding(16)
                        .cardStyle()
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("SMRT English · 个人学习使用")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .centeredContent(maxWidth: 600)
            }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog("确定退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    // 先发通知立即切登录页（不等清理完成），
                    // cookie/UserDefaults 清理丢后台——deleteCookie 走系统 IPC，主线程同步删会卡顿
                    NotificationCenter.default.post(name: .smrtSessionInvalid, object: nil)
                    Task.detached(priority: .userInitiated) {
                        SMRTClient.shared.logout()
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
