import Foundation
import SwiftUI
import AppKit

// MARK: - 模型

struct BBox: Identifiable, Equatable {
    var id: Int
    var x: Double, y: Double, w: Double, h: Double
    var desc: String = ""
    var type: String = "obj"
    var locked: Bool = false
    var hidden: Bool = false
    var colorPalette: [String] = []
    /// 指向解析源 elements 数组中的下标(JS 里的 srcRef),nil 表示解析后新增
    var srcIndex: Int? = nil
}

enum StyleType: String, CaseIterable, Equatable {
    case none, photo, artStyle = "art_style"
}

struct DiffChange: Equatable {
    enum Kind: String { case bbox = "BBox", desc = "描述", global = "全局字段", added = "新增物体", removed = "删除物体" }
    var kind: Kind
    var text: String
}

/// 撤销/重做快照(等价网页版 captureEditorState)
struct Snapshot: Equatable {
    var imgW: Double, imgH: Double
    var ratioValue: String, ratioLocked: Bool
    var boxes: [BBox]
    var focusID: Int?
    var selectedIDs: [Int]
    var highLevel: String, bgDesc: String
    var styleType: StyleType
    var aesthetics: String, lighting: String, medium: String, paletteText: String
    var pasteText: String
    var parsedSource: JVal?
    var parsedElArrayPath: [String]?
    var sourceRefIndexes: [Int]
    var showingSource: Bool
    var parsedCount: Int
    var snapToGrid: Bool
}

struct ParsedMeta {
    var highLevel: String?
    var stylePairs: [(String, String)] = []
    var stylePalette: [String] = []
    var background: String?
    var hasContent: Bool { highLevel != nil || !stylePairs.isEmpty || !stylePalette.isEmpty || background != nil }
}

// MARK: - EditorState

@MainActor
final class EditorState: ObservableObject {
    static let dimensionStep = 64.0
    static let gridSize = 20.0
    static let minBox = 20.0
    static let historyLimit = 80

    // 画布
    @Published var imgW: Double = 768
    @Published var imgH: Double = 1024
    @Published var ratioValue: String = "free"
    @Published var ratioLocked: Bool = false
    @Published var boxes: [BBox] = []
    @Published var selectedIDs: Set<Int> = []
    @Published var focusID: Int? = nil
    @Published var snapToGrid = false
    @Published var showGuides = false
    @Published var bgImage: NSImage? = nil

    // 全局/背景/风格
    @Published var highLevel = ""
    @Published var bgDesc = ""
    @Published var styleType: StyleType = .none
    @Published var aesthetics = ""
    @Published var lighting = ""
    @Published var medium = ""
    @Published var paletteText = ""

    // 导入 JSON
    @Published var pasteText = ""
    @Published var parseError: String? = nil
    @Published var parsedSource: JVal? = nil
    @Published var parsedElArrayPath: [String]? = nil  // 元素数组在源对象里的路径
    @Published var parsedCount: Int = 0
    @Published var showingSource = false
    @Published var parsedMeta: ParsedMeta? = nil
    @Published var pendingDiff: [DiffChange]? = nil   // 非 nil 时弹确认面板

    // 输出
    @Published var toast: String? = nil

    // 历史
    private(set) var history: [Snapshot] = []
    private(set) var historyIndex: Int = -1
    private var historyReady = false
    private var textHistoryBase: Snapshot? = nil
    private var textHistoryTask: Task<Void, Never>? = nil
    private var toastTask: Task<Void, Never>? = nil

    // 画布交互瞬态
    enum DragMode: Equatable { case none, move, resize(String), marquee(additive: Bool) }
    var dragMode: DragMode = .none
    var dragStart: CGPoint = .zero
    var moveOrigins: [Int: CGPoint] = [:]
    var resizeOrig: CGRect = .zero
    @Published var marqueeRect: CGRect? = nil

    private var uid = 0
    private var listAnchorID: Int? = nil

    static let presetSizes: [(Double, Double)] = [
        (1024, 1024), (1344, 768), (1408, 704), (768, 1024), (768, 1152), (896, 1152), (960, 1280)
    ]
    static let ratios: [(String, String)] = [
        ("free", "自由比例"), ("16:9", "16:9"), ("9:16", "9:16"), ("1:1", "1:1"),
        ("4:3", "4:3"), ("3:4", "3:4"), ("3:2", "3:2"), ("2:3", "2:3"), ("4:5", "4:5"), ("5:4", "5:4")
    ]

    init() { resetHistory() }

