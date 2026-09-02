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
              {"type":"obj", "bbox":[100,200,500,600], "description":"a cat on a chair", "color_palette":["#FACC15"]},
              {"type":"obj", "bbox":[600,100,900,400], "desc":"a lamp"}
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

        // 2) 输出 caption
        let cap = s.buildCaption()
        let capStr = JValWriter.compact(cap)
        check(capStr.contains("\"compositional_deconstruction\""), "caption 含 compositional_deconstruction")
        check(capStr.contains("\"bbox\": [100,200,500,600]"), "caption bbox 归一化单行 [ymin,xmin,ymax,xmax]")
        check(capStr.contains("\"photo\": true"), "style photo=true")

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

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
