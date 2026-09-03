import SwiftUI
import AppKit

// MARK: - 主题色(对齐网页版)
enum Theme {
    static let bg = Color(hex: 0x0B1120)
    static let surface = Color(hex: 0x101A30)
    static let surface2 = Color(hex: 0x0C1526)
    static let border = Color(hex: 0x22304D)
    static let text = Color(hex: 0xE8EEFB)
    static let dim = Color(hex: 0x8AA0BD)
    static let accent = Color(hex: 0x38BDF8)
    static let accent2 = Color(hex: 0xA78BFA)
    static let yellow = Color(hex: 0xFACC15)
    static let green = Color(hex: 0x34D399)
    static let red = Color(hex: 0xF87171)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - 画布

/// 框标签文本:annotation 优先,无 annotation 时回退 desc 前 14 字
func boxLabelText(box: BBox, order: Int) -> String {
    let tag = box.annotation.isEmpty ? String(box.desc.prefix(14)) : box.annotation
    return "\(order)\(box.locked ? " 🔒" : "")\(tag.isEmpty ? "" : " · " + tag)"
}

struct CanvasAreaView: View {
    @ObservedObject var state: EditorState
    var maxHeight: CGFloat = 680

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / state.imgW, maxHeight / state.imgH)
            let cssW = state.imgW * scale
            let cssH = state.imgH * scale
            ZStack(alignment: .topLeading) {
                canvasContent(cssW: cssW, cssH: cssH, scale: scale)
                    .frame(width: cssW, height: cssH)
                    .coordinateSpace(name: "bboxCanvas")
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func canvasContent(cssW: CGFloat, cssH: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 背景
            if let img = state.bgImage {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: cssW, height: cssH)
            } else {
                Theme.surface2
            }
            // 网格
            Canvas { ctx, _ in
                var path = Path()
                let stepCount = 10
                for i in 1..<stepCount {
                    let gx = cssW * CGFloat(i) / CGFloat(stepCount)
                    let gy = cssH * CGFloat(i) / CGFloat(stepCount)
                    path.move(to: CGPoint(x: gx, y: 0)); path.addLine(to: CGPoint(x: gx, y: cssH))
                    path.move(to: CGPoint(x: 0, y: gy)); path.addLine(to: CGPoint(x: cssW, y: gy))
                }
                ctx.stroke(path, with: .color(state.snapToGrid ? Theme.accent.opacity(0.24) : Theme.dim.opacity(0.10)), lineWidth: 1)
            }
            .allowsHitTesting(false)
            // 三分法构图参考线
            if state.showGuides {
                Canvas { ctx, _ in
                    var path = Path()
                    for i in 1...2 {
                        let gx = cssW * CGFloat(i) / 3
                        let gy = cssH * CGFloat(i) / 3
                        path.move(to: CGPoint(x: gx, y: 0)); path.addLine(to: CGPoint(x: gx, y: cssH))
                        path.move(to: CGPoint(x: 0, y: gy)); path.addLine(to: CGPoint(x: cssW, y: gy))
                    }
                    ctx.stroke(path, with: .color(.white.opacity(0.42)), lineWidth: 1)
                    // 兴趣点小十字
                    let cross = min(10, min(cssW, cssH) * 0.018)
                    var crossPath = Path()
                    for ix in 1...2 {
                        for iy in 1...2 {
                            let cx = cssW * CGFloat(ix) / 3, cy = cssH * CGFloat(iy) / 3
                            crossPath.move(to: CGPoint(x: cx - cross, y: cy)); crossPath.addLine(to: CGPoint(x: cx + cross, y: cy))
                            crossPath.move(to: CGPoint(x: cx, y: cy - cross)); crossPath.addLine(to: CGPoint(x: cx, y: cy + cross))
                        }
                    }
                    ctx.stroke(crossPath, with: .color(.white.opacity(0.55)), lineWidth: 1.25)
                }
                .allowsHitTesting(false)
            }
            // 空白区手势层:拖动框选 / 双击新建
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("bboxCanvas"))
                        .onChanged { v in
                            let p = state.canvasPoint(v.location, in: CGSize(width: cssW, height: cssH))
                            if state.dragMode == .none {
                                let additive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control)
                                state.marqueeBegan(at: p, additive: additive)
                            } else if case .marquee = state.dragMode {
                                state.marqueeDragged(to: p)
                            }
                        }
                        .onEnded { _ in
                            if case .marquee(let additive) = state.dragMode {
                                state.marqueeEnded(additive: additive)
                            }
                        }
                )
                .gesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .named("bboxCanvas"))
                        .onEnded { v in
                            let p = state.canvasPoint(v.location, in: CGSize(width: cssW, height: cssH))
                            state.doubleTapCanvas(at: p)
                        }
                )

            // 物体框
            ForEach(Array(state.boxes.enumerated()), id: \.element.id) { index, box in
                if !box.hidden {
                    BoxView(state: state, box: box, order: index + 1, scale: scale, canvasSize: CGSize(width: cssW, height: cssH))
                }
            }

            // 智能对齐参考线(1px 实线黄,贯穿画布;区别于框选虚线)
            ForEach(state.activeGuides, id: \.self) { line in
                if line.axis == .v {
                    Rectangle()
                        .fill(Theme.yellow)
                        .frame(width: 1, height: cssH)
                        .offset(x: line.pos * scale, y: 0)
                        .allowsHitTesting(false)
                } else {
                    Rectangle()
                        .fill(Theme.yellow)
                        .frame(width: cssW, height: 1)
                        .offset(x: 0, y: line.pos * scale)
                        .allowsHitTesting(false)
                }
            }

            // 多选拖动组包围盒(黄色虚线)
            if let g = state.groupBounds {
                Rectangle()
                    .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: g.width * scale, height: g.height * scale)
                    .offset(x: g.minX * scale, y: g.minY * scale)
                    .allowsHitTesting(false)
            }

            // 框选矩形
            if let r = state.marqueeRect {
                Rectangle()
                    .fill(Theme.accent.opacity(0.10))
                    .overlay(Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .frame(width: r.width * scale, height: r.height * scale)
                    .offset(x: r.minX * scale, y: r.minY * scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cssW, height: cssH)
        .onDrop(of: [.image], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    if let data, let img = NSImage(data: data) {
                        DispatchQueue.main.async {
                            state.bgImage = img
                            state.showToast("参考图已就位")
                        }
                    }
                }
            }
            return true
        }
    }
}

