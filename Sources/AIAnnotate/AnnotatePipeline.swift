import Foundation

/// M4 · 后处理管线与「生成视图」折叠(全部程序化,无模型参与;PLAN-image-auto-bbox §2 Step 4 / §3.1)。
/// - 输入为 M3 的 SAM3Grounder.GroundedRecognition;离线/降级时 instances 为空,
///   管线同一条路径产出合法结果(元素照写、省略 bbox 字段);
/// - 后处理:NMS 去重(同 label IoU>0.85,score 高者优先、同分保大框)→ 极小框过滤
///   (归一化面积 <0.1% 画布,即 <10 @0–1000²)→ 嵌套框保留(睫毛⊂眼是有意层级,不做包含消除)
///   → 排序(person 在前,其后按面积降序);
/// - caption 组装:EditorState.parse 兼容,顶层键序 high_level_description → style_description →
///   compositional_deconstruction,保序 JVal 构建;
/// - 「生成视图」折叠:纯函数,与全量视图并存;画布始终保留全量标注,M5 才接 UI。
enum AnnotatePipeline {

    // MARK: - 阈值常量

    /// NMS 与折叠收敛共用的 IoU 阈值。
    static let nmsIoUThreshold = 0.85
    /// 极小框过滤:面积 <0.1% 画布 = <10 @0–1000²(恰好 10 保留)。
    static let minBoxArea = 10
    /// 疑似背景实体判定:面积 >60% 画布 = >600000 @0–1000²。
    static let backgroundAreaThreshold = 600_000
    /// style_description.color_palette 上限(全部实体色板去重、保持首次出现顺序)。
    static let stylePaletteLimit = 8
    /// 折叠进父级/容器的部件类别(Plan §3.1:五官+头发+四肢+服装部件)。
    static let foldCategories: Set<OllamaVision.AnnotateEntity.Category> = [.faceFeature, .hair, .handArm, .garmentPart]
    /// 无 bbox 时兜底识别背景实体的关键词(label/desc 命中其一)。
    static let backgroundKeywords = ["背景", "场景", "天空", "室内", "室外", "墙面",
                                     "background", "sky", "room", "wall"]

    // MARK: - 元素模型(管线内部统一形态,category 仅存于此,caption 不携带)

    struct Element: Equatable {
        /// M1 实体原 label(NMS 分组与折叠收敛的 label 判据)。
        var label: String
        var category: OllamaVision.AnnotateEntity.Category
        /// M1 实体的中文详细描述。
        var desc: String
        var colorPalette: [String]
        /// [ymin,xmin,ymax,xmax] @0–1000;离线/漏检实体为 nil(caption 中省略 bbox 字段)。
        var bbox: [Int]?
        /// SAM3 实例置信度;无 bbox 元素为 0。
        var score: Double
    }

    // MARK: - 几何原语([ymin,xmin,ymax,xmax] @0–1000)

    static func area(_ b: [Int]) -> Int {
        max(0, b[2] - b[0]) * max(0, b[3] - b[1])
    }

