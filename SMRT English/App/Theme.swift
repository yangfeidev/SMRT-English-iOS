//
//  Theme.swift
//  SMRT English
//
//  主题：SMRT 品牌蓝（对齐官网导航选中色 #2196F3）+ 可爱圆润风格
//

import SwiftUI

enum Theme {
    /// 品牌主色（官网底部导航选中蓝，Material Blue 500）
    static let accent = Color(hex: 0x2196F3)
    /// 深蓝（渐变用，Material Blue 700）
    static let accentDark = Color(hex: 0x1976D2)
    /// 页面背景（冷调浅蓝白）
    static let background = Color(red: 0.956, green: 0.972, blue: 0.984)     // #F4F8FB
    /// 卡片背景
    static let card = Color.white
    /// 主文字
    static let textPrimary = Color(red: 0.15, green: 0.15, blue: 0.17)
    /// 次要文字
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.58)

    /// 品牌渐变
    static let accentGradient = LinearGradient(
        colors: [accent, accentDark],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// 底部 Tab 选中色（与主色统一）
    static let tabBlue = Color(hex: 0x2196F3)
    /// 底部 Tab 未选中灰
    static let tabGray = Color(hex: 0x8E99A3)
}

/// 级别标签配色（取自原版 smrt.ui.global.min.css 的 .category.{level}）
extension CafeCategory {
    var levelColor: Color? {
        switch level {
        case "adult":    return Color(hex: 0x2196F3)   // 蓝
        case "youth":    return Color(hex: 0x009688)   // 青绿
        case "kids":     return Color(hex: 0x00BCD4)   // 青
        case "children": return Color(hex: 0xE91E63)   // 粉
        default:         return nil
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// 卡片样式（圆角可调，默认 16）
extension View {
    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    /// iPad 上内容限宽居中（iPhone 不受影响）
    func centeredContent(maxWidth: CGFloat = 700) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
