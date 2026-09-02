import SwiftUI
import AppKit

// MARK: - 通用小组件

struct SectionCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                Spacer()
            }
            content
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AccentButton: View {
    let title: String
    var color: Color = Theme.accent
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(color.opacity(disabled ? 0.25 : 0.9))
                .foregroundStyle(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct GhostButton: View {
    let title: String
    var active = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(active ? Theme.accent.opacity(0.2) : Theme.surface2)
                .foregroundStyle(active ? Theme.accent : Theme.dim)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct LabeledEditor: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var lines: Int = 2
    var onBegin: () -> Void = {}
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.dim)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(height: CGFloat(lines) * 18 + 10)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: text) { _, _ in onCommit() }
                .onTapGesture { onBegin() }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim.opacity(0.6))
                            .padding(9)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - 色板

struct SwatchView: View {
    let colorHex: String
    var onCopy: () -> Void
    var onChange: (String) -> Void
    @State private var showEditor = false
    @State private var hexDraft = ""
    @State private var nsColor: NSColor = .white

    static let presets: [String] = [
        "#000000","#1F2937","#374151","#6B7280","#9CA3AF","#D1D5DB","#E5E7EB","#FFFFFF",
        "#7C2D12","#DC2626","#FB923C","#FACC15","#84CC16","#34D399","#38BDF8","#A78BFA",
        "#581C87","#831843","#0C1526","#22304D","#8AA0BD","#E8EEFB","#F5F4ED","#E8B04B"
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: Self.nsColor(from: colorHex) ?? .clear))
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .help("\(colorHex) · 点击复制 · 双击修改")
            .onTapGesture(count: 2) {
                hexDraft = colorHex
                nsColor = Self.nsColor(from: colorHex) ?? .white
                showEditor = true
            }
            .onTapGesture(count: 1) { onCopy() }
            .popover(isPresented: $showEditor) {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 8), spacing: 5) {
                        ForEach(Self.presets, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: Self.nsColor(from: c) ?? .clear))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
                                .onTapGesture { onChange(c); showEditor = false }
                        }
                    }
                    HStack {
                        TextField("#RRGGBB", text: $hexDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(5)
                            .background(Theme.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                            .frame(width: 100)
                            .onSubmit {
                                if Self.isValidHex(hexDraft) { onChange(hexDraft.uppercased()); showEditor = false }
                            }
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: nsColor) },
                            set: { c in
                                nsColor = NSColor(c)
                                if let hex = Self.hex(from: nsColor) {
                                    hexDraft = hex
                                    onChange(hex)
                                }
                            }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                .padding(10)
                .background(Theme.surface)
            }
    }

    static func isValidHex(_ s: String) -> Bool {
        s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
    static func nsColor(from hex: String) -> NSColor? {
        guard isValidHex(hex) else { return nil }
        let v = UInt32(hex.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func hex(from color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }
}

// MARK: - 物体列表

struct ObjectListView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        SectionCard(title: "物体列表", trailing: "\(state.boxes.count) 个") {
            HStack(spacing: 6) {
                AccentButton(title: "＋ 添加物体") { state.addBox() }
                GhostButton(title: "删除选中", disabled: state.selectedIDs.isEmpty) { state.deleteSelected() }
                Spacer()
            }
            if state.boxes.isEmpty {
                Text("还没有物体,点「添加物体」或双击画布。")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(state.boxes.enumerated()), id: \.element.id) { index, box in
                            row(index: index, box: box)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    @ViewBuilder
    func row(index: Int, box: BBox) -> some View {
        let active = state.selectedIDs.contains(box.id)
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Theme.bg : Theme.dim)
                .frame(width: 18)
            Text(box.desc.isEmpty ? "未命名物体" : String(box.desc.prefix(22)))
                .font(.system(size: 12))
                .foregroundStyle(active ? Theme.bg : Theme.text)
                .lineLimit(1)
            if box.locked { Text("🔒").font(.system(size: 10)) }
            Spacer()
            Image(systemName: box.hidden ? "eye.slash" : "eye")
                .font(.system(size: 11))
                .foregroundStyle(active ? Theme.bg.opacity(0.8) : (box.hidden ? Theme.red : Theme.dim))
                .onTapGesture { state.toggleBoxHidden(box.id) }
            Text("×")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(active ? Theme.bg.opacity(0.8) : Theme.dim)
                .onTapGesture { state.deleteBox(id: box.id) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? Theme.accent : (box.hidden ? Theme.surface2.opacity(0.5) : Theme.surface2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            state.listSelect(id: box.id,
                             additive: mods.contains(.command) || mods.contains(.control),
                             range: mods.contains(.shift))
        }
    }
}

// MARK: - 选中物体信息

struct SelectedInfoView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        SectionCard(title: "选中物体信息") {
            let n = state.selectedIDs.count
            if n == 0 {
                Text("尚未选中物体。点击画布上的框,或点「添加物体」。")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            } else if n > 1 {
                HStack {
                    Text("已选中 ").font(.system(size: 12)).foregroundStyle(Theme.dim)
                        + Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.yellow)
                        + Text(" 个物体").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Text("拖动任意一个可整体移动 · Delete 批量删除 · 列表 Shift 可范围多选")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            } else if let b = state.focusBox, let idx = state.boxes.firstIndex(where: { $0.id == b.id }) {
                LabeledEditor(
                    label: "物品名称 / 描述 (desc)",
                    text: Binding(get: { state.boxes[idx].desc }, set: { state.boxes[idx].desc = $0 }),
                    placeholder: "例如:A man with short dark hair, wearing a light blue shirt...",
                    lines: 3,
                    onBegin: { state.beginTextHistory() },
                    onCommit: { state.commitTextHistory() }
                )
                HStack(spacing: 10) {
                    coordItem("宽 W", b.w)
                    coordItem("高 H", b.h)
                    coordItem("中心X", b.x + b.w / 2)
                    coordItem("中心Y", b.y + b.h / 2)
                    Spacer()
                }
                // 对象色板:colorPalette + desc 中提取的色号
                let merged = mergedColors(for: b)
                if !merged.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("该对象颜色 (color_palette)").font(.system(size: 11)).foregroundStyle(Theme.dim)
                        HStack(spacing: 5) {
                            ForEach(merged, id: \.self) { c in
                                SwatchView(colorHex: c,
                                           onCopy: { state.copyText(c, "色号已复制") },
                                           onChange: { new in state.changeObjectColor(boxID: b.id, old: c, new: new) })
                            }
                        }
                    }
                }
            }
        }
    }

    func mergedColors(for b: BBox) -> [String] {
        var out: [String] = []
        for c in b.colorPalette.map({ $0.uppercased() }) + EditorState.extractColors(from: b.desc) where !out.contains(c) {
            out.append(c)
        }
        return out
    }

    func coordItem(_ label: String, _ v: Double) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.dim)
            Text("\(Int(v.rounded()))").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
        }
    }
}

