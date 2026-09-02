import SwiftUI
import AppKit

// MARK: - 键盘快捷键(删除/撤销重做/全选/方向键)

final class KeyMonitor {
    static func install(state: EditorState) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // 文本输入中不拦截
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView { return e }
            let mods = e.modifierFlags
            if mods.contains(.command) && !mods.contains(.option) {
                switch e.keyCode {
                case 6: // Z
                    Task { @MainActor in
                        if mods.contains(.shift) { state.redo() } else { state.undo() }
                    }
                    return nil
                case 0: // A
                    Task { @MainActor in state.selectAll() }
                    return nil
                default: break
                }
            }
            if e.keyCode == 51 || e.keyCode == 117 { // Delete / Forward delete
                if !state.selectedIDs.isEmpty {
                    Task { @MainActor in state.deleteSelected() }
                    return nil
                }
            }
            let arrows: [UInt16: (Double, Double)] = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)]
            if let (dx, dy) = arrows[e.keyCode] {
                let step = mods.contains(.shift) ? EditorState.gridSize : 1
                Task { @MainActor in state.nudgeSelected(dx: dx * step, dy: dy * step) }
                return nil
            }
            return e
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var state: EditorState
    @StateObject var gen = FluxGenState()
    @State private var wText = "768"
    @State private var hText = "1024"
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Theme.border)
            HSplitView {
                // 左:工具条 + 画布 + 物体列表
                VStack(spacing: 10) {
                    toolBar
                    CanvasAreaView(state: state)
                    ObjectListView(state: state)
                }
                .padding(12)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                // 右:面板
                ScrollView {
                    VStack(spacing: 12) {
                        ImportView(state: state)
                        GlobalFieldsView(state: state)
                        SelectedInfoView(state: state)
                        OutputView(state: state)
                        FluxGenView(state: state, gen: gen)
                        ConfigsView(state: state)
                    }
                    .padding(12)
                }
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 999).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 999))
                    .shadow(radius: 8)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
        // 清除画布确认
        .alert("清除当前画布?", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除画布", role: .destructive) { state.clearCanvas() }
        } message: {
            Text("这会移除所有物体、参考图、描述和已导入的 JSON。画布尺寸与已保存配置不会受到影响。")
        }
        // 更新 JSON 差异确认
        .sheet(item: diffBinding) { item in
            DiffSheet(changes: item.changes,
                      onCancel: { state.cancelUpdatePreview() },
                      onConfirm: { state.confirmUpdate() })
        }
        .onAppear {
            wText = "\(Int(state.imgW))"
            hText = "\(Int(state.imgH))"
        }
        .onChange(of: state.imgW) { _, v in wText = "\(Int(v))" }
        .onChange(of: state.imgH) { _, v in hText = "\(Int(v))" }
    }

    // sheet item 需要 Identifiable
    struct DiffItem: Identifiable { let id = UUID(); let changes: [DiffChange] }
    var diffBinding: Binding<DiffItem?> {
        Binding(get: { state.pendingDiff.map { DiffItem(changes: $0) } },
                set: { if $0 == nil { state.cancelUpdatePreview() } })
    }

    // MARK: 顶栏:品牌 + 画布尺寸 + 参考图
    var topBar: some View {
        HStack(spacing: 12) {
            Text("BBox 位置设计器")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
            Text("· ideogram 4 元素定位")
                .font(.system(size: 12)).foregroundStyle(Theme.dim)

            Divider().frame(height: 18)

            Text("画布尺寸").font(.system(size: 11)).foregroundStyle(Theme.dim)
            dimField($wText, side: "width")
            Text("×").foregroundStyle(Theme.dim)
            dimField($hText, side: "height")
            Text("px").font(.system(size: 11)).foregroundStyle(Theme.dim)

            Picker("比例", selection: $state.ratioValue) {
                ForEach(EditorState.ratios, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 90)
            .onChange(of: state.ratioValue) { _, _ in state.ratioLocked = false }

            Toggle("锁定比例", isOn: Binding(
                get: { state.ratioLocked },
                set: { on in
                    state.ratioLocked = on && state.selectedRatio() != nil
                    if state.ratioLocked { state.applyDimInputs(wText: wText, hText: hText, changedSide: "width") }
                }))
            .font(.system(size: 11)).foregroundStyle(Theme.dim)
            .disabled(state.selectedRatio() == nil)

            Spacer()

            GhostButton(title: "上传参考图") { pickImage() }
            if state.bgImage != nil {
                GhostButton(title: "移除背景") { state.bgImage = nil }
            }
            GhostButton(title: "清除画布") { showClearConfirm = true }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bg.opacity(0.9))
    }

    func dimField(_ text: Binding<String>, side: String) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 52)
            .padding(.vertical, 4)
            .background(Theme.surface2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .onSubmit { state.applyDimInputs(wText: wText, hText: hText, changedSide: side) }
    }

    // MARK: 画布工具条:预设 + 排列 + 工具
    var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 5) {
            ForEach(EditorState.presetSizes, id: \.0) { (w, h) in
                let active = (state.imgW == w && state.imgH == h) || (state.imgW == h && state.imgH == w)
                GhostButton(title: "\(Int(w))×\(Int(h))", active: active) {
                    state.ratioLocked = false
                    state.setDims(w, h)
                    state.recordHistory()
                }
            }
            Divider().frame(height: 16)
            toolGroup("历史") {
                GhostButton(title: "撤销", disabled: !state.canUndo) { state.undo() }
                GhostButton(title: "重做", disabled: !state.canRedo) { state.redo() }
            }
            Divider().frame(height: 16)
            toolGroup("排列") {
                GhostButton(title: "左对齐") { state.applyLayout("left") }
                GhostButton(title: "水平居中") { state.applyLayout("centerX") }
                GhostButton(title: "右对齐") { state.applyLayout("right") }
                GhostButton(title: "上对齐") { state.applyLayout("top") }
                GhostButton(title: "垂直居中") { state.applyLayout("centerY") }
                GhostButton(title: "下对齐") { state.applyLayout("bottom") }
                GhostButton(title: "横向等距") { state.applyLayout("distributeX") }
                GhostButton(title: "纵向等距") { state.applyLayout("distributeY") }
            }
            Divider().frame(height: 16)
            toolGroup("对象") {
                GhostButton(title: "网格吸附", active: state.snapToGrid) {
                    state.snapToGrid.toggle(); state.recordHistory()
                }
                GhostButton(title: "构图参考线", active: state.showGuides) { state.showGuides.toggle() }
                GhostButton(title: "复制") { state.duplicateSelected() }
                GhostButton(title: "锁定") { state.toggleSelectionState(\.locked) }
                GhostButton(title: "隐藏") { state.toggleSelectionState(\.hidden) }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    func toolGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        Text(label).font(.system(size: 10)).foregroundStyle(Theme.dim)
        content()
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            state.bgImage = img
            state.showToast("参考图已就位")
        }
    }
}

