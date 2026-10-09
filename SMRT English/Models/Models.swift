//
//  Models.swift
//  SMRT English
//
//  数据模型定义
//  ============================
//  本文件定义 App 内全部核心模型：
//  - CafeLevel       Cafe 分级（children/kids/youth/adults）
//  - LibraryCourse   课程（封面/编号/描述）
//  - LessonSection   课时分组（如 Conversation and Practice / Reading）
//  - LessonItem      课时条目（编号 1-1 + 标题 + lessonId）
//  - CourseUnit      课程单元（My Friends 01，内含多个分组）
//  - StudentClass    我的班级（Classes 页，班级名/课程/成员/详情页地址）
//
//  课时正文不再原生建模：课时详情内容区为 WebView 加载官网页面，
//  App 侧仅保留侧栏课时列表（LessonItem）用于顶部导航。
//
//  数据来源：smrtenglish.cn 服务端渲染 HTML，由 SMRTHTMLParser 解析填充。
//

import Foundation

// MARK: - Cafe

/// Cafe 分类标签（可点击，点击后按该分类过滤列表）
struct CafeCategory: Identifiable, Hashable {
    let name: String
    /// 分类过滤页路径，如 /sunshine/cafe/all/books?s=Books
    let path: String
    /// 级别标签（第一个标签通常是级别）：adult / youth / kids / children，
    /// 原版 CSS 有专属配色（smrt.ui.global.min.css .category.{level}），普通分类为 nil
    let level: String?
    var id: String { path }
}

struct CafeVideo: Identifiable, Hashable {
    /// 使用 modal 容器 id（如 8200）作为稳定 id
    let id: String
    let title: String
    let description: String
    let categories: [CafeCategory]
    /// 缩略图完整 URL（vidXXXX.jpg）
    let thumbnailURL: URL?
    /// 视频完整 URL（vidXXXX.mp4）
    let videoURL: URL?
    /// 音频完整 URL（若该条目是音频内容；当前站点暂无，预留兜底）
    let audioURL: URL?
    /// 所在页面路径（用于区分来自哪个 tab）
    var levelPath: String = "/sunshine/cafe"
}

/// Cafe 顶部 Tab：固定分级 + 动态搜索/分类页
/// 原版 tab 顺序（<ul id="categorynav">）：All / Adults / Youth / Kids / Children
struct CafeTab: Hashable {
    let title: String
    let path: String

    static let all    = CafeTab(title: "All",    path: "/sunshine/cafe")
    static let adults = CafeTab(title: "Adults", path: "/sunshine/cafe/adults")
    static let youth  = CafeTab(title: "Youth",  path: "/sunshine/cafe/youth")
    static let kids   = CafeTab(title: "Kids",   path: "/sunshine/cafe/kids")
    static let children = CafeTab(title: "Children", path: "/sunshine/cafe/children")

    /// 固定分级 Tab
    static let levels: [CafeTab] = [.all, .adults, .youth, .kids, .children]

    /// 全文搜索页（实测接口：/cafe/all/search?s=关键词）
    static func search(_ keyword: String) -> CafeTab {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        return CafeTab(title: "Search: \(keyword)", path: "/sunshine/cafe/all/search?s=\(encoded)")
    }

    /// 分类过滤页（与原版分类标签链接一致）
    static func category(_ category: CafeCategory) -> CafeTab {
        CafeTab(title: category.name, path: category.path)
    }
}

// MARK: - Library

struct LibraryCourse: Identifiable, Hashable {
    /// 课程数字 id，如 384
    let id: String
    let title: String
    /// 课程代号，如 EC / EE1 / EE2
    let code: String
    let courseDescription: String
    let imageURL: URL?
}

/// Library 首页 "English Courses" 区的类型卡（English for Youth 等）
struct LibraryTypeCard: Identifiable, Hashable {
    let name: String
    /// 类型 key：youth / kids / children（对应 ?s={key} 列表页）
    let key: String
    let imageURL: URL?
    var id: String { key }
}

/// Library 首页课程封面卡（原版仅封面图，点击进课程详情）
struct LibraryCourseCard: Identifiable, Hashable {
    /// 课程数字 id
    let id: String
    let imageURL: URL?
}

/// Library 首页类型分组（标题 + 横滑课程卡）
struct LibraryGroup: Identifiable, Hashable {
    let title: String
    /// 分组类型 key（youth/kids/children）
    let key: String
    let courses: [LibraryCourseCard]
    var id: String { key }
}

/// Library 首页整页数据
struct LibraryHome: Equatable {
    let types: [LibraryTypeCard]
    let groups: [LibraryGroup]
}

struct LessonItem: Identifiable, Hashable {
    /// lessonId（如 13927）；未解锁课时无 id，用 "locked-{number}" 伪 id
    let id: String
    /// 课程 id（如 1586，lesson URL 第一段）
    let courseId: String
    /// 课时编号，如 "1-1"
    let number: String
    let title: String
    /// 未解锁课时（页面 disabled-lesson，无链接）
    let locked: Bool

    init(id: String, courseId: String, number: String, title: String, locked: Bool = false) {
        self.id = id
        self.courseId = courseId
        self.number = number
        self.title = title
        self.locked = locked
    }
}

struct LessonSection: Identifiable, Hashable {
    /// 分组标题，如 "Conversation and Practice"
    let title: String
    let lessons: [LessonItem]
    var id: String { title }
}

struct CourseUnit: Identifiable, Hashable {
    /// 单元标题，如 "My Friends"
    let name: String
    /// 单元序号，如 "01"
    let number: String
    /// 单元封面图
    let imageURL: URL?
    let sections: [LessonSection]
    var id: String { name + number }
}

