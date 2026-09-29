//
//  LoginView.swift
//  SMRT English
//
//  登录页
//  - 表单：邮箱 + 密码（账密总是记住：Keychain 存储，默认行为且无开关）
//  - 调 SMRTClient.login（POST /process.php），cookie 由系统自动持久化
//  - 登录成功回调 onLoginSuccess
//

import SwiftUI
import UIKit

struct LoginView: View {
    var onLoginSuccess: () -> Void

    @State private var email = SMRTClient.shared.savedEmail ?? ""
    // 记住过密码则启动回填（Keychain 读取）
    @State private var password = SMRTClient.shared.savedEmail
        .flatMap { Keychain.read(account: $0) } ?? ""
    @State private var showForgotSheet = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header

                    VStack(spacing: 14) {
                        field(icon: "envelope", placeholder: "邮箱", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        field(icon: "lock", placeholder: "密码", text: $password, secure: true)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }

                    loginButton

                    // 忘记密码 → 原生重置邮件请求
                    Button("忘记密码？") { showForgotSheet = true }
                        .font(.caption)
                        .foregroundStyle(Theme.accent)

                    Text("登录即使用你在 smrtenglish.cn 的账号\n会话通过 Cookie 自动保持")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .centeredContent(maxWidth: 480)
            }
        }
        .task {
            await autoLoginIfRequested()
        }
        .onAppear {
            // 系统自带清空按钮：编辑时在输入框右侧显示 ✕（邮箱/密码框均生效）
            UITextField.appearance().clearButtonMode = .whileEditing
        }
        .sheet(isPresented: $showForgotSheet) {
            ForgotPasswordView(initialEmail: email)
        }
    }

    /// 调试辅助：simctl launch 带参 `-smrt-email x -smrt-password y` 时自动登录
    private func autoLoginIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let emailIdx = args.firstIndex(of: "-smrt-email"),
              emailIdx + 1 < args.count,
              let pwdIdx = args.firstIndex(of: "-smrt-password"),
              pwdIdx + 1 < args.count else { return }
        email = args[emailIdx + 1]
        password = args[pwdIdx + 1]
        await login()
    }

    // MARK: - 子视图

    private var header: some View {
        VStack(spacing: 10) {
            // smrt 品牌：透明底蓝书本 + 圆体字标，融入米白背景
            HStack(spacing: 14) {
                Image("SmrtBookMark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 3)
                Text("smrt")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .offset(y: 6) // 等价 baselineOffset(-6)：iOS 15 无 baselineOffset，用渲染位移替代
            }
            Text("英语学习 · Cafe 视频 + 分级课程")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.body)
        }
        .padding(14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var loginButton: some View {
        Button {
            Task { await login() }
        } label: {
            HStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                }
                Text(isLoading ? "登录中…" : "登录")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 4)
        }
        .disabled(isLoading || email.isEmpty || password.isEmpty)
        .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1)
    }

    // MARK: - 动作

    private func login() async {
        // 点登录立即收起键盘，不等登录结果和页面切换动画
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let trimmed = email.trimmingCharacters(in: .whitespaces)
            let ok = try await SMRTClient.shared.login(email: trimmed, password: password)
            if ok {
                // 账密总是记住（Keychain），下次会话过期后自动回填
                Keychain.save(password, account: trimmed)
                onLoginSuccess()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 忘记密码（原生请求官网重置邮件，POST /process.php subforgot=1）

struct ForgotPasswordView: View {
    let initialEmail: String
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        CompatNavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("输入注册邮箱，官网会向你发送重置密码邮件。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(14)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView().tint(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        } else {
                            Text("发送重置邮件")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || email.isEmpty)

                    if let resultMessage {
                        Label(resultMessage,
                              systemImage: resultIsError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(resultIsError ? .red : .green)
                    }

                    Spacer()
                }
                .padding(24)
                .centeredContent(maxWidth: 480)
            }
            .navigationTitle("忘记密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if email.isEmpty { email = initialEmail }
            }
        }
    }

    private func submit() async {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        isSubmitting = true
        resultMessage = nil
        defer { isSubmitting = false }
        do {
            try await SMRTClient.shared.forgotPassword(email: email.trimmingCharacters(in: .whitespaces))
            resultMessage = "重置邮件已发送，请到邮箱查收（若未收到请确认邮箱是否已注册）"
            resultIsError = false
        } catch {
            resultMessage = error.localizedDescription
            resultIsError = true
        }
    }
}
