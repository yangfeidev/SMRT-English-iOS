//
//  ProfileView.swift
//  SMRT English
//
//  Me 区块（账号卡 + 退出登录），常驻嵌在 Classes 页列表底部
//  （原「右上角头像 → 独立 Me 页」入口已取消）
//  - sessionValid 由 ClassesView 依据班级数据拉取结果驱动：
//      true  → 账号卡 + 退出登录
//      false → 「登录已过期」提示 + 重新登录按钮（切回登录页，登录后自动恢复）
//    会话有效性以真实数据拉取为准，不再仅凭本地缓存邮箱展示「假登录」状态
//

import SwiftUI

struct ProfileSection: View {
    /// 会话是否有效（ClassesView 数据拉取成功/失败驱动）
    let sessionValid: Bool

    @State private var showLogoutConfirm = false

    private var email: String {
        SMRTClient.shared.savedEmail ?? "已登录"
    }

    var body: some View {
        VStack(spacing: 20) {
            if sessionValid {
                accountCard
                logoutButton
            } else {
                expiredCard
            }

            Text("SMRT English · 个人学习使用")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
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

    // MARK: - 账号卡（登录有效）

    private var accountCard: some View {
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
    }

    // MARK: - 退出登录

    private var logoutButton: some View {
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
    }

    // MARK: - 登录过期（会话失效）

    private var expiredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textSecondary)
            Text("登录已过期")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("会话已失效，请重新登录后使用")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button {
                // 切回登录页（RootView 监听该通知）；登录成功后 Classes 自动刷新
                NotificationCenter.default.post(name: .smrtSessionInvalid, object: nil)
            } label: {
                Text("重新登录")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .cardStyle()
    }
}
