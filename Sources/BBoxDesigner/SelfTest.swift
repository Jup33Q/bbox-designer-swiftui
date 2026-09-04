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

        // 11) M2:AutoResolution 宽高比匹配 + SAM3/Ideogram 坐标换算
        // 11.1 宽高比匹配:方形 / 横图 / 竖图
        check(AutoResolution.suggestCanvas(imageW: 3000, imageH: 3000) == (1024, 1024), "M2 匹配:方形图 → 1024²")
        check(AutoResolution.suggestCanvas(imageW: 1600, imageH: 900) == (1344, 768), "M2 匹配:16:9 横图 → 1344×768")
        check(AutoResolution.suggestCanvas(imageW: 2000, imageH: 1000) == (1408, 704), "M2 匹配:2:1 横图 → 1408×704")
        check(AutoResolution.suggestCanvas(imageW: 750, imageH: 1000) == (768, 1024), "M2 匹配:3:4 竖图(近 768) → 768×1024")
        check(AutoResolution.suggestCanvas(imageW: 900, imageH: 1200) == (960, 1280), "M2 匹配:3:4 竖图(近 960) → 960×1280(同比例取尺度近者)")
        check(AutoResolution.suggestCanvas(imageW: 800, imageH: 1200) == (768, 1152), "M2 匹配:2:3 竖图 → 768×1152")
        check(AutoResolution.suggestCanvas(imageW: 700, imageH: 900) == (896, 1152), "M2 匹配:7:9 竖图 → 896×1152")
        // 11.2 与预设完全相同的输入命中它自己(3:4 两个同比例预设可区分)
        for p in AutoResolution.presets {
            check(AutoResolution.suggestCanvas(imageW: p.w, imageH: p.h) == p, "M2 匹配:与预设完全相同 \(Int(p.w))×\(Int(p.h)) → 自身")
        }
        check(AutoResolution.suggestCanvas(imageW: 0, imageH: 800) == (1024, 1024), "M2 匹配:非法尺寸回退 1024²")
        // 11.3 正向:已知像素框 → [ymin,xmin,ymax,xmax] @0–1000(非方形图 1000×500)
        check(AutoResolution.pixelsToIdeogram(x: 100, y: 50, w: 400, h: 250, imageW: 1000, imageH: 500) == [100, 100, 600, 500],
              "M2 换算:非方形图像素 → [ymin,xmin,ymax,xmax]")
        // 边界 0 与 1000:整图框
        check(AutoResolution.pixelsToIdeogram(x: 0, y: 0, w: 1000, h: 500, imageW: 1000, imageH: 500) == [0, 0, 1000, 1000],
              "M2 换算:整图框 → [0,0,1000,1000]")
        // 越界夹取
        check(AutoResolution.pixelsToIdeogram(x: -50, y: -10, w: 1200, h: 600, imageW: 1000, imageH: 500) == [0, 0, 1000, 1000],
              "M2 换算:越界框夹到 0...1000")
        // 11.4 反向:0–1000 → 像素
        let rev = AutoResolution.ideogramToPixels([100, 100, 600, 500], imageW: 1000, imageH: 500)
        check(rev.x == 100 && rev.y == 50 && rev.w == 400 && rev.h == 250, "M2 换算:反向回像素 x/y/w/h")
        // 11.5 往返误差 ≤ 1/1000(归一化单位;含非方形图与小数像素)
        func roundTrip(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ iw: Double, _ ih: Double) -> Double {
            let ideo = AutoResolution.pixelsToIdeogram(x: x, y: y, w: w, h: h, imageW: iw, imageH: ih)
            let back = AutoResolution.ideogramToPixels(ideo.map(Double.init), imageW: iw, imageH: ih)
            return max(abs(back.x - x) / iw, abs(back.y - y) / ih,
                       abs(back.x + back.w - x - w) / iw, abs(back.y + back.h - y - h) / ih)
        }
        check(roundTrip(123.4, 45.6, 321.0, 234.5, 1568, 1024) <= 0.001, "M2 换算:往返误差 ≤1/1000(非方形图)")
        check(roundTrip(0, 0, 768, 768, 768, 768) <= 0.001, "M2 换算:往返误差 ≤1/1000(方形整图)")
        check(roundTrip(1, 1, 3, 3, 4096, 2048) <= 0.001, "M2 换算:往返误差 ≤1/1000(极小框)")
        // 11.6 与 EditorState.normToIdeogram 结果一致(同一张图同一框)
        let stM2 = EditorState()
        stM2.imgW = 1000; stM2.imgH = 500
        let bM2 = BBox(id: 1, x: 100, y: 50, w: 400, h: 250)
        check(stM2.normToIdeogram(bM2) == AutoResolution.pixelsToIdeogram(x: 100, y: 50, w: 400, h: 250, imageW: 1000, imageH: 500),
              "M2 换算:与 EditorState.normToIdeogram 一致")

        // 12) M3:SAM3Grounder(全部离线断言,不依赖本机 ComfyUI 真实状态)
        // 12.1 workflow JSON 注入:label 列表写入 text、阈值/参数与 M0 §2 一致、节点连接正确
        let wf = SAM3Grounder.buildWorkflow(imageName: "m0_test_image.png", labels: ["apple", "cup", "key"])
        check(wf["1"]?["class_type"]?.stringValue == "LoadImage", "M3 workflow:节点1 LoadImage")
        check(wf["1"]?["inputs"]?["image"]?.stringValue == "m0_test_image.png", "M3 workflow:节点1 注入图片名")
        check(wf["2"]?["inputs"]?["ckpt_name"]?.stringValue == "sam3.1_multiplex_fp16.safetensors", "M3 workflow:节点2 ckpt 与 M0 一致")
        check(wf["3"]?["inputs"]?["text"]?.stringValue == "apple:8, cup:8, key:8", "M3 workflow:text 注入 label 列表(带 :8 多实例后缀)")
        check(wf["3"]?["inputs"]?["clip"] == .arr([.str("2"), .num(1)]), "M3 workflow:clip 连接 [\"2\",1]")
        check(wf["4"]?["class_type"]?.stringValue == "SAM3_Detect", "M3 workflow:节点4 SAM3_Detect")
        check(wf["4"]?["inputs"]?["threshold"]?.doubleValue == 0.5, "M3 workflow:threshold 0.5 与 M0 一致")
        check(wf["4"]?["inputs"]?["refine_iterations"]?.doubleValue == 2, "M3 workflow:refine_iterations 2 与 M0 一致")
        check(wf["4"]?["inputs"]?["individual_masks"] == .bool(false), "M3 workflow:individual_masks false 与 M0 一致")
        check(wf["4"]?["inputs"]?["model"] == .arr([.str("2"), .num(0)]) && wf["4"]?["inputs"]?["image"] == .arr([.str("1"), .num(0)]) && wf["4"]?["inputs"]?["conditioning"] == .arr([.str("3"), .num(0)]),
              "M3 workflow:节点4 三输入连接正确")
        // 12.2 /prompt 提交体保序 + 序列化往返
        let promptBody = SAM3Grounder.buildPromptBody(workflow: wf)
        check(promptBody["prompt"] == wf, "M3 /prompt 提交体:prompt 字段保序内嵌")
        check(JValParser.parse(JValWriter.compact(promptBody)) == promptBody, "M3 /prompt 提交体:序列化往返一致")
        // 12.3 label 清洗:逗号/冒号/括号不破坏批量协议
        let wfDirty = SAM3Grounder.buildWorkflow(imageName: "x.png", labels: ["tights (black)", "a,b:c"], maxDetPerLabel: 1)
        check(wfDirty["3"]?["inputs"]?["text"]?.stringValue == "tights black:1, abc:1", "M3 label 清洗:逗号/冒号/括号剥离")
        // 12.4 history 解析:逐帧嵌套 [[{...}]] 与扁平 [{...}] 两种形态;未就绪返回 nil
        let histNested = JValParser.parse(#"{"p1":{"status":{"status_str":"success","completed":true},"outputs":{"4":{"bboxes":[[{"x":100,"y":50,"width":200,"height":150,"score":0.87}]]}}}}"#)!
        let dNested = SAM3Grounder.parseDetections(histNested, promptID: "p1")
        check(dNested?.count == 1 && dNested?[0].x == 100 && dNested?[0].width == 200 && abs((dNested?[0].score ?? 0) - 0.87) < 1e-9,
              "M3 history 解析:逐帧嵌套形态")
        let histFlat = JValParser.parse(#"{"p2":{"outputs":{"4":{"bboxes":[{"x":1,"y":2,"width":3,"height":4,"score":0.5},{"x":5,"y":6,"width":7,"height":8,"score":0.6}]}}}}"#)!
        check(SAM3Grounder.parseDetections(histFlat, promptID: "p2")?.count == 2, "M3 history 解析:扁平形态 2 框")
        let histEmpty = JValParser.parse(#"{"p3":{"outputs":{"4":{"bboxes":[[]]}}}}"#)!
        check(SAM3Grounder.parseDetections(histEmpty, promptID: "p3")?.isEmpty == true, "M3 history 解析:零检出返回空数组")
        let histPending = JValParser.parse(#"{"p4":{"status":{"status_str":"running"}}}"#)!
        check(SAM3Grounder.parseDetections(histPending, promptID: "p4") == nil, "M3 history 解析:未就绪返回 nil")
        // 12.5 同概念多实例:逐实例命名 + bbox→归一化接线(复用 M2 pixelsToIdeogram)
        let detsM3 = [
            SAM3Grounder.SAM3Detection(x: 100, y: 50, width: 400, height: 250, score: 0.9),
            SAM3Grounder.SAM3Detection(x: 600, y: 60, width: 100, height: 80, score: 0.7)
        ]
        let instM3 = SAM3Grounder.makeInstances(label: "hand", detections: detsM3, imageW: 1000, imageH: 500)
        check(instM3.count == 2 && instM3[0].instanceName == "hand_1" && instM3[1].instanceName == "hand_2",
              "M3 多实例:hand_1/hand_2 逐实例命名")
        check(instM3[0].bbox == [100, 100, 600, 500], "M3 接线:像素 bbox → [ymin,xmin,ymax,xmax] @0-1000")
        check(instM3[0].bbox == AutoResolution.pixelsToIdeogram(x: 100, y: 50, w: 400, h: 250, imageW: 1000, imageH: 500),
              "M3 接线:与 M2 pixelsToIdeogram 同式")
        check(instM3[1].score == 0.7, "M3 多实例:score 逐实例保留")
        // 12.6 masks 外接矩形与 bbox 互验
        let maskM3: [[Double]] = [[0, 0, 0, 0], [0, 1, 1, 0], [0, 1, 1, 0], [0, 0, 0, 0]]
        let rectM3 = SAM3Grounder.maskBoundingRect(maskM3)
        check(rectM3?.x == 1 && rectM3?.y == 1 && rectM3?.w == 2 && rectM3?.h == 2, "M3 mask 互验:外接矩形求解")
        check(SAM3Grounder.maskBoundingRect([[0, 0], [0, 0]]) == nil, "M3 mask 互验:空 mask 返回 nil")
        check(SAM3Grounder.crossCheck(SAM3Grounder.SAM3Detection(x: 1, y: 1, width: 2, height: 2, score: 0.9), maskRect: rectM3!),
              "M3 mask 互验:一致通过")
        check(!SAM3Grounder.crossCheck(SAM3Grounder.SAM3Detection(x: 10, y: 1, width: 2, height: 2, score: 0.9), maskRect: rectM3!),
              "M3 mask 互验:偏移超限不通过")
        // 12.7 同义词回退表
        check(SAM3Grounder.synonymCandidates(for: "black tights") == ["black pantyhose"], "M3 同义词:tights→pantyhose 保前缀")
        check(SAM3Grounder.synonymCandidates(for: "long skirt") == ["long dress"], "M3 同义词:skirt→dress")
        check(SAM3Grounder.synonymCandidates(for: "red apple").isEmpty, "M3 同义词:未命中返回空")
        // 12.8 降级路径:127.0.0.1:9(discard 端口)必然连接拒绝 → 仅清单无 bbox 合法结果,不抛异常不卡死
        let recM3 = OllamaVision.EntityRecognition(
            styleDescription: "cinematic photo", highLevelDescription: "静物",
            entities: [OllamaVision.AnnotateEntity(label: "red apple", category: .other, desc: "红苹果", colorPalette: [])])
        let tM3 = Date()
        let degraded = SAM3Grounder.groundBlocking(imageData: Data(), recognition: recM3, host: "http://127.0.0.1:9")
        check(!degraded.sam3Online, "M3 降级:system_stats 不可达 → sam3Online=false")
        check(degraded.instances.isEmpty, "M3 降级:无 bbox 实例")
        check(degraded.recognition.entities.count == 1 && degraded.recognition.entities[0].label == "red apple",
              "M3 降级:实体清单原样保留")
        check(degraded.bestBBox(forLabel: "red apple") == nil, "M3 降级:统一消费入口返回 nil(在线/离线同路径)")
        check(Date().timeIntervalSince(tM3) < 15, "M3 降级:快速返回不卡死")

        // 13) M4:AnnotatePipeline 后处理 / caption 组装 / 生成视图折叠(全部离线断言,不依赖本机 Ollama/ComfyUI 真实状态)
        func mkE(_ label: String, _ cat: OllamaVision.AnnotateEntity.Category, _ desc: String, _ pal: [String] = []) -> OllamaVision.AnnotateEntity {
            OllamaVision.AnnotateEntity(label: label, category: cat, desc: desc, colorPalette: pal)
        }
        func mkI(_ label: String, _ idx: Int, _ bbox: [Int], _ score: Double) -> SAM3Grounder.GroundedInstance {
            SAM3Grounder.GroundedInstance(label: label, instanceIndex: idx,
                                          instanceName: label.replacingOccurrences(of: " ", with: "_") + "_\(idx)",
                                          bbox: bbox, score: score)
        }
        func mkG(_ rec: OllamaVision.EntityRecognition, _ insts: [SAM3Grounder.GroundedInstance], online: Bool = true) -> SAM3Grounder.GroundedRecognition {
            SAM3Grounder.GroundedRecognition(recognition: rec, instances: insts, sam3Online: online, note: "selftest")
        }
        // 13.1 NMS:同 label 两框 IoU≈0.951>0.85 → 去一,score 高者优先
        let recNMS = OllamaVision.EntityRecognition(styleDescription: "", highLevelDescription: "",
                                                    entities: [mkE("hand", .handArm, "手")])
        let pNMS1 = AnnotatePipeline.process(mkG(recNMS, [mkI("hand", 1, [100, 100, 300, 300], 0.9),
                                                          mkI("hand", 2, [105, 100, 305, 300], 0.8)]))
        check(pNMS1.count == 1 && pNMS1[0].score == 0.9, "M4 NMS:同 label IoU>0.85 去一,score 高者优先")
        // 同分保大框:[95,95,305,305](44100) vs [100,100,300,300](40000),IoU≈0.907
        let pNMS2 = AnnotatePipeline.process(mkG(recNMS, [mkI("hand", 1, [100, 100, 300, 300], 0.9),
                                                          mkI("hand", 2, [95, 95, 305, 305], 0.9)]))
        check(pNMS2.count == 1 && pNMS2[0].bbox == [95, 95, 305, 305], "M4 NMS:同分保大框")
        // IoU≈0.822<0.85 → 都保留
        let pNMS3 = AnnotatePipeline.process(mkG(recNMS, [mkI("hand", 1, [100, 100, 300, 300], 0.9),
                                                          mkI("hand", 2, [110, 110, 310, 310], 0.8)]))
        check(pNMS3.count == 2, "M4 NMS:IoU<0.85 都保留")
        // 13.2 极小框过滤:面积恰好 10(=0.1% 画布)保留,9 丢弃
        let recTiny = OllamaVision.EntityRecognition(styleDescription: "", highLevelDescription: "",
                                                     entities: [mkE("pin", .other, "别针")])
        check(AnnotatePipeline.process(mkG(recTiny, [mkI("pin", 1, [0, 0, 10, 1], 0.9)])).count == 1,
              "M4 极小框:恰好 0.1%(面积 10)保留")
        check(AnnotatePipeline.process(mkG(recTiny, [mkI("pin", 1, [0, 0, 3, 3], 0.9)])).isEmpty,
              "M4 极小框:面积 9(<0.1%)丢弃")
        // 13.3 嵌套框保留:睫毛框完全含于眼框(异 label)→ 两者都在
        let recNest = OllamaVision.EntityRecognition(styleDescription: "", highLevelDescription: "",
                                                     entities: [mkE("left eye", .faceFeature, "左眼"),
                                                                mkE("eyelashes", .faceFeature, "睫毛")])
        let pNest = AnnotatePipeline.process(mkG(recNest, [mkI("left eye", 1, [100, 100, 200, 200], 0.9),
                                                           mkI("eyelashes", 1, [120, 120, 150, 160], 0.85)]))
        check(pNest.count == 2, "M4 嵌套保留:睫毛⊂眼 两者都在")
        // 13.4 排序:person 在前,其后按面积降序(sky 100000 > desk 90000)
        let recSort = OllamaVision.EntityRecognition(styleDescription: "", highLevelDescription: "",
                                                     entities: [mkE("oak desk", .furniture, "书桌"),
                                                                mkE("blue sky", .nature, "天空"),
                                                                mkE("girl", .person, "女孩")])
        let pSort = AnnotatePipeline.process(mkG(recSort, [mkI("oak desk", 1, [600, 600, 900, 900], 0.9),
                                                           mkI("blue sky", 1, [0, 0, 100, 1000], 0.9),
                                                           mkI("girl", 1, [200, 200, 600, 600], 0.9)]))
        check(pSort.map(\.label) == ["girl", "blue sky", "oak desk"], "M4 排序:person 在前 + 面积降序")

        // 13.5 caption 组装:在线含 bbox 版 → EditorState.parse 直接进画布
        let recCap = OllamaVision.EntityRecognition(
            styleDescription: "minimalist still-life photograph",
            highLevelDescription: "白裙女孩坐在书桌前",
            entities: [mkE("girl in white dress", .person, "穿白裙的女孩", ["#FFFFFF"]),
                       mkE("left eye", .faceFeature, "左眼,深棕色", ["#3B2F2F"]),
                       mkE("oak desk", .furniture, "橡木书桌", ["#8B5A2B"]),
                       mkE("blue sky", .nature, "蔚蓝天空背景", ["#87CEEB"])])
        let gCap = mkG(recCap, [mkI("girl in white dress", 1, [50, 100, 900, 700], 0.95),
                                mkI("left eye", 1, [200, 300, 260, 380], 0.8),
                                mkI("oak desk", 1, [600, 50, 950, 950], 0.9),
                                mkI("blue sky", 1, [0, 0, 620, 1000], 0.88)])
        let capM4 = AnnotatePipeline.buildCaption(from: gCap)
        if case .obj(let topPairs) = capM4 {
            check(topPairs.map(\.0) == ["high_level_description", "style_description", "compositional_deconstruction"],
                  "M4 caption:顶层键序 high_level → style → compositional")
        } else { check(false, "M4 caption:顶层键序") }
        check(capM4["style_description"]?["aesthetics"]?.stringValue == "minimalist still-life photograph",
              "M4 caption:style 字符串填入 aesthetics")
        check(capM4["style_description"]?["photo"] == .bool(true), "M4 caption:含 photograph 字样给 photo:true")
        check(capM4["style_description"]?["color_palette"]?.arrayValue?.compactMap { $0.stringValue } == ["#FFFFFF", "#3B2F2F", "#8B5A2B", "#87CEEB"],
              "M4 caption:style 色板取全部实体去重保序")
        check(capM4["compositional_deconstruction"]?["background"]?["description"]?.stringValue == "蔚蓝天空背景",
              "M4 caption:nature 面积>60% 画布 → background")
        let sM4 = EditorState()
        sM4.parse(JValWriter.compact(capM4))
        check(sM4.parseError == nil && sM4.boxes.count == 4, "M4 caption:EditorState.parse 解析 4 元素进画布")
        check(sM4.boxes[0].desc == "穿白裙的女孩", "M4 caption:person 元素在最前")
        check(abs(sM4.boxes[0].y - 51.2) < 0.5 && abs(sM4.boxes[0].x - 76.8) < 0.5,
              "M4 caption:轴序 [ymin,xmin,ymax,xmax] 反归一化正确")
        check(sM4.boxes[0].colorPalette == ["#FFFFFF"], "M4 caption:元素色板进画布")
        check(sM4.boxes[1].desc == "蔚蓝天空背景", "M4 caption:person 之后按面积降序")
        check(sM4.styleType == .photo && sM4.aesthetics == "minimalist still-life photograph",
              "M4 caption:style_description 对象正确回填")
        check(sM4.paletteText.contains("#8B5A2B"), "M4 caption:style 色板回填")
        check(sM4.bgDesc == "蔚蓝天空背景" && sM4.highLevel == "白裙女孩坐在书桌前", "M4 caption:background/high_level 回填")
        // 13.5b style 转换分支:无 photo/photograph/realistic 字样 → art_style:true
        let capArt = AnnotatePipeline.buildCaption(from: mkG(
            OllamaVision.EntityRecognition(styleDescription: "soft watercolor anime illustration", highLevelDescription: "",
                                           entities: [mkE("cat", .other, "猫")]),
            [mkI("cat", 1, [100, 100, 500, 500], 0.9)]))
        check(capArt["style_description"]?["art_style"] == .bool(true) && capArt["style_description"]?["photo"] == nil,
              "M4 caption:非 photo 字样给 art_style:true")
        // 13.5c style 色板上限 8(10 实体不同色 → 取前 8,首次出现顺序)
        let capPal = AnnotatePipeline.buildCaption(from: mkG(
            OllamaVision.EntityRecognition(styleDescription: "photo", highLevelDescription: "",
                                           entities: (0..<10).map { mkE("obj\($0)", .other, "物\($0)", ["#C\($0)"]) }), []))
        let palArr = capPal["style_description"]?["color_palette"]?.arrayValue?.compactMap { $0.stringValue }
        check(palArr?.count == 8 && palArr?.first == "#C0", "M4 caption:style 色板去重上限 8 保首次出现序")
        // 13.5d 离线无 bbox 版:元素照写省略 bbox,background 关键词兜底,parse 安全落地
        let gOff = mkG(OllamaVision.EntityRecognition(
            styleDescription: "anime illustration", highLevelDescription: "室内场景",
            entities: [mkE("girl", .person, "女孩", ["#FFFFFF"]),
                       mkE("cozy room interior", .furniture, "温馨的室内背景", ["#EEEEEE"])]), [], online: false)
        let capOff = AnnotatePipeline.buildCaption(from: gOff)
        let elsOff = capOff["compositional_deconstruction"]?["elements"]?.arrayValue
        check(elsOff?.count == 2, "M4 离线:无 bbox 实体仍写入元素")
        check(elsOff?.first?["bbox"] == nil && elsOff?.first?["description"]?.stringValue == "女孩",
              "M4 离线:元素省略 bbox 字段")
        check(capOff["compositional_deconstruction"]?["background"]?["description"]?.stringValue == "温馨的室内背景",
              "M4 离线:background 无 bbox 关键词兜底")
        let sOff = EditorState()
        sOff.parse(JValWriter.compact(capOff))
        check(sOff.boxes.isEmpty && sOff.styleType == .artStyle && sOff.aesthetics == "anime illustration",
              "M4 离线:parse 安全落地且 style 仍回填")

        // 13.6 生成视图折叠:11 元素(5 部件 + person + 书桌/书架 + 天空/苹果/杯子)
        let recFold = OllamaVision.EntityRecognition(
            styleDescription: "anime illustration", highLevelDescription: "女孩在书房",
            entities: [mkE("girl", .person, "女孩"),
                       mkE("left eye", .faceFeature, "左眼"),
                       mkE("right eye", .faceFeature, "右眼"),
                       mkE("long hair", .hair, "长发"),
                       mkE("left hand", .handArm, "左手"),
                       mkE("white skirt", .garmentPart, "白裙"),
                       mkE("oak desk", .furniture, "橡木书桌"),
                       mkE("bookshelf", .furniture, "书架"),
                       mkE("blue sky", .nature, "天空"),
                       mkE("red apple", .other, "红苹果"),
                       mkE("coffee cup", .other, "咖啡杯")])
        let gFold = mkG(recFold, [mkI("girl", 1, [100, 200, 800, 700], 0.95),
                                  mkI("left eye", 1, [200, 300, 260, 380], 0.8),
                                  mkI("right eye", 1, [200, 450, 260, 530], 0.8),
                                  mkI("long hair", 1, [120, 250, 300, 650], 0.85),
                                  mkI("left hand", 1, [600, 150, 700, 250], 0.75),
                                  mkI("white skirt", 1, [450, 350, 800, 650], 0.9),
                                  mkI("oak desk", 1, [700, 50, 950, 950], 0.9),
                                  mkI("bookshelf", 1, [705, 55, 948, 948], 0.85),
                                  mkI("blue sky", 1, [0, 0, 90, 1000], 0.9),
                                  mkI("red apple", 1, [820, 600, 880, 680], 0.8),
                                  mkI("coffee cup", 1, [820, 750, 870, 820], 0.8)])
        let fullEls = AnnotatePipeline.process(gFold)
        check(fullEls.count == 11, "M4 折叠:全量 11 元素(画布保留全量标注)")
        let folded = AnnotatePipeline.collapse(fullEls)
        check(folded.count >= 3 && folded.count <= 6, "M4 折叠:生成视图 3–6 个主元素(实际 \(folded.count))")
        let personEl = folded.first { $0.category == .person }
        check(personEl?.bbox == [100, 150, 800, 700], "M4 折叠:person 子部件 bbox 并集正确")
        check(personEl?.desc.contains("左眼") == true && personEl?.desc.contains("白裙") == true,
              "M4 折叠:description 追加合并")
        check(!folded.contains { $0.label == "bookshelf" }, "M4 折叠:异 label IoU>0.85 收敛保大框(desk)")
        // 折叠输出两两 IoU ≤0.85
        let fbb = folded.compactMap(\.bbox)
        var maxFoldIoU = 0.0
        for i in fbb.indices { for j in (i + 1)..<fbb.count { maxFoldIoU = max(maxFoldIoU, AnnotatePipeline.iou(fbb[i], fbb[j])) } }
        check(fbb.count == folded.count && maxFoldIoU <= 0.85, "M4 折叠:输出元素两两 IoU ≤0.85")
        // 无 person 时部件并入面积最大的容器元素
        let foldedNoP = AnnotatePipeline.collapse(AnnotatePipeline.process(mkG(
            OllamaVision.EntityRecognition(styleDescription: "", highLevelDescription: "",
                                           entities: [mkE("wardrobe", .furniture, "衣柜"),
                                                      mkE("collar", .garmentPart, "衣领")]),
            [mkI("wardrobe", 1, [50, 50, 500, 500], 0.9), mkI("collar", 1, [100, 100, 200, 200], 0.8)])))
        check(foldedNoP.count == 1 && foldedNoP[0].label == "wardrobe" && foldedNoP[0].bbox == [50, 50, 500, 500]
                && foldedNoP[0].desc.contains("衣领"),
              "M4 折叠:无 person 时部件并入面积最大容器")
        // collapseCaption:elements 替换为折叠结果,其余字段与键序原样保留,且可直接 parse
        let capFull = AnnotatePipeline.buildCaption(from: gFold, elements: fullEls)
        let capFolded = AnnotatePipeline.collapseCaption(full: capFull, elements: fullEls)
        check(capFolded["compositional_deconstruction"]?["elements"]?.arrayValue?.count == folded.count,
              "M4 折叠:caption elements 替换为折叠结果")
        check(capFolded["high_level_description"] == capFull["high_level_description"]
                && capFolded["style_description"] == capFull["style_description"],
              "M4 折叠:caption 其余字段原样保留")
        let sFold = EditorState()
        sFold.parse(JValWriter.compact(capFolded))
        check(sFold.parseError == nil && sFold.boxes.count == folded.count, "M4 折叠:生成视图 caption 可直接 parse 进画布")

        // 14) M5:UI 面板状态映射 / 底面背景状态位 / 导入画布接线(全部离线断言,不依赖本机 Ollama/ComfyUI 真实状态)
        // 14.1 逐实体进度状态映射(识别中/定位中/完成/失败/离线无 bbox)
        check(AIStatusMapper.rowStatus(label: "girl", grounded: nil, phase: .recognizing) == .pending,
              "M5 状态映射:识别中 → pending")
        check(AIStatusMapper.rowStatus(label: "girl", grounded: nil, phase: .grounding) == .locating,
              "M5 状态映射:定位中 → locating")
        check(AIStatusMapper.rowStatus(label: "girl in white dress", grounded: gCap, phase: .done) == .done(0.95),
              "M5 状态映射:完成 → done(最高 score)")
        check(AIStatusMapper.rowStatus(label: "不存在的实体", grounded: gCap, phase: .done) == .failed("未检出"),
              "M5 状态映射:在线未检出 → failed")
        check(AIStatusMapper.rowStatus(label: "girl", grounded: gOff, phase: .done) == .noBBox,
              "M5 状态映射:离线降级 → 无 bbox(清单仍可导入)")
        check(AIStatusMapper.rowStatus(label: "girl", grounded: gOff, phase: .failed("boom")) == .failed("boom"),
              "M5 状态映射:管线失败 → failed")
        // 14.2 底面背景状态位:三档合法 / ⌥B 翻转 / 序列化往返(测试钩子指向临时文件,不碰真实 configs.json)
        check(EditorState.bgOpacitySteps == [0.3, 0.6, 1.0], "M5 底图:opacity 三档值合法(30/60/100%)")
        let tmpCfgURL = FileManager.default.temporaryDirectory.appendingPathComponent("bbd_m5_\(UUID().uuidString).json")
        let sBg = EditorState(testConfigsURL: tmpCfgURL)
        sBg.configs = []
        check(sBg.bgVisible && sBg.bgOpacity == 0.6, "M5 底图:默认 visible + 60%")
        sBg.setBgOpacity(0.3)
        check(sBg.bgOpacity == 0.3, "M5 底图:切 30% 档")
        sBg.setBgOpacity(0.5)
        check(sBg.bgOpacity == 0.6, "M5 底图:非法值吸附最近档(0.5 → 60%)")
        sBg.setBgOpacity(0.9)
        check(sBg.bgOpacity == 1.0, "M5 底图:0.9 吸附 100% 档")
        let vBg0 = sBg.bgVisible
        sBg.toggleBgVisible()
        check(sBg.bgVisible == !vBg0, "M5 底图:⌥B visible 翻转")
        sBg.toggleBgVisible()
        check(sBg.bgVisible == vBg0, "M5 底图:⌥B 再次翻转恢复")
        sBg.bgVisible = false
        sBg.setBgOpacity(1.0) // 走完整持久化路径写出(含 visible=false)
        let sBg2 = EditorState(testConfigsURL: tmpCfgURL)
        check(sBg2.bgVisible == false && sBg2.bgOpacity == 1.0, "M5 底图:visible/opacity 写出再读回一致")
        // 旧格式(裸 [SavedConfig] 数组)兼容:设置位给默认,不丢配置
        try? Data("[]".utf8).write(to: tmpCfgURL)
        let sBg3 = EditorState(testConfigsURL: tmpCfgURL)
        check(sBg3.bgVisible && sBg3.bgOpacity == 0.6 && sBg3.configs.isEmpty, "M5 底图:旧格式 configs.json 兼容读取")
        try? FileManager.default.removeItem(at: tmpCfgURL)
        // 14.3 「导入画布」接线:mock GroundedRecognition → buildCaption → EditorState.parse(与 M4 同 fixture,数量一致)
        let capStrM5 = AnnotatePipeline.captionString(from: gFold)
        let sAI = EditorState()
        sAI.parse(capStrM5)
        check(sAI.parseError == nil && sAI.boxes.count == fullEls.count,
              "M5 导入画布:buildCaption → parse,boxes 数与 M4 自测一致(\(fullEls.count))")
        let capFoldStrM5 = JValWriter.compact(AnnotatePipeline.collapseCaption(
            full: AnnotatePipeline.buildCaption(from: gFold, elements: fullEls), elements: fullEls))
        let sAI2 = EditorState()
        sAI2.parse(capFoldStrM5)
        check(sAI2.parseError == nil && sAI2.boxes.count == folded.count, "M5 生成视图:折叠 caption 可直接 parse")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
