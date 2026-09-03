import Foundation

/// `BBoxDesigner --selftest`:验证 JSON 解析 / caption 构建 / 写回闭环。
enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            print((cond ? "PASS" : "FAIL") + " " + name)
            if !cond { failures += 1 }
        }

        let s = EditorState()
        let sample = """
        前面是噪音文字
        {
          "high_level_description": "A cozy studio portrait",
          "style_description": {"aesthetics":"soft film", "lighting":"window light", "photo":true, "medium":"35mm", "color_palette":["#A78BFA","#38BDF8"]},
          "compositional_deconstruction": {
            "background": {"bbox":[0,0,1000,1000], "description":"warm blurred room"},
            "elements": [
              {"type":"obj", "bbox":[100,200,500,600], "description":"a cat on a chair", "color_palette":["#FACC15"], "annotation":"左袖"},
              {"type":"obj", "bbox":[600,100,900,400], "desc":"a lamp", "note":"台灯"}
            ]
          },
          "custom_field": {"keep":"me"}
        }
        """
        // 1) 解析
        s.parse(sample)
        check(s.boxes.count == 2, "解析出 2 个元素")
        check(s.parseError == nil, "无解析错误")
        check(s.highLevel == "A cozy studio portrait", "回填 high_level_description")
        check(s.bgDesc == "warm blurred room", "回填 background.description")
        check(s.styleType == .photo, "回填 style type=photo")
        check(s.paletteText.contains("#A78BFA"), "回填 color_palette")
        // bbox 反归一化:cat ymin=100 → y=102.4 @1024高
        check(abs(s.boxes[0].y - 102.4) < 0.5, "bbox [ymin,xmin,ymax,xmax] 反归一化 y")
        check(abs(s.boxes[0].x - 153.6) < 0.5, "bbox 反归一化 x")
        check(s.boxes[0].desc == "a cat on a chair", "description 别名读取")
        check(s.boxes[1].desc == "a lamp", "desc 别名读取")
        check(s.boxes[0].colorPalette == ["#FACC15"], "对象 color_palette 读取")
        check(s.boxes[0].annotation == "左袖", "annotation 读取")
        check(s.boxes[1].annotation == "台灯", "note 别名读取为 annotation")

        // 2) 输出 caption
        let cap = s.buildCaption()
        let capStr = JValWriter.compact(cap)
        check(capStr.contains("\"compositional_deconstruction\""), "caption 含 compositional_deconstruction")
        check(capStr.contains("\"bbox\": [100,200,500,600]"), "caption bbox 归一化单行 [ymin,xmin,ymax,xmax]")
        check(capStr.contains("\"photo\": true"), "style photo=true")
        check(!capStr.contains("annotation"), "caption 不含 annotation")

        // 3) 移动物体 → 写回
        s.selectedIDs = [s.boxes[0].id]
        s.focusID = s.boxes[0].id
        s.boxes[0].x = 0
        s.boxes[0].y = 0
        s.boxes[0].desc = "a big cat"
        let changes = s.computeChanges()
        check(changes.contains { $0.kind == .bbox }, "diff 检测到 bbox 变化")
        check(changes.contains { $0.kind == .desc }, "diff 检测到描述变化")
        s.updateSourceJSON()
        check(s.pasteText.contains("\"description\": \"a big cat\""), "写回 desc")
        check(s.pasteText.contains("\"bbox\": [0,0,400,400]"), "写回新 bbox")
        check(s.pasteText.contains("\"custom_field\""), "未知字段保留")
        check(s.pasteText.contains("\"keep\": \"me\""), "未知字段内容保留")
        // 键顺序:high_level_description 仍在最前
        check(s.pasteText.hasPrefix("{\n  \"high_level_description\""), "键顺序保持")
        check(s.pasteText.contains("\"annotation\": \"左袖\""), "写回保留 annotation")

        // 4) 新增 + 删除元素闭环
        let before = s.boxes.count
        let nb = s.addBox(at: CGPoint(x: 500, y: 500))
        nb.id.description // touch
        s.updateSourceJSON()
        check(s.pasteText.contains("\"desc\": \"\""), "新增元素追加到源")
        s.deleteBox(id: nb.id)
        s.updateSourceJSON()
        let count = JValParser.parseLoose(s.pasteText)?["compositional_deconstruction"]?["elements"]?.arrayValue?.count ?? -1
        check(count == before, "删除元素从源移除")

        // 5) 撤销/重做
        s.undo()
        s.redo()
        check(s.parsedSource != nil, "undo/redo 后解析源仍在")

        // 6) 写回的 JSON 可再次解析(round-trip)
        let s2 = EditorState()
        s2.parse(s.pasteText)
        check(s2.boxes.count == before, "round-trip 再解析元素数一致")
        check(s2.parseError == nil, "round-trip 无错误")
        check(s2.boxes[0].annotation == "左袖", "round-trip annotation 保留")

        // 7) 智能对齐吸附(computeSnap 纯函数 + EditorState 接线)
        let canvas = SmartGuides.canvasCandidates(w: 1000, h: 1000)
        // 7.1 左边线吸附:左边缘 x=102,候选 v@100,阈值 6 → deltaX=-2
        let r1 = SmartGuides.computeSnap(moving: CGRect(x: 102, y: 300, width: 100, height: 100),
                                         candidates: [SnapLine(axis: .v, pos: 100)], threshold: 6)
        check(r1.deltaX == -2 && r1.deltaY == 0 && r1.lines == [SnapLine(axis: .v, pos: 100)], "吸附:左边线吸附 v@100")
        // 7.2 中线吸附:包围盒中X 命中画布中线 v@500
        let r2 = SmartGuides.computeSnap(moving: CGRect(x: 447, y: 300, width: 100, height: 100),
                                         candidates: canvas, threshold: 6)
        check(r2.deltaX == 3 && r2.lines.contains(SnapLine(axis: .v, pos: 500)), "吸附:中X 命中画布中线")
        // 7.3 双轴同时吸附:X 命中物体边缘 v@100 + Y 命中画布中线 h@500
        let r3 = SmartGuides.computeSnap(moving: CGRect(x: 102, y: 447, width: 100, height: 100),
                                         candidates: canvas + [SnapLine(axis: .v, pos: 100)], threshold: 6)
        check(r3.deltaX == -2 && r3.deltaY == 3 && r3.lines.count == 2, "吸附:双轴同时吸附")
        // 7.4 超阈值不吸附:距离 7px → 无 lines、无 delta
        let r4 = SmartGuides.computeSnap(moving: CGRect(x: 107, y: 300, width: 100, height: 100),
                                         candidates: [SnapLine(axis: .v, pos: 100)], threshold: 6)
        check(r4.lines.isEmpty && r4.deltaX == 0 && r4.deltaY == 0, "吸附:超阈值不吸附")
        // 7.5 多候选取最近:候选 101/104,当前 102 → 选 101
        let r5 = SmartGuides.computeSnap(moving: CGRect(x: 102, y: 300, width: 50, height: 50),
                                         candidates: [SnapLine(axis: .v, pos: 101), SnapLine(axis: .v, pos: 104)], threshold: 6)
        check(r5.deltaX == -1 && r5.lines == [SnapLine(axis: .v, pos: 101)], "吸附:多候选取最近")
        // 7.6 缩放边吸附:拖 e 边到 898,候选 v@900 → 夹到 900
        let r6 = SmartGuides.computeSnap(edge: 898, axis: .v,
                                         candidates: [SnapLine(axis: .v, pos: 900)], threshold: 6)
        check(r6.deltaX == 2 && r6.deltaY == 0 && r6.lines == [SnapLine(axis: .v, pos: 900)], "吸附:缩放边夹到候选线")
        // 7.7 smartSnapEnabled=false 时走原逻辑(不吸附、无参考线,行为回归不变)
        let s3 = EditorState()
        s3.smartSnapEnabled = false
        let a3 = s3.addBox(at: CGPoint(x: 300, y: 300))
        let b3 = s3.addBox(at: CGPoint(x: 600, y: 700))
        let edgeX = a3.x + a3.w
        s3.boxDown(b3, at: CGPoint(x: b3.x, y: b3.y), additive: false)
        s3.moveDragged(to: CGPoint(x: edgeX - 2, y: b3.y))
        let moved3 = s3.boxes.first(where: { $0.id == b3.id })!
        check(moved3.x == edgeX - 2 && s3.activeGuides.isEmpty, "吸附:smartSnapEnabled=false 不吸附")
        s3.endDrag()
        // 7.8 正向接线:开启时整体移动吸附到物体边缘,endDrag 清空参考线
        let s4 = EditorState()
        let a4 = s4.addBox(at: CGPoint(x: 300, y: 300))
        let b4 = s4.addBox(at: CGPoint(x: 600, y: 700))
        let edgeX4 = a4.x + a4.w
        s4.boxDown(b4, at: CGPoint(x: b4.x, y: b4.y), additive: false)
        s4.moveDragged(to: CGPoint(x: edgeX4 - 2, y: b4.y))
        let moved4 = s4.boxes.first(where: { $0.id == b4.id })!
        check(moved4.x == edgeX4 && s4.activeGuides.contains(SnapLine(axis: .v, pos: edgeX4)), "吸附:移动吸附到物体边缘")
        s4.endDrag()
        check(s4.activeGuides.isEmpty, "吸附:endDrag 清空参考线")

        // 8) 多选整体拖动(PLAN-multi-drag §3)
        // 精确布点助手:新建后改写到指定几何(50x50),返回最新值
        func mkBox(_ st: EditorState, _ x: Double, _ y: Double, locked: Bool = false, hidden: Bool = false) -> BBox {
            let b = st.addBox(at: CGPoint(x: x + 25, y: y + 25))
            if let i = st.boxes.firstIndex(where: { $0.id == b.id }) {
                st.boxes[i].x = x; st.boxes[i].y = y; st.boxes[i].w = 50; st.boxes[i].h = 50
                st.boxes[i].locked = locked; st.boxes[i].hidden = hidden
            }
            return st.boxes.first(where: { $0.id == b.id })!
        }
        // 8.1 整组移动:A(100,100) B(300,300) 全选,拖 dx=20,dy=30 → A(120,130) B(320,330)
        let s5 = EditorState()
        s5.imgW = 1024; s5.imgH = 1024; s5.smartSnapEnabled = false
        let a5 = mkBox(s5, 100, 100)
        let b5 = mkBox(s5, 300, 300)
        s5.recordHistory() // undo 断言的拖动前基线
        s5.selectAll()
        s5.boxDown(a5, at: CGPoint(x: 100, y: 100), additive: false)
        s5.moveDragged(to: CGPoint(x: 120, y: 130))
        let a5m = s5.boxes.first(where: { $0.id == a5.id })!
        let b5m = s5.boxes.first(where: { $0.id == b5.id })!
        check(a5m.x == 120 && a5m.y == 130 && b5m.x == 320 && b5m.y == 330, "多选拖动:整组移动相对偏移不变")
        check(s5.selectedIDs.count == 2, "多选拖动:点击组内框保持多选")
        s5.endDrag()
        // 8.2 统一钳制(右):拖 dx=+10000 → 组右缘贴 imgW,B.x=imgW-50=974,A.x=774(间距 200 保持)
        let s6 = EditorState()
        s6.imgW = 1024; s6.imgH = 1024; s6.smartSnapEnabled = false
        let a6 = mkBox(s6, 100, 100)
        let b6 = mkBox(s6, 300, 300)
        s6.selectAll()
        s6.boxDown(a6, at: CGPoint(x: 100, y: 100), additive: false)
        s6.moveDragged(to: CGPoint(x: 100 + 10000, y: 100))
        let a6r = s6.boxes.first(where: { $0.id == a6.id })!
        let b6r = s6.boxes.first(where: { $0.id == b6.id })!
        check(b6r.x == 974 && a6r.x == 774, "多选拖动:统一钳制右缘整组贴边不变形")
        // 8.3 统一钳制(左):同一拖动会话内拖 dx=-10000 → A.x=0,B.x=200
        s6.moveDragged(to: CGPoint(x: 100 - 10000, y: 100))
        let a6l = s6.boxes.first(where: { $0.id == a6.id })!
        let b6l = s6.boxes.first(where: { $0.id == b6.id })!
        check(a6l.x == 0 && b6l.x == 200, "多选拖动:统一钳制左缘整组贴边不变形")
        s6.endDrag()
        // 8.4 锁定框不随动:A locked,全选 A+B 拖动 → A 不动,B 动;钳制只按可动框(B)计算
        let s7 = EditorState()
        s7.imgW = 1024; s7.imgH = 1024; s7.smartSnapEnabled = false
        let a7 = mkBox(s7, 100, 100, locked: true)
        let b7 = mkBox(s7, 300, 300)
        s7.selectAll()
        s7.boxDown(b7, at: CGPoint(x: 300, y: 300), additive: false)
        s7.moveDragged(to: CGPoint(x: 300 + 10000, y: 300))
        let a7m = s7.boxes.first(where: { $0.id == a7.id })!
        let b7m = s7.boxes.first(where: { $0.id == b7.id })!
        check(a7m.x == 100 && a7m.y == 100 && b7m.x == 974 && b7m.y == 300, "多选拖动:锁定框不随动且钳制只按可动框")
        s7.endDrag()
        // 8.5 隐藏框不随动
        let s9 = EditorState()
        s9.imgW = 1024; s9.imgH = 1024; s9.smartSnapEnabled = false
        let a9 = mkBox(s9, 100, 100, hidden: true)
        let b9 = mkBox(s9, 300, 300)
        s9.selectAll()
        s9.boxDown(b9, at: CGPoint(x: 300, y: 300), additive: false)
        s9.moveDragged(to: CGPoint(x: 300 + 10000, y: 300))
        let a9m = s9.boxes.first(where: { $0.id == a9.id })!
        let b9m = s9.boxes.first(where: { $0.id == b9.id })!
        check(a9m.x == 100 && a9m.y == 100 && b9m.x == 974 && b9m.y == 300, "多选拖动:隐藏框不随动且钳制只按可动框")
        s9.endDrag()
        // 8.6 undo 一次全部归位(基于 8.1 的 s5)
        s5.undo()
        let a5u = s5.boxes.first(where: { $0.id == a5.id })!
        let b5u = s5.boxes.first(where: { $0.id == b5.id })!
        check(a5u.x == 100 && a5u.y == 100 && b5u.x == 300 && b5u.y == 300, "多选拖动:undo 一次全部归位")
        // 8.7 选择语义回归:组内保持 / 组外单选 / ⌘仅剩1个不移除
        let s8 = EditorState()
        let a8 = mkBox(s8, 100, 100)
        let b8 = mkBox(s8, 300, 300)
        let c8 = mkBox(s8, 600, 600)
        s8.selectAll()
        s8.boxDown(a8, at: CGPoint(x: 100, y: 100), additive: false)
        check(s8.selectedIDs.count == 3, "选择语义:点击组内框保持多选")
        s8.endDrag()
        s8.boxDown(c8, at: CGPoint(x: 600, y: 600), additive: true) // 先把 c8 移出组
        check(s8.selectedIDs.count == 2 && !s8.selectedIDs.contains(c8.id), "选择语义:⌘点击组内框移出组")
        s8.endDrag()
        s8.boxDown(c8, at: CGPoint(x: 600, y: 600), additive: false) // c8 在组外 → 单选
        check(s8.selectedIDs == [c8.id], "选择语义:点击组外框变单选")
        s8.endDrag()
        s8.boxDown(c8, at: CGPoint(x: 600, y: 600), additive: true) // 仅剩 1 个,⌘不移除
        check(s8.selectedIDs == [c8.id], "选择语义:⌘点击仅剩 1 个不移除")
        s8.endDrag()
        _ = b8

        // 9) 框标签:annotation 优先,回退 desc 前 14 字
        check(boxLabelText(box: s2.boxes[0], order: 1) == "1 · 左袖", "标签:annotation 优先")
        var fb = BBox(id: 999, x: 0, y: 0, w: 50, h: 50)
        fb.desc = "a lamp with a very long shade"
        check(boxLabelText(box: fb, order: 2) == "2 · a lamp with a ", "标签:无 annotation 回退 desc 前 14 字")
        check(boxLabelText(box: BBox(id: 998, x: 0, y: 0, w: 50, h: 50), order: 3) == "3", "标签:无 desc 无 annotation 只有序号")

        // 10) M1:Ollama 响应 JSON 容错解析(合法 / 缺字段 / 带多余文本)
        // 10.1 合法完整响应
        let ovOK = """
        {"style_description":"cinematic photo","high_level_description":"木桌上的静物",
         "entities":[
           {"label":"red apple","category":"other","desc":"红色苹果","color_palette":["#E03131"]},
           {"label":"blue coffee cup","category":"furniture","desc":"蓝色咖啡杯","color_palette":["#1C7ED6","#FFFFFF"]}
         ]}
        """
        let rOK = OllamaVision.parseEntityResponse(ovOK)
        check(rOK?.styleDescription == "cinematic photo", "Ollama 解析:style_description")
        check(rOK?.highLevelDescription == "木桌上的静物", "Ollama 解析:high_level_description")
        check(rOK?.entities.count == 2, "Ollama 解析:2 个实体")
        check(rOK?.entities[0].label == "red apple" && rOK?.entities[0].category == .other, "Ollama 解析:label/category")
        check(rOK?.entities[1].colorPalette == ["#1C7ED6", "#FFFFFF"], "Ollama 解析:color_palette")
        // 10.2 缺字段:无 style/entities 条目缺 category/desc/color_palette → 默认值,缺 label 的条目被丢弃
        let ovMissing = """
        {"entities":[{"label":"silver key"},{"desc":"没有 label 的坏条目"}]}
        """
        let rMiss = OllamaVision.parseEntityResponse(ovMissing)
        check(rMiss != nil, "Ollama 容错:缺字段仍可解析")
        check(rMiss?.styleDescription == "" && rMiss?.highLevelDescription == "", "Ollama 容错:缺 style/high_level 给空串")
        check(rMiss?.entities.count == 1, "Ollama 容错:缺 label 的条目丢弃")
        check(rMiss?.entities[0].category == .other, "Ollama 容错:缺 category 归 other")
        check(rMiss?.entities[0].desc == "silver key", "Ollama 容错:缺 desc 回退 label")
        check(rMiss?.entities[0].colorPalette == [], "Ollama 容错:缺 color_palette 给空数组")
        // 10.3 带多余文本(markdown 围栏 + 首尾噪音) → parseLoose 提取首个 {...} 块
        let ovNoisy = "好的,这是识别结果:\n```json\n{\"style_description\":\"anime\",\"high_level_description\":\"h\",\"entities\":[{\"label\":\"oak desk\",\"category\":\"furniture\",\"desc\":\"橡木书桌\",\"color_palette\":[]}]}\n```\n希望对你有帮助。"
        let rNoisy = OllamaVision.parseEntityResponse(ovNoisy)
        check(rNoisy?.entities.count == 1 && rNoisy?.entities[0].label == "oak desk", "Ollama 容错:多余文本中提取 JSON 块")
        check(rNoisy?.styleDescription == "anime", "Ollama 容错:噪音文本中 style 正确")
        // 10.4 完全无 JSON → nil(触发 recognizeEntities 重试 1 次)
        check(OllamaVision.parseEntityResponse("对不起,我看不清这张图") == nil, "Ollama 容错:无 JSON 返回 nil")
        // 10.5 未知 category 值归并 other
        let rWeird = OllamaVision.parseEntityResponse("{\"entities\":[{\"label\":\"x\",\"category\":\"vehicle\"}]}")
        check(rWeird?.entities[0].category == .other, "Ollama 容错:未知 category 归 other")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
