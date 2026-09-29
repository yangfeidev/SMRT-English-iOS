//
//  NavigationCompat.swift
//  SMRT English
//
//  导航兼容层：最低支持 iOS 15
//  - CompatNavigationStack：iOS 16+ 用 NavigationStack，iOS 15 用 NavigationView（.stack 样式，
//    与 NavigationStack 的单列推入行为一致，iPad 上也不会变成分栏）
//  - compatNavigationBarHidden()：隐藏系统导航栏（iOS 16+ 用 toolbar(.hidden, for:)，
//    iOS 15 用 navigationBarHidden）
//  - 页面跳转统一用 NavigationLink(destination:)，iOS 15/16+ 均原生支持，无需分叉
//

import SwiftUI

/// NavigationStack 的 iOS 15 兼容包装
struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// 隐藏系统导航栏（Cafe 页自绘标题栏用）
    @ViewBuilder
    func compatNavigationBarHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(.hidden, for: .navigationBar)
        } else {
            self.navigationBarHidden(true)
        }
    }
}
