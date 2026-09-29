//
//  LessonDetailView.swift
//  SMRT English
//
//  课时详情页
//  - 顶部：同单元课时横向导航 chips（当前高亮，可左右切换课时）
//  - 内容区：按 LessonBlock 顺序渲染（标题/文本/视频/音频/单词卡/图片/翻卡）
//  - 底部：练习列表（有练习才显示）；点击弹 WebView 承载官网练习弹窗
//    （官网支持 #ex{ssi} 深链自动弹出对应练习，交互与网页完全一致）
//

import SwiftUI
import Kingfisher
import AVFoundation
import AVKit
import PencilKit

struct LessonDetailView: View {
    let course: LibraryCourse
    /// 初始课时（外部 push 传入，仅作 currentLesson 的初始值）
    let lesson: LessonItem

    /// 当前展示的课时：顶部 tab 本页切换（不 push），状态驱动重载
    @State private var currentLesson: LessonItem
    /// 顶部课时导航（含当前课时；独立保留，切换加载失败也不会消失）
    @State private var siblingItems: [LessonItem] = []
    @State private var detail: LessonDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedExercise: LessonExercise?
    /// 首次 push 加载需要等转场动画；之后的 tab 本页切换立即加载
    @State private var firstLoadDone = false

    init(course: LibraryCourse, lesson: LessonItem) {
        self.course = course
        self.lesson = lesson
        _currentLesson = State(initialValue: lesson)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                siblingBar
                content
            }
            // 顶部对齐：tab 栏恒定贴顶，任何内容状态（加载/清空/切换间隙）都不会把它挤走
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(currentLesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: currentLesson.id) {
            // 仅首次 push 转场需要等动画结束（转场中写状态会卡动画）；
            // tab 本页切换无转场，立即加载
            if !firstLoadDone {
                try? await Task.sleep(nanoseconds: 450_000_000)
                firstLoadDone = true
            }
            await load()
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseSheet(exercise: exercise)
        }
    }

    // MARK: - 顶部课时导航（本页切换，不 push）

    @ViewBuilder
    private var siblingBar: some View {
        if siblingItems.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(siblingItems) { item in
                        Button {
                            switchLesson(item)
                        } label: {
                            HStack(spacing: 5) {
                                Text(item.number)
                                    .font(.caption2.bold())
                                Text(item.title)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(item.id == currentLesson.id ? Theme.accent : Theme.card)
                            .foregroundStyle(item.id == currentLesson.id ? .white : Theme.textSecondary)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Theme.background)
        }
    }

    /// 合并官网侧栏课时列表。官网侧栏当前课时自己不是链接（抓不到），
    /// 缺失时补入当前课时；按课时 id 数值排序（官网课时 id 全局递增，排序即页面顺序）。
    private func mergeSiblings(_ fetched: [LessonItem]) {
        var all = fetched
        if !all.contains(where: { $0.id == currentLesson.id }) {
            all.append(currentLesson)
        }
        all.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        siblingItems = all
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            ProgressView("加载课时…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, detail == nil {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(detail.blocks) { block in
                        LessonBlockView(block: block)
                    }
                    if !detail.exercises.isEmpty {
                        exerciseSection(detail.exercises)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
                .centeredContent(maxWidth: 700)
            }
        }
    }

    // MARK: - 练习区（官网 openBtn 深链）

    private func exerciseSection(_ exercises: [LessonExercise]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exercises")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 8) {
                ForEach(exercises) { exercise in
                    Button {
                        selectedExercise = exercise
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "pencil.and.outline")
                                .foregroundStyle(Theme.accent)
                            Text(exercise.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(12)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lesson.exercise.\(exercise.id)")
                }
            }
        }
    }

    private func switchLesson(_ item: LessonItem) {
        guard item.id != currentLesson.id else { return }
        // 清旧内容 → 内容区转 loading，tab 栏（siblingItems）保持可见
        detail = nil
        errorMessage = nil
        currentLesson = item
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await SMRTClient.shared.lesson(
                courseId: currentLesson.courseId, lessonId: currentLesson.id)
            detail = result
            mergeSiblings(result.siblings)
        } catch {
            if error.isCancellation { return }
            detail = nil
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 单个内容块渲染

struct LessonBlockView: View {
    let block: LessonBlock

    var body: some View {
        switch block {
        case .heading(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Theme.accentGradient)
                    .frame(width: 4, height: 18)
                    .clipShape(Capsule())
                Text(text)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.top, 6)

        case .text(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

        case .video(let title, let sources, let embedPath):
            LessonVideoBlock(title: title, sources: sources, embedPath: embedPath)

        case .audio(_, let url):
            AudioPlayButton(url: url)

        case .vocabCard(let caption, let imageURL, let audioURL):
            VocabCard(caption: caption, imageURL: imageURL, audioURL: audioURL)

        case .image(let url, _):
            KFImage(url)
                .resizable()
                .placeholder {
                    Rectangle().fill(Color(.systemGray5)).aspectRatio(16 / 10, contentMode: .fit)
                }
                .fade(duration: 0.25)
                .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        case .imageRow(let images):
            ImageRowView(images: images)

        case .activity(let promptImageURL, let choices):
            ActivityView(promptImageURL: promptImageURL, choices: choices)

        case .sortActivity(let items, let answer):
            SortActivityView(items: items, answer: answer)

        case .writeInline(let before, let after):
            WriteInlineView(before: before, after: after)

        case .drawBoard(let name, let backgroundImageURL):
            DrawBoardView(name: name, backgroundImageURL: backgroundImageURL)

        case .revealCard(let imageURL, let texts):
            RevealCard(imageURL: imageURL, texts: texts)
        }
    }
}

// MARK: - 多图行（官网 row：col4 三列 / col6 两列并排，图下图注）

struct ImageRowView: View {
    let images: [LessonImage]

    var body: some View {
        // 列数对齐官网：1 张通栏、2 张两列、≥3 张三列（超出的自动换行）
        let columnCount = images.count == 1 ? 1 : (images.count == 2 ? 2 : 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(images.indices, id: \.self) { index in
                let item = images[index]
                VStack(spacing: 6) {
                    KFImage(item.url)
                        .resizable()
                        .placeholder {
                            Rectangle().fill(Color(.systemGray5)).aspectRatio(1, contentMode: .fit)
                        }
                        .fade(duration: 0.25)
                        .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let caption = item.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

// MARK: - 练习弹窗（原生作答：/sunshine/exercise/{ssi} 片段解析 + 官网同款提交接口）

/// 原生练习页：当前支持 dropdown 题型（题图 + 下拉选择），
/// 提交对齐官网 JS（POST /json/exercise_save.php，Submit 时 status=1）
struct ExerciseSheet: View {
    let exercise: LessonExercise
    @Environment(\.dismiss) private var dismiss

    @State private var data: ExerciseData?
    @State private var selections: [String: String] = [:]   // 题目id -> 选项value(qaXXX)
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSubmitConfirm = false
    @State private var isSaving = false
    @State private var savedToast: String?

    var body: some View {
        CompatNavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if isLoading {
                    ProgressView("加载练习…")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.textSecondary)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let data {
                    exerciseContent(data)
                }
            }
            .navigationTitle(exercise.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog("确定提交给老师？", isPresented: $showSubmitConfirm, titleVisibility: .visible) {
                Button("提交", role: .destructive) { Task { await save(submit: true) } }
                Button("取消", role: .cancel) {}
            }
            .overlay {
                if let savedToast {
                    Text(savedToast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private func exerciseContent(_ data: ExerciseData) -> some View {
        if data.isNoAccess {
            VStack(spacing: 12) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.textSecondary)
                Text("暂无权限")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("该练习尚未由老师分享给你，请在网页端确认。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !data.title.isEmpty {
                        Text(data.title)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if !data.instruction.isEmpty {
                        Text(data.instruction)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    ForEach(data.questions) { question in
                        questionCard(question)
                    }

                    // 提交区
                    HStack(spacing: 12) {
                        Button {
                            showSubmitConfirm = true
                        } label: {
                            if isSaving {
                                ProgressView().tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            } else {
                                Text("Submit")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)

                        Button {
                            Task { await save(submit: false) }
                        } label: {
                            Text("Save & Close")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                    }
                    .padding(.top, 8)
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 题目卡片（题图 + 下拉选择）

    private func questionCard(_ question: ExerciseQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = question.imageURL {
                KFImage(url)
                    .resizable()
                    .placeholder {
                        Rectangle().fill(Color(.systemGray5))
                            .aspectRatio(4 / 3, contentMode: .fit)
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                if !question.number.isEmpty {
                    Text(question.number)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }

                Menu {
                    ForEach(question.options, id: \.value) { option in
                        Button {
                            selections[question.id] = option.value
                        } label: {
                            if selections[question.id] == option.value {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedLabel(for: question))
                            .font(.subheadline)
                            .foregroundStyle(selections[question.id] == nil
                                             ? Theme.textSecondary : Theme.accent)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)
    }

    private func selectedLabel(for question: ExerciseQuestion) -> String {
        guard let value = selections[question.id],
              let option = question.options.first(where: { $0.value == value }) else {
            return "请选择"
        }
        return option.label
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await SMRTClient.shared.exercise(exercise)
            data = result
        } catch {
            if error.isCancellation { return }
            data = nil
            errorMessage = error.localizedDescription
        }
    }

    private func save(submit: Bool) async {
        guard let data else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await SMRTClient.shared.saveExercise(data, selections: selections, submit: submit)
            withAnimation { savedToast = submit ? "已提交" : "已保存" }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation { savedToast = nil }
            dismiss()
        } catch {
            withAnimation { savedToast = "保存失败，请重试" }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedToast = nil }
        }
    }
}

// MARK: - 点图判对错活动（官网 click 卡片：题图 + 选项图，点对 ✓ 点错 ✗，纯前端）

struct ActivityView: View {
    let promptImageURL: URL?
    let choices: [ActivityChoice]

    /// 已点过的选项索引 -> 是否点对（官网可反复点，这里点后保留标记）
    @State private var tapped: [Int: Bool] = [:]

    var body: some View {
        // 官网布局：题图在左(col3)、选项图在右(col9 一排 5~6 张)
        HStack(alignment: .top, spacing: 12) {
            if let url = promptImageURL {
                KFImage(url)
                    .resizable()
                    .placeholder {
                        EmptyView()
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // 选项图网格（手机上每行 3 张，与官网比例接近）
            let columns = [GridItem(.adaptive(minimum: 64), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    choiceButton(index, choice)
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)
    }

    private func choiceButton(_ index: Int, _ choice: ActivityChoice) -> some View {
        Button {
            // 官网行为：点对显示 ✓、点错显示 ✗（可反复点）
            if tapped[index] == nil {
                tapped[index] = choice.isCorrect
            }
        } label: {
            ZStack {
                KFImage(choice.imageURL)
                    .resizable()
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 128, height: 128)))
                    .placeholder {
                        Rectangle().fill(Color(.systemGray5))
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let result = tapped[index] {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(result ? Color.green : Color.red)
                        .shadow(radius: 3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 排序活动（官网 sort images：听音排序，选位置互斥抢占，纯本地交互）

struct SortActivityView: View {
    let items: [SortItem]
    let answer: String

    /// figureId -> 位次(1-based)，选择互斥（抢占交换）
    @State private var positions: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    VStack(spacing: 5) {
                        KFImage(item.imageURL)
                            .resizable()
                            .placeholder {
                                Rectangle().fill(Color(.systemGray5))
                                    .frame(height: 66)
                            }
                            .fade(duration: 0.25)
                            .frame(height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Menu {
                            ForEach(Array(1...items.count), id: \.self) { pos in
                                Button("第 \(pos) 位") { assign(item.id, pos) }
                            }
                        } label: {
                            Text(positions[item.id].map { "第 \($0) 位" } ?? "选位置")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(positions[item.id] == nil
                                                 ? Theme.textSecondary : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(positions[item.id] == nil
                                            ? Theme.card : Theme.accent)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                                }
                        }
                    }
                    .padding(8)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            // 顺序预览条：按位次排列已选的图
            if positions.count == items.count {
                HStack(spacing: 8) {
                    ForEach(1...items.count, id: \.self) { pos in
                        if let item = items.first(where: { positions[$0.id] == pos }) {
                            KFImage(item.imageURL)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topLeading) {
                                    Text("\(pos)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Theme.accent)
                                        .clipShape(Circle())
                                        .offset(x: -3, y: -3)
                                }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)
    }

    /// 选位置：目标位次已被占用时与占用者交换
    private func assign(_ figureId: String, _ pos: Int) {
        if let occupant = positions.first(where: { $0.value == pos })?.key, occupant != figureId,
           let current = positions[figureId] {
            positions[occupant] = current
        }
        positions[figureId] = pos
    }
}

// MARK: - 内联填空（官网 write-inline contenteditable）

struct WriteInlineView: View {
    let before: String
    let after: String
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !before.isEmpty {
                Text(before)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            TextField("", text: $text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 80)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                }
                .fixedSize()
            if !after.isEmpty {
                Text(after)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)
    }
}

// MARK: - 描红画板（官网 draw + canvas sketchpad：底图上手绘，支持撤销/换色/清除）

struct DrawBoardView: View {
    let name: String
    let backgroundImageURL: URL?

    @State private var canvasView = PKCanvasView()
    @State private var drawColor: Color = .black
    @State private var tool: PKTool = {
        let tool = PKInkingTool(.pen, color: .black, width: 6)
        return tool
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !name.isEmpty {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            ZStack {
                // 底图（描红参考）
                if let url = backgroundImageURL {
                    KFImage(url)
                        .resizable()
                        .placeholder {
                            Rectangle().fill(.white)
                        }
                        .fade(duration: 0.25)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.white)
                }

                CanvasRepresentable(canvasView: canvasView, tool: $tool)
                    .background(Color.clear)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
            }

            // 工具条：颜色 / 撤销 / 清除（对齐官网 undo / palette）
            HStack(spacing: 14) {
                ForEach([Color.black, .red, .blue, .orange], id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: drawColor == color ? 26 : 20,
                               height: drawColor == color ? 26 : 20)
                        .overlay {
                            if drawColor == color {
                                Circle().stroke(Theme.accent, lineWidth: 2).frame(width: 32, height: 32)
                            }
                        }
                        .onTapGesture {
                            drawColor = color
                            tool = PKInkingTool(.pen, color: UIColor(color), width: 6)
                        }
                }
                Spacer()
                Button {
                    canvasView.undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 17, weight: .medium))
                }
                Button {
                    canvasView.drawing = PKDrawing()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 3)
    }
}

/// PKCanvasView 的 SwiftUI 包装（透明背景、允许手指绘制、外部注入工具）
struct CanvasRepresentable: UIViewRepresentable {
    let canvasView: PKCanvasView
    @Binding var tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.tool = tool
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput   // 允许手指（不要求 Apple Pencil）
        canvasView.overrideUserInterfaceStyle = .light
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = tool
    }
}

// MARK: - 课时视频块（多码率 + iframe 兜底）
//
// 交互说明：未播放时视频中央盖一个 play.circle.fill 播放按钮（样式对齐首页 Cafe
// 视频卡片的封面按钮），提示用户这是视频、可点击；点击直接开播。
// 开始播放后按钮隐藏，系统控制栏照常使用；暂停/播放结束按钮重新出现
// （通过 KVO 监听 AVPlayer.timeControlStatus 同步状态）。

struct LessonVideoBlock: View {
    let title: String
    let sources: [LessonVideoSource]
    let embedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bestSource != nil {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay {
                                ZStack {
                                    // 中央播放按钮（对齐首页封面按钮样式）：仅未播放时显示，
                                    // 播放中移除 overlay，不干扰系统控制栏的点击
                                    if !isPlaying {
                                        Button {
                                            play()
                                        } label: {
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 40))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .shadow(radius: 6)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    // 右上角全屏按钮（常显）
                                    VStack {
                                        HStack {
                                            Spacer()
                                            fullscreenButton
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            .onDisappear { player.pause() }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let embedPath {
                // 兜底：内嵌网页播放器
                EmbeddedPlayer(path: embedPath)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    // 左右留白：之前标题贴卡片左缘，被 cardStyle 的 16pt 圆角裁掉笔画
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
        .cardStyle()
        .padding(.vertical, 4)
        .fullScreenCover(isPresented: $isFullscreen) {
            if let player {
                FullscreenVideoPlayer(player: player, title: title)
            }
        }
        .task(id: bestSource) {
            // AVPlayer 创建移出 body：body 求值期间写 @State 会触发重建循环，加剧转场卡顿
            guard let url = bestSource, player == nil else { return }
            let p = AVPlayer(url: url)
            player = p
            // 监听播放状态：暂停/结束 → 按钮重新出现；播放/缓冲 → 按钮隐藏
            rateObserver = p.observe(\.timeControlStatus, options: [.new]) { pl, _ in
                DispatchQueue.main.async {
                    isPlaying = pl.timeControlStatus != .paused
                }
            }
        }
        .onDisappear {
            rateObserver?.invalidate()
        }
    }

    private func play() {
        player?.play()
    }

    /// 右上角全屏按钮（半透明圆底，对齐全屏组件关闭按钮的样式）
    private var fullscreenButton: some View {
        Button {
            isFullscreen = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
    }

    /// 选最接近 720p 的源
    private var bestSource: URL? {
        guard !sources.isEmpty else { return nil }
        let sorted = sources.sorted {
            abs($0.size - 720) < abs($1.size - 720)
        }
        return sorted.first?.url
    }

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isFullscreen = false
    @State private var rateObserver: NSKeyValueObservation?
}

// MARK: - 音频播放按钮

struct AudioPlayButton: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "waveform.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accentGradient)
                Text(isPlaying ? "播放中…" : "播放音频")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(12)
            .background(Theme.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func toggle() {
        if player == nil {
            player = AVPlayer(url: url)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: player?.currentItem,
                                                   queue: .main) { _ in
                isPlaying = false
            }
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }
}

// MARK: - 单词卡（图片 + 发音）

struct VocabCard: View {
    let caption: String
    let imageURL: URL?
    let audioURL: URL?

    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        Button {
            playAudio()
        } label: {
            HStack(spacing: 14) {
                KFImage(imageURL)
                    .resizable()
                    .placeholder {
                        Rectangle().fill(Color(.systemGray5))
                            .overlay { Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                .frame(width: 84, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(caption)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: "speaker.wave.2.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accentGradient)
            }
            .padding(10)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .onDisappear { audioPlayer?.stop() }
    }

    private func playAudio() {
        guard let audioURL else { return }
        URLSession.shared.dataTask(with: audioURL) { data, _, _ in
            guard let data else { return }
            DispatchQueue.main.async {
                audioPlayer?.stop()
                audioPlayer = try? AVAudioPlayer(data: data)
                audioPlayer?.play()
            }
        }.resume()
    }
}

// MARK: - 翻卡（图 + 覆盖文字）

struct RevealCard: View {
    let imageURL: URL?
    let texts: [String]

    @State private var revealed = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                KFImage(imageURL)
                    .resizable()
                    .placeholder {
                        Rectangle().fill(Color(.systemGray5))
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: .fill)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !revealed {
                    VStack(spacing: 6) {
                        ForEach(texts, id: \.self) { t in
                            Text(t)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Text("点击查看图片")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(20)
                    .background(Theme.card.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .onTapGesture { withAnimation(.spring(response: 0.35)) { revealed.toggle() } }

            if revealed && !texts.isEmpty {
                Text(texts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - 内嵌网页播放器（iframe 兜底）

struct EmbeddedPlayer: View {
    let path: String

    var body: some View {
        WebViewRepresentable(url: SMRTClient.shared.baseURL.appendingPathComponent(path))
    }
}