// MARK: - 全局/背景 + 风格

struct GlobalFieldsView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        SectionCard(title: "全局 / 背景描述", trailing: "Ideogram4") {
            LabeledEditor(label: "整体描述 (high_level_description)", text: $state.highLevel,
                          placeholder: "例如:A serene portrait of a woman standing by a window, soft light...",
                          lines: 2,
                          onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
            LabeledEditor(label: "背景描述 (background · bbox 固定 [0,0,1000,1000])", text: $state.bgDesc,
                          placeholder: "例如:softly blurred living room, warm afternoon light through curtains...",
                          lines: 2,
                          onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
        }

        SectionCard(title: "风格描述 (style_description)", trailing: "可选") {
            Picker("类型(photo 或 art_style,二者其一)", selection: $state.styleType) {
                Text("不指定(省略 style_description)").tag(StyleType.none)
                Text("photo · 写实摄影").tag(StyleType.photo)
                Text("art_style · 插画 / 渲染").tag(StyleType.artStyle)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: state.styleType) { _, _ in state.commitTextHistory() }

            if state.styleType != .none {
                LabeledEditor(label: "aesthetics", text: $state.aesthetics, lines: 1,
                              onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
                LabeledEditor(label: "lighting", text: $state.lighting, lines: 1,
                              onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
                LabeledEditor(label: "medium", text: $state.medium, lines: 1,
                              onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
                LabeledEditor(label: "color_palette(逗号分隔色值)", text: $state.paletteText, lines: 1,
                              onBegin: { state.beginTextHistory() }, onCommit: { state.commitTextHistory() })
                let palette = state.paletteText.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { SwatchView.isValidHex($0) }
                if !palette.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { i, c in
                            SwatchView(colorHex: c.uppercased(),
                                       onCopy: { state.copyText(c.uppercased(), "色号已复制") },
                                       onChange: { new in state.changeOverallColor(index: i, new: new) })
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 导入 JSON

struct ImportView: View {
    @ObservedObject var state: EditorState
    @State private var showFileImporter = false

    var body: some View {
        SectionCard(title: "导入 ideogram 4 JSON 提示词", trailing: state.parsedCount > 0 ? "\(state.parsedCount) 个" : "解析") {
            Text("粘贴提示词 JSON(支持 bbox / elements / type / desc 等字段)")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
            TextEditor(text: $state.pasteText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                AccentButton(title: "解析并加载") { state.parse(state.pasteText) }
                GhostButton(title: "选择 JSON") { showFileImporter = true }
                Spacer()
            }
            if let err = state.parseError {
                Text(err).font(.system(size: 11)).foregroundStyle(Theme.red)
            }
            // 解析详情
            if let meta = state.parsedMeta, meta.hasContent {
                VStack(alignment: .leading, spacing: 8) {
                    if let hl = meta.highLevel {
                        metaBlock("整体描述", hl)
                    }
                    if !meta.stylePairs.isEmpty || !meta.stylePalette.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("风格描述").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent2)
                            ForEach(meta.stylePairs, id: \.0) { k, v in
                                Text("\(k): ").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                                    + Text(v).font(.system(size: 11)).foregroundStyle(Theme.dim)
                            }
                            if !meta.stylePalette.isEmpty {
                                HStack(spacing: 5) {
                                    ForEach(Array(meta.stylePalette.enumerated()), id: \.offset) { i, c in
                                        if SwatchView.isValidHex(c) {
                                            SwatchView(colorHex: c.uppercased(),
                                                       onCopy: { state.copyText(c.uppercased(), "色号已复制") },
                                                       onChange: { new in state.changeOverallColor(index: i, new: new) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let bg = meta.background {
                        metaBlock("背景描述", bg)
                    }
                }
                .padding(8)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 6) {
                AccentButton(title: "更新提示词", color: Theme.green, disabled: state.parsedSource == nil) {
                    state.openUpdatePreview()
                }
                GhostButton(title: "复制", disabled: state.pasteText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    state.copyText(state.pasteText)
                }
                Spacer()
            }
            Text("点「更新提示词」把调整后的 bbox 写回原始 JSON,再点「复制」即可拿去重新生成图片。")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, let text = try? String(contentsOf: url, encoding: .utf8) {
                state.pasteText = text
                state.parse(text)
            }
        }
    }

    func metaBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent2)
            Text(body).font(.system(size: 11)).foregroundStyle(Theme.dim)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 输出 JSON

struct OutputView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        SectionCard(title: "输出 JSON") {
            ScrollView {
                Text(state.outputString())
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 220)
            .background(Theme.surface2)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                AccentButton(title: "复制 caption") { state.copyCaption() }
                GhostButton(title: "复制为提示词") { state.copyAsPrompt() }
                Spacer()
            }
        }
    }
}

// MARK: - 配置管理

struct ConfigsView: View {
    @ObservedObject var state: EditorState
    @State private var name = ""
    @State private var selected: Double? = nil

    var body: some View {
        SectionCard(title: "配置管理", trailing: "\(state.configs.count)") {
            HStack {
                TextField("配置名称,例如:人像构图 v1", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(6)
                    .background(Theme.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                AccentButton(title: "保存配置") {
                    state.saveConfig(name: name)
                    name = ""
                }
            }
            if !state.configs.isEmpty {
                Picker("已保存配置", selection: $selected) {
                    Text("选择配置…").tag(nil as Double?)
                    ForEach(state.configs, id: \.id) { c in
                        Text(c.name).tag(c.id as Double?)
                    }
                }
                .labelsHidden()
                HStack(spacing: 6) {
                    GhostButton(title: "还原", disabled: selected == nil) {
                        if let id = selected { state.restoreConfig(id: id) }
                    }
                    GhostButton(title: "删除", disabled: selected == nil) {
                        if let id = selected { state.deleteConfig(id: id); selected = nil }
                    }
                    Spacer()
                }
            }
        }
        .onAppear { state.loadConfigsFromDisk() }
    }
}

// MARK: - FLUX 生成

struct FluxGenView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var gen: FluxGenState

    var body: some View {
        SectionCard(title: "本地生成 · FLUX.2-klein", trailing: gen.mcpAvailable ? "MCP ✓" : "MCP 未找到") {
            if !gen.mcpAvailable {
                Text("未找到 FluxKleinStudio.app(~/Desktop/FluxKleinStudio.app)。请先安装 flux-klein-studio。")
                    .font(.system(size: 11)).foregroundStyle(Theme.red)
            } else {
                HStack(spacing: 6) {
                    GhostButton(title: "从画布生成提示词") { gen.flattenPrompt(from: state) }
                    Spacer()
                }
                TextEditor(text: $gen.prompt)
                    .font(.system(size: 11))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Theme.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 10) {
                    Stepper("步数 \(gen.steps)", value: $gen.steps, in: 1...50)
                        .font(.system(size: 11))
                    Stepper("seed \(gen.seed == -1 ? "随机" : "\(gen.seed)")", value: $gen.seed, in: -1...999999)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.dim)
                HStack {
                    Picker("量化", selection: $gen.quantize) {
                        Text("4bit").tag(4); Text("8bit").tag(8); Text("16bit").tag(16)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Toggle("设为参考图", isOn: $gen.setAsReference)
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Spacer()
                }
                HStack(spacing: 6) {
                    if gen.status == .generating {
                        ProgressView().controlSize(.small)
                        Text("生成中…(首次加载模型需 1–3 分钟)")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    } else {
                        AccentButton(title: "生成图片", color: Theme.accent2, disabled: gen.prompt.trimmingCharacters(in: .whitespaces).isEmpty) {
                            let w = state.imgW, h = state.imgH
                            Task { await gen.generate(canvasW: w, canvasH: h, editor: state) }
                        }
                    }
                    if let p = gen.resultPath {
                        GhostButton(title: "在 Finder 显示") { gen.revealInFinder() }
                        let _ = p
                    }
                    Spacer()
                }
                if case .failed(let msg) = gen.status {
                    Text(msg).font(.system(size: 11)).foregroundStyle(Theme.red)
                }
                if let img = gen.resultImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
            }
        }
    }
}