    // MARK: 基础工具
    func normalizeDimension(_ v: Double, fallback: Double = 64) -> Double {
        guard v.isFinite else { return fallback }
        return max(EditorState.dimensionStep, (v / EditorState.dimensionStep).rounded() * EditorState.dimensionStep)
    }
    func snap(_ v: Double) -> Double { snapToGrid ? (v / EditorState.gridSize).rounded() * EditorState.gridSize : v }
    func clampD(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
    var focusBox: BBox? { selectedIDs.count == 1 ? boxes.first(where: { $0.id == focusID }) : nil }
    func showToast(_ msg: String) {
        toastTask?.cancel()
        toast = msg
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    func copyText(_ s: String, _ msg: String = "已复制到剪贴板") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        showToast(msg)
    }

    // MARK: 尺寸
    func setDims(_ w: Double, _ h: Double) {
        if ProcessInfo.processInfo.arguments.contains("--dimtrace") {
            print("setDims", w, h, "caller:", Thread.callStackSymbols.dropFirst(2).prefix(2).joined(separator: " | "))
        }
        imgW = normalizeDimension(w, fallback: imgW)
        imgH = normalizeDimension(h, fallback: imgH)
        showingSource = false
        clampBoxes()
    }
    func applyDimInputs(wText: String, hText: String, changedSide: String) {
        var w = normalizeDimension(Double(wText) ?? .nan, fallback: imgW)
        var h = normalizeDimension(Double(hText) ?? .nan, fallback: imgH)
        if ratioLocked, let r = selectedRatio() {
            if changedSide == "height" { w = normalizeDimension(h * r, fallback: imgW) }
            else { h = normalizeDimension(w / r, fallback: imgH) }
        }
        setDims(w, h)
        recordHistory()
    }
    func selectedRatio() -> Double? {
        guard ratioValue != "free" else { return nil }
        let parts = ratioValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    func clampBoxes() {
        for i in boxes.indices {
            boxes[i].w = clampD(boxes[i].w, EditorState.minBox, imgW)
            boxes[i].h = clampD(boxes[i].h, EditorState.minBox, imgH)
            boxes[i].x = clampD(boxes[i].x, 0, imgW - boxes[i].w)
            boxes[i].y = clampD(boxes[i].y, 0, imgH - boxes[i].h)
        }
    }

    // MARK: 物体操作
    @discardableResult
    func addBox(at p: CGPoint? = nil) -> BBox {
        showingSource = false
        let w = (imgW * 0.3).rounded(), h = (imgH * 0.3).rounded()
        var x = p.map { $0.x - w / 2 } ?? (imgW / 2 - w / 2)
        var y = p.map { $0.y - h / 2 } ?? (imgH / 2 - h / 2)
        x = clampD(x, 0, imgW - w); y = clampD(y, 0, imgH - h)
        uid += 1
        let b = BBox(id: uid, x: x, y: y, w: w, h: h)
        boxes.append(b)
        selectedIDs = [b.id]
        focusID = b.id
        recordHistory()
        return b
    }

    func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        boxes.removeAll { selectedIDs.contains($0.id) }
        selectedIDs.removeAll()
        focusID = nil
        showingSource = false
        recordHistory()
    }
    func deleteBox(id: Int) {
        boxes.removeAll { $0.id == id }
        selectedIDs.remove(id)
        if focusID == id { focusID = selectedIDs.first }
        if listAnchorID == id { listAnchorID = focusID }
        recordHistory()
    }
    func selectAll() {
        guard !boxes.isEmpty else { return }
        selectedIDs = Set(boxes.map { $0.id })
        focusID = boxes.last?.id
        listAnchorID = focusID
    }

    func movableSelection() -> [BBox] { boxes.filter { selectedIDs.contains($0.id) && !$0.locked && !$0.hidden } }

    func nudgeSelected(dx: Double, dy: Double) {
        let movable = movableSelection()
        guard !movable.isEmpty else { return }
        for b in movable {
            if let i = boxes.firstIndex(where: { $0.id == b.id }) {
                boxes[i].x = clampD(boxes[i].x + dx, 0, imgW - boxes[i].w)
                boxes[i].y = clampD(boxes[i].y + dy, 0, imgH - boxes[i].h)
            }
        }
        recordHistory()
    }

    func applyLayout(_ mode: String) {
        let items = movableSelection()
        guard items.count >= 2 else { showToast("请选择至少两个未锁定物体"); return }
        let left = items.map { $0.x }.min()!, right = items.map { $0.x + $0.w }.max()!
        let top = items.map { $0.y }.min()!, bottom = items.map { $0.y + $0.h }.max()!
        func setX(_ b: BBox, _ v: Double) { if let i = boxes.firstIndex(where: { $0.id == b.id }) { boxes[i].x = v } }
        func setY(_ b: BBox, _ v: Double) { if let i = boxes.firstIndex(where: { $0.id == b.id }) { boxes[i].y = v } }
        switch mode {
        case "left": items.forEach { setX($0, left) }
        case "right": items.forEach { setX($0, right - $0.w) }
        case "centerX": let x = (left + right) / 2; items.forEach { setX($0, x - $0.w / 2) }
        case "top": items.forEach { setY($0, top) }
        case "bottom": items.forEach { setY($0, bottom - $0.h) }
        case "centerY": let y = (top + bottom) / 2; items.forEach { setY($0, y - $0.h / 2) }
        case "distributeX":
            guard items.count >= 3 else { showToast("横向等距需要至少三个物体"); return }
            let ordered = items.sorted { $0.x < $1.x }
            let gap = (right - left - ordered.reduce(0) { $0 + $1.w }) / Double(ordered.count - 1)
            var x = left
            for b in ordered { setX(b, x); x += b.w + gap }
        case "distributeY":
            guard items.count >= 3 else { showToast("纵向等距需要至少三个物体"); return }
            let ordered = items.sorted { $0.y < $1.y }
            let gap = (bottom - top - ordered.reduce(0) { $0 + $1.h }) / Double(ordered.count - 1)
            var y = top
            for b in ordered { setY(b, y); y += b.h + gap }
        default: return
        }
        for i in boxes.indices {
            boxes[i].x = clampD(snap(boxes[i].x), 0, imgW - boxes[i].w)
            boxes[i].y = clampD(snap(boxes[i].y), 0, imgH - boxes[i].h)
        }
        showingSource = false
        recordHistory()
    }

    func duplicateSelected() {
        let items = boxes.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else { showToast("请先选择物体"); return }
        var copies: [BBox] = []
        for var b in items {
            uid += 1
            b.id = uid
            b.x = clampD(b.x + EditorState.gridSize, 0, imgW - b.w)
            b.y = clampD(b.y + EditorState.gridSize, 0, imgH - b.h)
            b.srcIndex = nil; b.locked = false; b.hidden = false
            copies.append(b)
        }
        boxes.append(contentsOf: copies)
        selectedIDs = Set(copies.map { $0.id })
        focusID = copies.first?.id
        showingSource = false
        recordHistory()
    }

    func toggleSelectionState(_ key: WritableKeyPath<BBox, Bool>) {
        let items = boxes.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else { showToast("请先选择物体"); return }
        let next = !items.allSatisfy { $0[keyPath: key] }
        for i in boxes.indices where selectedIDs.contains(boxes[i].id) { boxes[i][keyPath: key] = next }
        recordHistory()
    }
    func toggleBoxHidden(_ id: Int) {
        guard let target = boxes.first(where: { $0.id == id }) else { return }
        if selectedIDs.contains(id) && selectedIDs.count > 1 {
            let newHidden = !target.hidden
            for i in boxes.indices where selectedIDs.contains(boxes[i].id) { boxes[i].hidden = newHidden }
        } else if let i = boxes.firstIndex(where: { $0.id == id }) {
            boxes[i].hidden.toggle()
        }
        recordHistory()
    }

    /// 列表点击选择(支持 Cmd 加选 / Shift 范围选择)
    func listSelect(id: Int, additive: Bool, range: Bool) {
        guard let idx = boxes.firstIndex(where: { $0.id == id }) else { return }
        if range, let anchor = listAnchorID, let aIdx = boxes.firstIndex(where: { $0.id == anchor }) {
            let lo = min(aIdx, idx), hi = max(aIdx, idx)
            if !additive { selectedIDs.removeAll() }
            for i in lo...hi { selectedIDs.insert(boxes[i].id) }
            focusID = id
        } else if additive {
            if selectedIDs.contains(id) {
                if selectedIDs.count > 1 {
                    selectedIDs.remove(id)
                    if focusID == id { focusID = selectedIDs.first }
                }
            } else {
                selectedIDs.insert(id)
                focusID = id
            }
            listAnchorID = id
        } else {
            selectedIDs = [id]
            focusID = id
            listAnchorID = id
        }
    }

    func clearCanvas() {
        boxes = []; selectedIDs = []; focusID = nil; uid = 0
        bgImage = nil
        highLevel = ""; bgDesc = ""; styleType = .none
        aesthetics = ""; lighting = ""; medium = ""; paletteText = ""
        pasteText = ""; parseError = nil
        parsedSource = nil; parsedElArrayPath = nil; parsedCount = 0
        showingSource = false; parsedMeta = nil
        recordHistory()
        showToast("画布已清除,可以开始新设计。")
    }

    // MARK: 画布手势
    func canvasPoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x / size.width * imgW, y: p.y / size.height * imgH)
    }

    func boxDown(_ b: BBox, at p: CGPoint, additive: Bool) {
        showingSource = false
        if additive {
            if selectedIDs.contains(b.id) {
                if selectedIDs.count > 1 {
                    selectedIDs.remove(b.id)
                    if focusID == b.id { focusID = selectedIDs.first }
                }
            } else {
                selectedIDs.insert(b.id)
                focusID = b.id
            }
        } else {
            if !selectedIDs.contains(b.id) { selectedIDs = [b.id] }
            focusID = b.id
        }
        dragMode = .move
        dragStart = p
        moveOrigins = [:]
        for m in movableSelection() { moveOrigins[m.id] = CGPoint(x: m.x, y: m.y) }
    }
    func moveDragged(to p: CGPoint) {
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        for (id, orig) in moveOrigins {
            if let i = boxes.firstIndex(where: { $0.id == id }) {
                boxes[i].x = clampD(snap(orig.x + dx), 0, imgW - boxes[i].w)
                boxes[i].y = clampD(snap(orig.y + dy), 0, imgH - boxes[i].h)
            }
        }
    }
    func endDrag() {
        var wasEdit = false
        switch dragMode {
        case .move, .resize: wasEdit = true
        default: break
        }
        dragMode = .none
        moveOrigins = [:]
        if wasEdit { recordHistory() }
    }

    func resizeBegan(_ b: BBox, handle: String) {
        showingSource = false
        dragMode = .resize(handle)
        resizeOrig = CGRect(x: b.x, y: b.y, width: b.w, height: b.h)
    }
    func resizeDragged(id: Int, handle: String, to p: CGPoint) {
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        var x1 = resizeOrig.minX, y1 = resizeOrig.minY
        var x2 = resizeOrig.maxX, y2 = resizeOrig.maxY
        if handle.contains("w") { x1 = p.x }
        if handle.contains("e") { x2 = p.x }
        if handle.contains("n") { y1 = p.y }
        if handle.contains("s") { y2 = p.y }
        x1 = clampD(x1, 0, imgW - 1); x2 = clampD(x2, 1, imgW)
        y1 = clampD(y1, 0, imgH - 1); y2 = clampD(y2, 1, imgH)
        let MIN = EditorState.minBox
        if x2 - x1 < MIN { if handle.contains("w") { x1 = x2 - MIN } else { x2 = x1 + MIN } }
        if y2 - y1 < MIN { if handle.contains("n") { y1 = y2 - MIN } else { y2 = y1 + MIN } }
        if snapToGrid {
            x1 = clampD(snap(x1), 0, imgW - MIN); x2 = clampD(snap(x2), x1 + MIN, imgW)
            y1 = clampD(snap(y1), 0, imgH - MIN); y2 = clampD(snap(y2), y1 + MIN, imgH)
        }
        boxes[i].x = x1; boxes[i].y = y1; boxes[i].w = x2 - x1; boxes[i].h = y2 - y1
    }

    func marqueeBegan(at p: CGPoint, additive: Bool) {
        showingSource = false
        if !additive { selectedIDs.removeAll(); focusID = nil }
        dragMode = .marquee(additive: additive)
        dragStart = p
        marqueeRect = CGRect(origin: p, size: .zero)
    }
    func marqueeDragged(to p: CGPoint) {
        let x = min(dragStart.x, p.x), y = min(dragStart.y, p.y)
        marqueeRect = CGRect(x: x, y: y, width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
    }
    func marqueeEnded(additive: Bool) {
        guard let r = marqueeRect else { dragMode = .none; return }
        defer { dragMode = .none; marqueeRect = nil }
        if r.width < 2 && r.height < 2 {
            if !additive { selectedIDs.removeAll(); focusID = nil }
            return
        }
        // 中心点命中检测
        var hits: [Int] = []
        for b in boxes where !b.hidden {
            let cx = b.x + b.w / 2, cy = b.y + b.h / 2
            if cx >= r.minX && cx <= r.maxX && cy >= r.minY && cy <= r.maxY { hits.append(b.id) }
        }
        if additive {
            for id in hits {
                if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            }
        } else {
            selectedIDs.removeAll()
            for id in hits { selectedIDs.insert(id) }
        }
        var focus: Int? = nil
        for id in hits.reversed() where selectedIDs.contains(id) { focus = id; break }
        focusID = focus ?? selectedIDs.first
    }

    func doubleTapCanvas(at p: CGPoint) {
        showingSource = false
        for b in boxes {
            if p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h {
                if !selectedIDs.contains(b.id) { selectedIDs = [b.id] }
                focusID = b.id
                return
            }
        }
        addBox(at: p)
    }

    // MARK: 历史
    func captureSnapshot() -> Snapshot {
        Snapshot(imgW: imgW, imgH: imgH, ratioValue: ratioValue, ratioLocked: ratioLocked,
                 boxes: boxes, focusID: focusID, selectedIDs: Array(selectedIDs),
                 highLevel: highLevel, bgDesc: bgDesc, styleType: styleType,
                 aesthetics: aesthetics, lighting: lighting, medium: medium, paletteText: paletteText,
                 pasteText: pasteText, parsedSource: parsedSource, parsedElArrayPath: parsedElArrayPath,
                 sourceRefIndexes: boxes.map { $0.srcIndex ?? -1 },
                 showingSource: showingSource, parsedCount: parsedCount, snapToGrid: snapToGrid)
    }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    func recordHistory() {
        guard historyReady else { return }
        let next = captureSnapshot()
        if historyIndex >= 0 && history[historyIndex] == next { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(next)
        if history.count > EditorState.historyLimit { history.removeFirst() }
        historyIndex = history.count - 1
    }
    func resetHistory() {
        history = [captureSnapshot()]
        historyIndex = 0
        historyReady = true
    }
    func restore(_ s: Snapshot) {
        imgW = s.imgW; imgH = s.imgH
        ratioValue = s.ratioValue; ratioLocked = s.ratioLocked
        boxes = s.boxes
        selectedIDs = Set(s.selectedIDs.filter { id in boxes.contains(where: { $0.id == id }) })
        focusID = s.focusID.flatMap { selectedIDs.contains($0) ? $0 : nil } ?? selectedIDs.first
        highLevel = s.highLevel; bgDesc = s.bgDesc; styleType = s.styleType
        aesthetics = s.aesthetics; lighting = s.lighting; medium = s.medium; paletteText = s.paletteText
        pasteText = s.pasteText
        parsedSource = s.parsedSource
        parsedElArrayPath = s.parsedElArrayPath
        parsedCount = s.parsedCount
        showingSource = s.showingSource
        snapToGrid = s.snapToGrid
        if parsedSource != nil {
            parsedMeta = makeMeta(parsedSource!)
        } else {
            parsedMeta = nil
        }
        uid = boxes.map { $0.id }.max() ?? 0
        clampBoxes()
    }
    func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        restore(history[historyIndex])
    }
    func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        restore(history[historyIndex])
    }

    /// 文本字段聚焦时调用:记录文本编辑前的基线
    func beginTextHistory() {
        guard historyReady, textHistoryBase == nil else { return }
        textHistoryBase = captureSnapshot()
    }
    /// 文本字段输入时调用(防抖 0.45s 提交)
    func commitTextHistory() {
        textHistoryTask?.cancel()
        textHistoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, let base = self.textHistoryBase else { return }
            let current = self.captureSnapshot()
            if current != base {
                self.history.removeSubrange((self.historyIndex + 1)...)
                self.history.append(base)
                self.historyIndex = self.history.count - 1
                self.recordHistory()
            }
            self.textHistoryBase = nil
        }
    }

    // MARK: Ideogram 4 输出
    /// 像素 bbox → 0-1000 归一化,轴序 [ymin,xmin,ymax,xmax]
    func normToIdeogram(_ b: BBox) -> [Int] {
        let cx: (Double) -> Int = { v in Int(self.clampD((v / self.imgW * 1000).rounded(), 0, 1000)) }
        let cy: (Double) -> Int = { v in Int(self.clampD((v / self.imgH * 1000).rounded(), 0, 1000)) }
        return [cy(b.y), cx(b.x), cy(b.y + b.h), cx(b.x + b.w)]
    }

    func buildStyle() -> JVal? {
        guard styleType != .none else { return nil }
        let aes = aesthetics.trimmingCharacters(in: .whitespaces)
        let lig = lighting.trimmingCharacters(in: .whitespaces)
        let med = medium.trimmingCharacters(in: .whitespaces)
        let palette = paletteText.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        var pairs: [(String, JVal)] = []
        if !aes.isEmpty { pairs.append(("aesthetics", .str(aes))) }
        if !lig.isEmpty { pairs.append(("lighting", .str(lig))) }
        // 按 CaptionVerifier 要求的键顺序
        if styleType == .photo {
            pairs.append(("photo", .bool(true)))
            if !med.isEmpty { pairs.append(("medium", .str(med))) }
        } else {
            if !med.isEmpty { pairs.append(("medium", .str(med))) }
            pairs.append(("art_style", .bool(true)))
        }
        if !palette.isEmpty { pairs.append(("color_palette", .arr(palette.map { .str($0) }))) }
        return .obj(pairs)
    }

    func buildCaption() -> JVal {
        var elements: [JVal] = []
        for b in boxes {
            var pairs: [(String, JVal)] = [("type", .str(b.type)), ("bbox", .arr(normToIdeogram(b).map { .num(Double($0)) }))]
            let d = b.desc.trimmingCharacters(in: .whitespaces)
            if !d.isEmpty { pairs.append(("description", .str(d))) }
            if !b.colorPalette.isEmpty { pairs.append(("color_palette", .arr(b.colorPalette.map { .str($0) }))) }
            elements.append(.obj(pairs))
        }
        var bgPairs: [(String, JVal)] = [("bbox", .arr([0, 0, 1000, 1000].map { .num($0) }))]
        let bg = bgDesc.trimmingCharacters(in: .whitespaces)
        if !bg.isEmpty { bgPairs.append(("description", .str(bg))) }
        let comp: JVal = .obj([("background", .obj(bgPairs)), ("elements", .arr(elements))])
        var out: [(String, JVal)] = []
        let hl = highLevel.trimmingCharacters(in: .whitespaces)
        if !hl.isEmpty { out.append(("high_level_description", .str(hl))) }
        if let st = buildStyle() { out.append(("style_description", st)) }
        out.append(("compositional_deconstruction", comp))
        return .obj(out)
    }

    func outputJSON() -> JVal {
        if showingSource, let src = parsedSource { return src }
        return buildCaption()
    }
    func outputString() -> String { JValWriter.compact(outputJSON()) }

    func copyCaption() { copyText(JValWriter.compact(buildCaption())) }
    func copyAsPrompt() {
        let lines = boxes.map { b -> String in
            let bbox = [b.x, b.y, b.x + b.w, b.y + b.h].map { JVal.formatNumber($0.rounded()) }
            return "- bbox [\(bbox.joined(separator: ","))]: \(b.desc.isEmpty ? "(待补充描述)" : b.desc)"
        }.joined(separator: "\n")
        copyText("请基于以下元素布局,为 ideogram 4 完善每个物体的详细提示词:\n" + lines)
    }

    // MARK: 导入解析
    private func makeMeta(_ data: JVal) -> ParsedMeta {
        var meta = ParsedMeta()
        if let hl = data.first(["high_level_description", "prompt", "description"])?.stringValue { meta.highLevel = hl }
        if let style = data.first(["style_description", "style"]), style.isObject {
            if case .obj(let pairs) = style {
                for (k, v) in pairs where k != "color_palette" {
                    meta.stylePairs.append((k, v.stringValue ?? JValWriter.compact(v)))
                }
            }
            if let pal = style["color_palette"]?.arrayValue {
                meta.stylePalette = pal.compactMap { $0.stringValue }
            }
        }
        if let bg = data.first(["compositional_deconstruction", "background"]).flatMap({ $0["background"] }) {
            meta.background = bg.first(["description", "desc"])?.stringValue
        } else if let bg = data["background"] {
            meta.background = bg.stringValue ?? bg.first(["description", "desc"])?.stringValue
        }
        return meta
    }

    /// 在源对象中定位 elements 数组:兼容 compositional_deconstruction.elements / elements / objects / boxes
    private func extractElementArray(_ data: JVal) -> (array: [JVal], path: [String])? {
        for key in ["elements", "objects", "boxes"] {
            if let a = data[key]?.arrayValue { return (a, [key]) }
        }
        if let cd = data["compositional_deconstruction"], let a = cd["elements"]?.arrayValue {
            return (a, ["compositional_deconstruction", "elements"])
        }
        return nil
    }

    private func parsedElArray() -> [JVal]? {
        guard let src = parsedSource, let path = parsedElArrayPath else { return nil }
        if path.count == 1 { return src[path[0]]?.arrayValue }
        if path.count == 2 { return src[path[0]]?[path[1]]?.arrayValue }
        return nil
    }

    func parse(_ text: String) {
        parseError = nil
        parsedSource = nil; parsedElArrayPath = nil; showingSource = false
        parsedCount = 0; parsedMeta = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseError = "未检测到有效的 JSON 内容"; return
        }
        guard let data = JValParser.parseLoose(text) else {
            parseError = "JSON 解析失败"; return
        }
        guard data.isObject else { parseError = "未检测到有效的 JSON 内容"; return }

        guard let (elArray, path) = extractElementArray(data) else {
            parseError = "未找到可解析的元素"
            parsedSource = data
            parsedMeta = makeMeta(data)
            backfillGlobals(from: data)
            return
        }
        struct El { var rawIndex: Int; var bbox: [Double]; var desc: String; var type: String; var colorPalette: [String] }
        var elems: [El] = []
        for (idx, raw) in elArray.enumerated() {
            guard raw.isObject else { continue }
            guard let rawArr = raw.first(["bbox", "box", "bndbox", "coordinates", "rect", "xyxy"])?.arrayValue, rawArr.count >= 4 else { continue }
            let c = rawArr.prefix(4).compactMap { $0.doubleValue }
            guard c.count == 4 else { continue }
            // Ideogram4: [ymin,xmin,ymax,xmax] @0-1000 → 画布像素
            let x1 = c[1] / 1000 * imgW, y1 = c[0] / 1000 * imgH
            let x2 = c[3] / 1000 * imgW, y2 = c[2] / 1000 * imgH
            let desc = raw.first(["desc", "description", "label", "name", "caption"])?.stringValue ?? ""
            let type = raw.first(["type", "category", "class"])?.stringValue ?? "obj"
            let cp = raw.first(["color_palette", "colors", "palette"])?.arrayValue?.compactMap { $0.stringValue } ?? []
            elems.append(El(rawIndex: idx, bbox: [x1, y1, x2, y2], desc: desc, type: type, colorPalette: cp))
        }
        if elems.isEmpty {
            parseError = "未找到可解析的元素"
            parsedSource = data
            parsedMeta = makeMeta(data)
            backfillGlobals(from: data)
            return
        }
        // 反归一化后理论上必落在画布内;若确实超出则扩展画布(保持 64 倍数)
        let maxX = elems.map { $0.bbox[2] }.max() ?? 0
        let maxY = elems.map { $0.bbox[3] }.max() ?? 0
        if maxX > imgW || maxY > imgH {
            let nw = normalizeDimension(max(imgW, ceil(maxX) + 20), fallback: imgW)
            let nh = normalizeDimension(max(imgH, ceil(maxY) + 20), fallback: imgH)
            imgW = nw; imgH = nh
        }
        boxes = elems.map { e in
            uid += 1
            let x = clampD(e.bbox[0], 0, imgW - 1), y = clampD(e.bbox[1], 0, imgH - 1)
            let w = clampD(e.bbox[2] - e.bbox[0], 1, imgW - x)
            let h = clampD(e.bbox[3] - e.bbox[1], 1, imgH - y)
            return BBox(id: uid, x: x, y: y, w: w, h: h, desc: e.desc, type: e.type, colorPalette: e.colorPalette, srcIndex: e.rawIndex)
        }
        selectedIDs.removeAll()
        focusID = boxes.last?.id
        if let f = focusID { selectedIDs.insert(f) }
        backfillGlobals(from: data)
        parsedSource = data
        parsedElArrayPath = path
        parsedCount = elems.count
        parsedMeta = makeMeta(data)
        showingSource = false
        recordHistory()
        showToast("已解析 \(elems.count) 个元素")
    }

    private func backfillGlobals(from data: JVal) {
        if let hl = data.first(["high_level_description", "prompt", "description"])?.stringValue { highLevel = hl }
        if let cd = data["compositional_deconstruction"], let bg = cd["background"] {
            bgDesc = bg.first(["description", "desc"])?.stringValue ?? ""
        }
        if let st = data["style_description"], st.isObject {
            styleType = st["photo"]?.boolValue == true ? .photo : (st["art_style"]?.boolValue == true ? .artStyle : .none)
            aesthetics = st["aesthetics"]?.stringValue ?? ""
            lighting = st["lighting"]?.stringValue ?? ""
            medium = st["medium"]?.stringValue ?? ""
            paletteText = st["color_palette"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: ", ") ?? ""
        }
    }

    // MARK: 更新写回
    private func mutateParsedElements(_ f: (inout [JVal]) -> Void) {
        guard var src = parsedSource, let path = parsedElArrayPath else { return }
        var arr = parsedElArray() ?? []
        f(&arr)
        if path.count == 1 { src[path[0]] = .arr(arr) }
        else if path.count == 2 {
            if var cd = src[path[0]] { cd[path[1]] = .arr(arr); src[path[0]] = cd }
        }
        parsedSource = src
    }

    func computeChanges() -> [DiffChange] {
        guard parsedSource != nil, let arr = parsedElArray() else { return [] }
        var changes: [DiffChange] = []
        var live = Set<Int>()
        for (index, b) in boxes.enumerated() {
            let label = b.desc.isEmpty ? "#\(index + 1)" : "#\(index + 1) · \(String(b.desc.prefix(28)))"
            guard let si = b.srcIndex, si >= 0, si < arr.count else {
                changes.append(DiffChange(kind: .added, text: label))
                continue
            }
            live.insert(si)
            let src = arr[si]
            let nextBBox = normToIdeogram(b)
            let oldBBox = src["bbox"]?.arrayValue?.compactMap { $0.doubleValue.map { Int($0) } } ?? []
            if oldBBox != nextBBox {
                changes.append(DiffChange(kind: .bbox, text: "\(label): [\(oldBBox.map(String.init).joined(separator: ","))] → [\(nextBBox.map(String.init).joined(separator: ","))]"))
            }
            let oldDesc = src.first(["desc", "description"])?.stringValue ?? ""
            if oldDesc != b.desc {
                changes.append(DiffChange(kind: .desc, text: "\(label): 描述将更新"))
            }
        }
        for (index, _) in arr.enumerated() where !live.contains(index) {
            changes.append(DiffChange(kind: .removed, text: "#\(index + 1)"))
        }
        // 全局字段
        let hlNext = highLevel.trimmingCharacters(in: .whitespaces)
        let hlOld = parsedSource?["high_level_description"]?.stringValue ?? ""
        if hlNext != hlOld { changes.append(DiffChange(kind: .global, text: "high_level_description")) }
        let bgNext = bgDesc.trimmingCharacters(in: .whitespaces)
        let bgOld = parsedSource?["compositional_deconstruction"]?["background"]?["description"]?.stringValue ?? ""
        if bgNext != bgOld { changes.append(DiffChange(kind: .global, text: "background.description")) }
        if buildStyle() != parsedSource?["style_description"] {
            changes.append(DiffChange(kind: .global, text: "style_description"))
        }
        return changes
    }

    func openUpdatePreview() {
        guard parsedSource != nil, parsedElArray() != nil else { showToast("请先解析 JSON 提示词"); return }
        pendingDiff = computeChanges()
    }
    func cancelUpdatePreview() { pendingDiff = nil }
    func confirmUpdate() {
        pendingDiff = nil
        updateSourceJSON()
    }

    func updateSourceJSON() {
        guard parsedSource != nil, parsedElArray() != nil else { showToast("请先解析 JSON 提示词"); return }
        var arr = parsedElArray()!
        // 1) 已映射元素:原地更新 bbox / desc / description / color_palette
        for bi in boxes.indices {
            guard let si = boxes[bi].srcIndex, si >= 0, si < arr.count, arr[si].isObject else { continue }
            var el = arr[si]
            el["bbox"] = .arr(normToIdeogram(boxes[bi]).map { .num(Double($0)) })
            if el["desc"] != nil { el["desc"] = .str(boxes[bi].desc) }
            if el["description"] != nil { el["description"] = .str(boxes[bi].desc) }
            if !boxes[bi].colorPalette.isEmpty {
                el["color_palette"] = .arr(boxes[bi].colorPalette.map { .str($0) })
            } else if el["color_palette"] != nil {
                el["color_palette"] = nil
            }
            arr[si] = el
        }
        // 2) 新增的框:追加
        for bi in boxes.indices where boxes[bi].srcIndex == nil {
            var pairs: [(String, JVal)] = [
                ("type", .str(boxes[bi].type)),
                ("bbox", .arr(normToIdeogram(boxes[bi]).map { .num(Double($0)) })),
                ("desc", .str(boxes[bi].desc))
            ]
            if !boxes[bi].colorPalette.isEmpty { pairs.append(("color_palette", .arr(boxes[bi].colorPalette.map { .str($0) }))) }
            arr.append(.obj(pairs))
            boxes[bi].srcIndex = arr.count - 1
        }
        // 3) 删除的框:移除。先算旧下标 → 新下标的 remap,再删除并回填 boxes
        let live = Set(boxes.compactMap { $0.srcIndex })
        var remap: [Int: Int] = [:]
        var newIdx = 0
        for i in 0..<arr.count {
            if live.contains(i) { remap[i] = newIdx; newIdx += 1 }
        }
        for i in stride(from: arr.count - 1, through: 0, by: -1) where !live.contains(i) {
            arr.remove(at: i)
        }
        for bi in boxes.indices {
            if let old = boxes[bi].srcIndex { boxes[bi].srcIndex = remap[old] }
        }

        mutateParsedElements { $0 = arr }

        // 3.5) 同步全局/背景/风格
        if var src = parsedSource {
            let hl = highLevel.trimmingCharacters(in: .whitespaces)
            src["high_level_description"] = hl.isEmpty ? nil : .str(hl)
            if var cd = src["compositional_deconstruction"] {
                if var bg = cd["background"] {
                    bg["description"] = bgNext(bgDesc) == nil ? nil : .str(bgDesc.trimmingCharacters(in: .whitespaces))
                    cd["background"] = bg
                }
                src["compositional_deconstruction"] = cd
            }
            src["style_description"] = buildStyle()
            parsedSource = src
        }
        // 4) 写回文本框
        pasteText = JValWriter.compact(parsedSource!)
        showingSource = true
        recordHistory()
        showToast("已更新提示词 (\(boxes.count) 个元素)")
    }
    private func bgNext(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // 改色:对象色板双击改色 → 替换 desc 里的色号 + colorPalette 字段
    func changeObjectColor(boxID: Int, old: String, new: String) {
        guard let i = boxes.firstIndex(where: { $0.id == boxID }) else { return }
        let newUp = new.uppercased()
        var changed = false
        if boxes[i].desc.uppercased().contains(old.uppercased()) {
            boxes[i].desc = boxes[i].desc.replacingOccurrences(of: old, with: newUp, options: .caseInsensitive)
            changed = true
        }
        if let pi = boxes[i].colorPalette.firstIndex(where: { $0.uppercased() == old.uppercased() }) {
            boxes[i].colorPalette[pi] = newUp
            changed = true
        }
        if changed { recordHistory() }
        showToast("已改为 \(newUp)")
    }
    /// 整体配色改色:写回 paletteText
    func changeOverallColor(index idx: Int, new: String) {
        var arr = paletteText.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        while arr.count < idx + 1 { arr.append("") }
        arr[idx] = new
        paletteText = arr.joined(separator: ", ")
        if parsedSource?["style_description"]?["color_palette"]?.arrayValue != nil {
            var src = parsedSource!
            var pal = src["style_description"]!["color_palette"]!.arrayValue!
            while pal.count < idx + 1 { pal.append(.str("")) }
            pal[idx] = .str(new)
            var st = src["style_description"]!
            st["color_palette"] = .arr(pal)
            src["style_description"] = st
            parsedSource = src
        }
        showToast("已改为 \(new)")
    }

    /// 从 desc 提取 #rrggbb 色号
    static func extractColors(from desc: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "#[0-9a-fA-F]{6}\\b") else { return [] }
        let matches = re.matches(in: desc, range: NSRange(desc.startIndex..., in: desc))
        var seen = Set<String>(), out: [String] = []
        for m in matches {
            let c = String(desc[Range(m.range, in: desc)!]).uppercased()
            if !seen.contains(c) { seen.insert(c); out.append(c) }
        }
        return out
    }

    // MARK: 配置持久化
    struct SavedConfig: Codable {
        var id: Double
        var name: String
        var w: Double, h: Double
        var ratioValue: String, ratioLocked: Bool
        var boxes: [BoxDTO]
        var selectedIDs: [Int]
        var focusID: Int?
        var highLevel: String, bgDesc: String, styleType: String
        var aesthetics: String, lighting: String, medium: String, paletteText: String
        var pasteText: String
        var parsedSourceText: String?
        var sourceRefIndexes: [Int]
        var showingSource: Bool
        var parsedCount: Int
        var bgPNGBase64: String?
        var ts: Double
    }
    struct BoxDTO: Codable {
        var id: Int, x: Double, y: Double, w: Double, h: Double
        var desc: String, type: String, locked: Bool, hidden: Bool
        var colorPalette: [String]
        var srcIndex: Int?
    }

    @Published var configs: [SavedConfig] = []

    private var configsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BBoxDesigner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("configs.json")
    }

    func loadConfigsFromDisk() {
        guard let data = try? Data(contentsOf: configsURL),
              let arr = try? JSONDecoder().decode([SavedConfig].self, from: data) else { configs = []; return }
        configs = arr
    }
    private func writeConfigsToDisk() -> Bool {
        guard let data = try? JSONEncoder().encode(configs) else { return false }
        return (try? data.write(to: configsURL)) != nil
    }

    func saveConfig(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { showToast("请输入配置名称"); return }
        let bgB64: String? = bgImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])?.base64EncodedString() }
        let cfg = SavedConfig(
            id: Date().timeIntervalSince1970 * 1000, name: trimmed, w: imgW, h: imgH,
            ratioValue: ratioValue, ratioLocked: ratioLocked,
            boxes: boxes.map { BoxDTO(id: $0.id, x: $0.x, y: $0.y, w: $0.w, h: $0.h, desc: $0.desc, type: $0.type, locked: $0.locked, hidden: $0.hidden, colorPalette: $0.colorPalette, srcIndex: $0.srcIndex) },
            selectedIDs: Array(selectedIDs), focusID: focusID,
            highLevel: highLevel, bgDesc: bgDesc, styleType: styleType.rawValue,
            aesthetics: aesthetics, lighting: lighting, medium: medium, paletteText: paletteText,
            pasteText: pasteText,
            parsedSourceText: parsedSource.map { JValWriter.compact($0) },
            sourceRefIndexes: boxes.map { $0.srcIndex ?? -1 },
            showingSource: showingSource, parsedCount: parsedCount,
            bgPNGBase64: bgB64, ts: Date().timeIntervalSince1970)
        configs.append(cfg)
        if !writeConfigsToDisk() {
            // 存储失败:去掉背景图重试
            configs[configs.count - 1].bgPNGBase64 = nil
            if !writeConfigsToDisk() { showToast("保存失败:存储空间不足"); return }
            showToast("配置已保存 (不含背景图)")
        } else {
            showToast("配置已保存")
        }
    }

    func restoreConfig(id: Double) {
        guard let cfg = configs.first(where: { $0.id == id }) else { showToast("请先选择一个配置"); return }
        imgW = normalizeDimension(cfg.w, fallback: imgW)
        imgH = normalizeDimension(cfg.h, fallback: imgH)
        ratioValue = cfg.ratioValue; ratioLocked = cfg.ratioLocked
        boxes = cfg.boxes.map { BBox(id: $0.id, x: $0.x, y: $0.y, w: $0.w, h: $0.h, desc: $0.desc, type: $0.type, locked: $0.locked, hidden: $0.hidden, colorPalette: $0.colorPalette, srcIndex: nil) }
        selectedIDs = Set(cfg.selectedIDs.filter { id in boxes.contains(where: { $0.id == id }) })
        focusID = cfg.focusID.flatMap { selectedIDs.contains($0) ? $0 : nil } ?? selectedIDs.first
        highLevel = cfg.highLevel; bgDesc = cfg.bgDesc
        styleType = StyleType(rawValue: cfg.styleType) ?? .none
        aesthetics = cfg.aesthetics; lighting = cfg.lighting; medium = cfg.medium; paletteText = cfg.paletteText
        pasteText = cfg.pasteText
        parsedSource = cfg.parsedSourceText.flatMap { JValParser.parseLoose($0) }
        if parsedSource != nil {
            parsedElArrayPath = extractElementArray(parsedSource!)?.path
            for (i, b) in cfg.boxes.enumerated() {
                let ref = cfg.sourceRefIndexes.count > i ? cfg.sourceRefIndexes[i] : -1
                if ref >= 0, i < boxes.count { boxes[i].srcIndex = ref }
            }
            parsedCount = cfg.parsedCount
            parsedMeta = makeMeta(parsedSource!)
            showingSource = cfg.showingSource
        } else {
            parsedElArrayPath = nil; parsedCount = 0; parsedMeta = nil; showingSource = false
        }
        uid = boxes.map { $0.id }.max() ?? 0
        if let b64 = cfg.bgPNGBase64, let data = Data(base64Encoded: b64) {
            bgImage = NSImage(data: data)
        } else {
            bgImage = nil
        }
        clampBoxes()
        resetHistory()
        showToast("配置已还原")
    }

    func deleteConfig(id: Double) {
        configs.removeAll { $0.id == id }
        writeConfigsToDisk()
        showToast("配置已删除")
    }
}