// MARK: - 差异确认

struct DiffSheet: View {
    let changes: [DiffChange]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认 JSON 更新").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text("以下更改会写回原始 JSON;确认前不会修改任何内容。")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if changes.isEmpty {
                        Text("没有检测到需要写回的更改。")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    } else {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                            HStack(alignment: .top, spacing: 8) {
                                Text(c.kind.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(kindColor(c.kind).opacity(0.2))
                                    .foregroundStyle(kindColor(c.kind))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(c.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                GhostButton(title: "取消") { onCancel() }
                AccentButton(title: "确认更新", color: Theme.green, disabled: changes.isEmpty) { onConfirm() }
            }
        }
        .padding(16)
        .frame(width: 480)
        .background(Theme.bg)
    }

    func kindColor(_ k: DiffChange.Kind) -> Color {
        switch k {
        case .bbox: return Theme.accent
        case .desc: return Theme.accent2
        case .global: return Theme.yellow
        case .added: return Theme.green
        case .removed: return Theme.red
        }
    }
}

// MARK: - App

@main
struct BBoxDesignerApp: App {
    @StateObject private var state = EditorState()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in
                let code = SelfTest.run()
                exit(code)
            }
        }
        if CommandLine.arguments.contains("--mcptest") {
            Task {
                let client = FluxMCPClient()
                do {
                    try await client.initialize()
                    let tools = try await client.request(method: "tools/list")
                    let names = ((tools["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                    print("MCP OK, tools:", names.joined(separator: ", "))
                    client.stop()
                    exit(0)
                } catch {
                    print("MCP FAIL:", error.localizedDescription)
                    exit(1)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    KeyMonitor.install(state: state)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("粘贴参考图") {
                    if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
                        state.bgImage = img
                        state.showToast("参考图已就位")
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
