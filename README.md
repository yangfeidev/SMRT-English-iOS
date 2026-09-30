# SMRT English

基于 [smrtenglish.cn](https://smrtenglish.cn) 官网内容的 iOS 原生学习客户端（SwiftUI），供个人学习使用。

## 功能

- **Cafe**：视频流浏览（分级 Tab / 搜索 / 分页），播放按视频编码自适应——H.264 走原生 AVPlayer，AV1 内嵌 WebKit 播放器，并采用立即起播策略
- **Library**：课程库浏览 → 课程详情（单元树）→ 课时详情（WebView 承载官网页面）
- **Classes**：我的班级 → 班级课程页（单元树手风琴）→ 课时；Me 区块常驻（账号信息 / 退出登录）
- **登录态**：Keychain 记住密码、会话失效自动静默重登、单点登录互踢检测（重定向路径判定）

## 技术要点

| 项 | 说明 |
|---|---|
| UI 框架 | SwiftUI（最低支持 iOS 15，含 NavigationStack 兼容层） |
| 工程管理 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` 生成 `project.pbxproj`） |
| 图片缓存 | Kingfisher 8.13（源码 vendor 进工程，静态库 target，避免 SPM 网络依赖） |
| 混合渲染 | 课时详情 / 部分页面由 WKWebView 承载官网页面，登录态经 `syncCookies` 同步 |
| 移动端适配 | 注入 CSS 修正官网手机端栅格（单词卡/点图活动/画板/多图行） |
| 编码探测 | 播放前 Range 拉取 mp4 moov box 检测 AV1，AVPlayer 不支持 AV1 编码 |

## 构建

```bash
# 1. 重新生成工程（新增/删除文件后需要）
xcodegen generate

# 2. 打开工程运行（推荐 GUI）
open "SMRT English.xcodeproj"
# 选择模拟器或真机，Cmd+R

# CLI 编译验证
xcodebuild -project "SMRT English.xcodeproj" -scheme "SMRT English" \
  -destination 'generic/platform=iOS Simulator' build
```

环境要求：Xcode 26+、iOS 15.0+ 部署目标、Apple 登录的开发者账号（真机安装）。

## 项目结构

```
SMRT English/
├── App/                 # 入口 / 根路由 / 主题 / NavigationStack 兼容层
├── Models/              # 数据模型（Cafe / Library / Classes）
├── Networking/          # SMRTClient（登录/会话/抓取）+ SMRTHTMLParser（HTML 解析）
├── Views/
│   ├── Cafe/            # Cafe 列表 + 视频播放页
│   ├── Library/         # 课程库 / 课程详情 / 课时详情
│   ├── Classes/         # 我的班级 / 班级课程页 / 网页承载页
│   ├── Login/           # 登录 / Me 区块
│   └── Components/      # WebViewRepresentable / 全屏播放器
└── Vendor/Kingfisher/   # Kingfisher 源码（静态库）
```

## 说明

- 本项目仅供个人学习使用，内容版权归 smrtenglish.cn 所有
- 部分页面为官网页面的 WebView 承载，样式与交互以官网为准