/// 班级页子 Tab（rawValue = 官网 URL 路径段）
/// 官网班级页左侧菜单：Course / Class List / Attendance / Assignments / Assessments / Class Info
/// 注意 Assessments 的官网路径是 evaluation；
/// Gradebook 为教师端独有第 7 项（学生端隐藏，见 ClassCourseView.visibleTabs）
enum ClassTab: String, CaseIterable, Identifiable {
    case course = "course"
    case classList = "classlist"
    case attendance = "attendance"
    case assignments = "assignments"
    case assessments = "evaluation"
    case gradebook = "gradebook"
    case classInfo = "classinfo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .course: return "Course"
        case .classList: return "Class List"
        case .attendance: return "Attendance"
        case .assignments: return "Assignments"
        case .assessments: return "Assessments"
        case .gradebook: return "Gradebook"
        case .classInfo: return "Class Info"
        }
    }
}

/// 班级作业（Assignments 页表格行，学生只读视角）
struct ClassAssignment: Identifiable, Hashable {
    /// 课时链接（含 #ex 锚点）作稳定 id，如 /sunshine/lesson/1339/13233#ex4421
    let id: String
    /// 状态文案（官网 data-tippy-content：Complete / Assigned...）
    let status: String
    /// 作业标题（课时名）
    let title: String
    /// 所属分组（如 Reading and Writing）
    let section: String
    /// 课时页链接（点击跳原生课时详情）
    let lessonPath: String?
    /// 截止日期（如 Oct 7th）
    let dueDate: String
    /// 得分（如 100%，未完成时为空）
    let score: String
}

/// Class Info 页键值对（Class Code / Class Name / Course / Teacher）
struct ClassInfoItem: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }
}

// MARK: - Classes（我的班级）

/// 班级成员（Classes 页卡片内的头像列表，名字来自头像的 tooltip）
struct ClassMember: Identifiable, Hashable {
    /// 稳定 id（排序后位置 + 姓名，服务端顺序变化也不影响 ForEach 复用）
    let id: String
    let name: String
    /// 成员头像 URL（多数为站点默认头像 default1.gif）
    let avatarURL: URL?
}

/// 我的班级（/sunshine/classes 列表项）
struct StudentClass: Identifiable, Hashable {
    /// 班级数字 id（如 25057，取自 /sunshine/class/{id}/course/ 链接）
    let id: String
    /// 班级名，如 "EE1段周一班EE1上半年"
    let name: String
    /// 课程名，如 "ELEMENTARY ENGLISH ONE"
    let course: String
    /// 班级课程页路径（点击卡片跳转用）
    let coursePath: String
    let members: [ClassMember]
}

// MARK: - 班级课程（/sunshine/class/{id}/course/）

/// 班级课程页课时行（lesson-status 标记练习/共享状态）
struct ClassLesson: Identifiable, Hashable {
    /// 课时 id（lesson 链接第二段，如 13180）
    let id: String
    /// 课程课时 id（lesson 链接第一段，如 1339）
    let courseId: String
    /// 编号，如 "1-1"
    let number: String
    let title: String
    /// 官网 lesson-status 的 tippy 文案：In Progress / Lesson only / Not shared
    let status: String
    /// 状态点是否标记 has-exercises
    let hasExercises: Bool
}

/// 班级课程页分组（category-header，如 Conversation and Practice）
struct ClassSection: Identifiable, Hashable {
    let title: String
    let lessons: [ClassLesson]
    var id: String { title }
}

/// 班级课程页单元（unit-section，手风琴折叠）
struct ClassUnit: Identifiable, Hashable {
    /// 单元课时 id（unit-content 的 id 后缀，如 1339）
    let id: String
    /// 单元名，如 "My Day"
    let name: String
    /// 单元序号，如 "01"
    let number: String
    /// 单元封面图（unit-image 背景）
    let imageURL: URL?
    let sections: [ClassSection]
}

/// 班级课程页整页数据
struct ClassCourse: Equatable {
    /// 班级名，如 "EE1段周一班EE1上半年"
    let className: String
    /// 课程名，如 "Elementary English One"
    let courseName: String
    /// 课程在 Library 的 id（页面 folder_open 按钮的 /sunshine/library/{id}）
    let courseLibraryId: String
    let units: [ClassUnit]
    /// 是否教师端（班级页侧栏含 Gradebook 入口——学生端 6 项、教师端 7 项）
    let isTeacher: Bool
}

// MARK: - 教师端（/sunshine/class/{id}/ 教师视角）
//
// 2026-10-08 教师账号实测（curl 登录抓页）：
// - 角色判定：班级页侧栏含 gradebook 入口（学生端 6 项、教师端 7 项）
// - Assignments：三态服务端 tab（?tab=scheduled/in-progress/complete-assignments，
//   badge 计数 smrt-scheduled/in-progress/complete），行内删除/公布答案/
//   成绩查看等交互繁多
// - Attendance：Take Attendance 点图打卡 / 记录表改状态 / 搜索
// - Assignments / Attendance / Assessments / Gradebook 均为重交互页面
//   → WebView 登录态承载官网自理（隐藏站点 chrome 只留内容）；
//   Class List 为纯展示表格 → 原生简单列表

/// 教师端 Class List 成员行（表格视图：头像 / 姓名 / Id / Email）
struct TeacherClassListMember: Identifiable, Hashable {
    /// 学生 id（view=student 链接）
    let id: String
    let name: String
    /// 学生 Id 列（官网当前显示为空）
    let number: String
    let email: String
    let avatarURL: URL?
}

// MARK: - 登录账号

struct SMRTAccount: Equatable {
    var email: String
}