    static func iou(_ a: [Int], _ b: [Int]) -> Double {
        let y1 = max(a[0], b[0]), x1 = max(a[1], b[1])
        let y2 = min(a[2], b[2]), x2 = min(a[3], b[3])
        let inter = max(0, y2 - y1) * max(0, x2 - x1)
        let union = area(a) + area(b) - inter
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    /// 交叠面积(折叠时挑父级 person 用);任一无 bbox 为 0。
    static func intersectionArea(_ a: [Int]?, _ b: [Int]?) -> Int {
        guard let a, let b else { return 0 }
        return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    }

    // MARK: - 后处理:展开 → NMS → 极小框过滤 → 排序(嵌套框不做包含消除,有意保留)

    /// GroundedRecognition → 管线元素:每实例一个元素;无实例的实体(离线/漏检)产出单个无 bbox 元素。
    static func expand(_ grounded: SAM3Grounder.GroundedRecognition) -> [Element] {
        var out: [Element] = []
        for e in grounded.recognition.entities {
            let insts = grounded.instances(forLabel: e.label)
            if insts.isEmpty {
                out.append(Element(label: e.label, category: e.category, desc: e.desc,
                                   colorPalette: e.colorPalette, bbox: nil, score: 0))
            } else {
                for inst in insts {
                    out.append(Element(label: e.label, category: e.category, desc: e.desc,
                                       colorPalette: e.colorPalette, bbox: inst.bbox, score: inst.score))
                }
            }
        }
        return out
    }

    /// 同 label 实例间 NMS:IoU>0.85 去一,score 高者优先,同分保大框。无 bbox 元素不参与(恒保留)。
    static func nms(_ elements: [Element]) -> [Element] {
        var byLabel: [String: [Int]] = [:]
        var labelOrder: [String] = []
        for (i, e) in elements.enumerated() {
            if byLabel[e.label] == nil { labelOrder.append(e.label) }
            byLabel[e.label, default: []].append(i)
        }
        var dropped = Set<Int>()
        for label in labelOrder {
            let idxs = byLabel[label]!.filter { elements[$0].bbox != nil }
            // 保留优先级:score 降序 → 面积降序
            let sorted = idxs.sorted {
                let a = elements[$0], b = elements[$1]
                if a.score != b.score { return a.score > b.score }
                return area(a.bbox!) > area(b.bbox!)
            }
            var kept: [Int] = []
            for i in sorted {
                if kept.contains(where: { iou(elements[i].bbox!, elements[$0].bbox!) > nmsIoUThreshold }) {
                    dropped.insert(i)
                } else {
                    kept.append(i)
                }
            }
        }
        return elements.indices.filter { !dropped.contains($0) }.map { elements[$0] }
    }

    /// 极小框过滤:归一化面积 < minBoxArea(10,即 0.1% 画布)丢弃;无 bbox 元素恒保留。
    static func filterTinyBoxes(_ elements: [Element]) -> [Element] {
        elements.filter { e in e.bbox.map { area($0) >= minBoxArea } ?? true }
    }

    /// 排序:category=person 在前,其后按面积降序;同位次保持原顺序(无 bbox 面积按 0)。
    static func sortElements(_ elements: [Element]) -> [Element] {
        elements.enumerated().sorted { a, b in
            let pa = a.element.category == .person, pb = b.element.category == .person
            if pa != pb { return pa }
            let aa = a.element.bbox.map(area) ?? 0, ab = b.element.bbox.map(area) ?? 0
            if aa != ab { return aa > ab }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 完整后处理链(嵌套框保留:全程无包含消除步骤)。
    static func process(_ grounded: SAM3Grounder.GroundedRecognition) -> [Element] {
        sortElements(filterTinyBoxes(nms(expand(grounded))))
    }

    // MARK: - caption 组装(EditorState.parse 兼容,保序 JVal)

    /// style_description 转换:M1 给的是字符串(如 "minimalist still-life photograph"),
    /// EditorState.parse(EditorState.swift:713/824)要求对象形态。
    /// 规则:字符串填入 aesthetics;含 photo/photograph/realistic 字样给 photo:true 否则 art_style:true;
    /// color_palette 取全部实体色板去重(首次出现顺序,上限 stylePaletteLimit)。键序与 EditorState.buildStyle 一致。
    static func styleObject(styleDescription: String,
                            entities: [OllamaVision.AnnotateEntity]) -> JVal {
        var pairs: [(String, JVal)] = [("aesthetics", .str(styleDescription))]
        let lower = styleDescription.lowercased()
        let isPhoto = lower.contains("photo") || lower.contains("photograph") || lower.contains("realistic")
        pairs.append((isPhoto ? "photo" : "art_style", .bool(true)))
        var seen = Set<String>()
        var palette: [String] = []
        for e in entities {
            for c in e.colorPalette where seen.insert(c).inserted {
                palette.append(c)
                if palette.count >= stylePaletteLimit { break }
            }
            if palette.count >= stylePaletteLimit { break }
        }
        if !palette.isEmpty { pairs.append(("color_palette", .arr(palette.map { .str($0) }))) }
        return .obj(pairs)
    }

    /// 疑似背景/场景实体:furniture/nature 且面积 >60% 画布;无 bbox 时(离线)按关键词兜底。无候选返回 nil。
    static func backgroundDescription(recognition: OllamaVision.EntityRecognition,
                                      elements: [Element]) -> String? {
        for e in elements where e.category == .furniture || e.category == .nature {
            if let b = e.bbox, area(b) > backgroundAreaThreshold { return e.desc }
        }
        for e in recognition.entities where e.category == .furniture || e.category == .nature {
            let hay = (e.label + " " + e.desc).lowercased()
            if backgroundKeywords.contains(where: { hay.contains($0) }) { return e.desc }
        }
        return nil
    }

    /// 元素 → caption JSON:type:"obj" → bbox(无则省略)→ description → color_palette(空则省略)。
    static func captionJSON(_ e: Element) -> JVal {
        var pairs: [(String, JVal)] = [("type", .str("obj"))]
        if let b = e.bbox { pairs.append(("bbox", .arr(b.map { .num(Double($0)) }))) }
        pairs.append(("description", .str(e.desc)))
        if !e.colorPalette.isEmpty { pairs.append(("color_palette", .arr(e.colorPalette.map { .str($0) }))) }
        return .obj(pairs)
    }

    /// 在已后处理的元素列表上组装 caption(供 buildCaption 与折叠视图复用同一次 process 结果)。
    /// 顶层键序:high_level_description → style_description → compositional_deconstruction;
    /// compositional_deconstruction 内 background(可选)在前、elements 在后,与 EditorState.buildCaption 同序。
    static func buildCaption(from grounded: SAM3Grounder.GroundedRecognition,
                             elements: [Element]) -> JVal {
        var comp: [(String, JVal)] = []
        if let bg = backgroundDescription(recognition: grounded.recognition, elements: elements) {
            comp.append(("background", .obj([("description", .str(bg))])))
        }
        comp.append(("elements", .arr(elements.map(captionJSON))))
        return .obj([
            ("high_level_description", .str(grounded.recognition.highLevelDescription)),
            ("style_description", styleObject(styleDescription: grounded.recognition.styleDescription,
                                              entities: grounded.recognition.entities)),
            ("compositional_deconstruction", .obj(comp))
        ])
    }

    /// 一条调用 = process + buildCaption。
    static func buildCaption(from grounded: SAM3Grounder.GroundedRecognition) -> JVal {
        buildCaption(from: grounded, elements: process(grounded))
    }

    /// 保序紧凑序列化(供「复制 JSON」类出口)。
    static func captionString(from grounded: SAM3Grounder.GroundedRecognition) -> String {
        JValWriter.compact(buildCaption(from: grounded))
    }

    // MARK: - 「生成视图」折叠(Plan §3.1,纯函数;画布始终保留全量标注,M5 才接 UI)

    /// 部件并入:desc 追加合并(去重)、bbox 取并集、色板去重合并、score 取高。
    static func merge(_ a: Element, _ b: Element) -> Element {
        var m = a
        if let ba = a.bbox, let bb = b.bbox {
            m.bbox = [min(ba[0], bb[0]), min(ba[1], bb[1]), max(ba[2], bb[2]), max(ba[3], bb[3])]
        } else if a.bbox == nil {
            m.bbox = b.bbox
        }
        if !b.desc.isEmpty, !a.desc.contains(b.desc) {
            m.desc = a.desc.isEmpty ? b.desc : a.desc + ";" + b.desc
        }
        for c in b.colorPalette where !m.colorPalette.contains(c) { m.colorPalette.append(c) }
        m.score = max(a.score, b.score)
        return m
    }

    /// 折叠为生成视图:
    /// 1) face_feature/hair/hand_arm/garment_part 并入父级 person(多个 person 取交叠最大者;
    ///    离线无 bbox 并入首个 person);无 person 时并入面积最大的非部件容器元素;
    /// 2) 剩余元素重叠收敛:不同 label 间 IoU>0.85 保大框(面积降序贪心),目标 3–6 个互不重叠主元素;
    ///    无 bbox 元素不参与几何收敛,恒保留。
    static func collapse(_ elements: [Element]) -> [Element] {
        var out = elements
        let personIdxs = out.indices.filter { out[$0].category == .person }
        // 无 person 时的兜底容器:面积最大的非部件类元素
        let containerIdx: Int? = personIdxs.isEmpty
            ? out.indices.filter { !foldCategories.contains(out[$0].category) }
                .max(by: { (out[$0].bbox.map(area) ?? 0) < (out[$1].bbox.map(area) ?? 0) })
            : nil
        var absorbed = Set<Int>()
        for i in out.indices where foldCategories.contains(out[i].category) {
            let target: Int?
            if !personIdxs.isEmpty {
                target = out[i].bbox != nil
                    ? personIdxs.max(by: { intersectionArea(out[$0].bbox, out[i].bbox) < intersectionArea(out[$1].bbox, out[i].bbox) })
                    : personIdxs.first
            } else {
                target = containerIdx
            }
            guard let t = target, t != i else { continue }
            out[t] = merge(out[t], out[i])
            absorbed.insert(i)
        }
        let rest = out.indices.filter { !absorbed.contains($0) }.map { out[$0] }
        // 重叠收敛:面积降序贪心,不同 label 且 IoU>0.85 的后来者被大框吸收
        let order = rest.indices.sorted { (rest[$0].bbox.map(area) ?? 0) > (rest[$1].bbox.map(area) ?? 0) }
        var kept: [Element] = []
        for i in order {
            if let bi = rest[i].bbox,
               kept.contains(where: { k in
                   k.label != rest[i].label && k.bbox.map { iou($0, bi) > nmsIoUThreshold } == true
               }) { continue }
            kept.append(rest[i])
        }
        return kept
    }

    /// 全量 caption → 折叠版 caption:elements 替换为折叠结果,其余字段(键序)原样保留。
    /// elements 参数须为构建 full 时同一份 process 结果(category 信息的唯一来源,caption 不携带)。
    static func collapseCaption(full: JVal, elements: [Element]) -> JVal {
        var comp = full["compositional_deconstruction"] ?? .obj([])
        comp["elements"] = .arr(collapse(elements).map(captionJSON))
        var out = full
        out["compositional_deconstruction"] = comp
        return out
    }

    // MARK: - CLI 冒烟(--annotate-smoke <图片路径> [模型]):M1 → M3 → M4 端到端

    static func smokeTest(imagePath: String, model: String = OllamaVision.defaultModel) async -> Int32 {
        guard let data = FileManager.default.contents(atPath: imagePath) else {
            print("[AnnotatePipeline] 读不到图片:\(imagePath)")
            return 1
        }
        do {
            let (rec, timings) = try await OllamaVision.recognizeEntities(imageData: data, model: model)
            print("[AnnotatePipeline] M1 完成:\(rec.entities.count) 实体,\(timings.summary)")
            let grounded = await SAM3Grounder.ground(imageData: data, recognition: rec)
            print("[AnnotatePipeline] M3 完成:online=\(grounded.sam3Online) \(grounded.note)")
            let elements = process(grounded)
            let caption = buildCaption(from: grounded, elements: elements)
            let captionStr = JValWriter.compact(caption)
            print("[AnnotatePipeline] M4 全量 caption(\(elements.count) 元素):\n\(captionStr)")
            let collapsed = collapseCaption(full: caption, elements: elements)
            let collapsedCount = collapsed["compositional_deconstruction"]?["elements"]?.arrayValue?.count ?? 0
            print("[AnnotatePipeline] M4 生成视图 caption(\(collapsedCount) 元素):\n\(JValWriter.compact(collapsed))")
            // 走 EditorState.parse 闭环验证(parse 结果供报告回填)
            await MainActor.run {
                let s = EditorState()
                s.parse(captionStr)
                print("[AnnotatePipeline] EditorState.parse:boxes=\(s.boxes.count) parseError=\(s.parseError ?? "nil") style=\(s.styleType.rawValue) aesthetics=\(s.aesthetics) bg=\(s.bgDesc)")
                for b in s.boxes {
                    print("  box [\(JVal.formatNumber(b.x)),\(JVal.formatNumber(b.y)),\(JVal.formatNumber(b.w)),\(JVal.formatNumber(b.h))] \(b.desc)")
                }
            }
            return 0
        } catch {
            print("[AnnotatePipeline] 管线失败:\(error)")
            return 1
        }
    }
}