struct BoxView: View {
    @ObservedObject var state: EditorState
    let box: BBox
    let order: Int
    let scale: CGFloat
    let canvasSize: CGSize

    var isSelected: Bool { state.selectedIDs.contains(box.id) }
    var showHandles: Bool { isSelected && state.selectedIDs.count == 1 && state.focusID == box.id && !box.locked }

    var strokeColor: Color {
        if box.locked { return Theme.dim }
        return isSelected ? Theme.yellow : Theme.accent
    }
    var fillColor: Color {
        if box.locked { return Theme.dim.opacity(0.12) }
        return isSelected ? Theme.yellow.opacity(0.16) : Theme.accent.opacity(0.12)
    }

    var body: some View {
        let x = box.x * scale, y = box.y * scale
        let w = box.w * scale, h = box.h * scale
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(fillColor)
                .overlay(Rectangle().stroke(strokeColor, lineWidth: isSelected ? 2.5 : 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("bboxCanvas"))
                        .onChanged { v in
                            if box.locked { return }
                            let p = state.canvasPoint(v.location, in: canvasSize)
                            if state.dragMode == .none {
                                let additive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control)
                                state.boxDown(box, at: p, additive: additive)
                            } else if state.dragMode == .move {
                                // 按住 ⌘ 拖动时临时禁用吸附(Keynote 惯例)
                                state.moveDragged(to: p, suppressSnap: NSEvent.modifierFlags.contains(.command))
                            }
                        }
                        .onEnded { _ in
                            if state.dragMode == .move { state.endDrag() }
                        }
                )
                .gesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .named("bboxCanvas"))
                        .onEnded { v in
                            let p = state.canvasPoint(v.location, in: canvasSize)
                            state.doubleTapCanvas(at: p)
                        }
                )
            // 序号标签(annotation 优先,窄框跟随框宽换行,最多 3 行)
            let label = boxLabelText(box: box, order: order)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isSelected ? Theme.yellow.opacity(0.9) : Theme.accent.opacity(0.9))
                .foregroundStyle(Theme.bg)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: max(w, 40), alignment: .leading)
                .offset(y: -19)
                .allowsHitTesting(false)
            // 8 个 resize 手柄
            if showHandles {
                ForEach(handleDefs, id: \.name) { hd in
                    Rectangle()
                        .fill(Theme.yellow)
                        .frame(width: 9, height: 9)
                        .position(x: hd.fx(w) , y: hd.fy(h))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("bboxCanvas"))
                                .onChanged { v in
                                    let p = state.canvasPoint(v.location, in: canvasSize)
                                    if state.dragMode == .none {
                                        state.resizeBegan(box, handle: hd.name)
                                    } else if case .resize = state.dragMode {
                                        state.resizeDragged(id: box.id, handle: hd.name, to: p,
                                                            suppressSnap: NSEvent.modifierFlags.contains(.command))
                                    }
                                }
                                .onEnded { _ in
                                    if case .resize = state.dragMode { state.endDrag() }
                                }
                        )
                }
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .offset(x: x, y: y)
    }

    struct HandleDef { let name: String; let fx: (CGFloat) -> CGFloat; let fy: (CGFloat) -> CGFloat }
    var handleDefs: [HandleDef] {
        [
            HandleDef(name: "nw", fx: { _ in 0 }, fy: { _ in 0 }),
            HandleDef(name: "n",  fx: { $0 / 2 }, fy: { _ in 0 }),
            HandleDef(name: "ne", fx: { $0 }, fy: { _ in 0 }),
            HandleDef(name: "e",  fx: { $0 }, fy: { $0 / 2 }),
            HandleDef(name: "se", fx: { $0 }, fy: { $0 }),
            HandleDef(name: "s",  fx: { $0 / 2 }, fy: { $0 }),
            HandleDef(name: "sw", fx: { _ in 0 }, fy: { $0 }),
            HandleDef(name: "w",  fx: { _ in 0 }, fy: { $0 / 2 }),
        ]
    }
}
