import AppKit
import Foundation

/// M1 · Ollama 视觉实体识别客户端(PLAN-image-auto-bbox §2 Step 1)。
/// - POST {host}/api/chat,format:json、stream:false、temperature 0.1;
/// - 图片预处理为最长边 1568、JPEG q85 base64,经 message.images 传输;
/// - 默认模型 qwen3.8:27b-mlx(M0 实测视觉可用;gemma4:e4b-mlx 无图像输入能力,HTTP 400);
/// - 输出强校验:JSONDecode 失败重试 1 次;
/// - 响应 load/prompt_eval/eval_duration(ns) 全部采入日志。
enum OllamaVision {
    static let defaultHost = "http://127.0.0.1:11434"
    static let defaultModel = "qwen3.8:27b-mlx"
    /// Qwen-VL 甜点边长,见 Plan §2 Step 1。
    static let maxEdge = 1568
    static let jpegQuality = 0.85

    /// 实体识别系统提示词,固定为 Plan §4-A(穷尽 7 层 + style_description + color_palette)。
    static let systemPrompt = """
    你是图像实体清点专家。仔细审视这张图片,输出严格 JSON(不要输出任何其他文字):
    {
      "style_description": "<整体画风一句话,如 anime illustration, soft watercolor, cinematic photo>",
      "high_level_description": "<全图一句话概括>",
      "entities": [
        {"label": "<2-5词的简短英文名词短语,用于检测模型文本提示>", "category": "<person|garment|garment_part|face_feature|hair|hand_arm|furniture|nature|other>", "desc": "<中文详细描述,含颜色/材质/姿态>", "color_palette": ["#rrggbb"]}
      ]
    }
    必须穷尽以下层次(存在才输出,宁多勿漏):
    1. 人物整体(person: girl, boy, woman…)
    2. 服装整体与每个部件:连衣裙、上衣、裙子、裤子、连裤袜、袜子、鞋、帽子、发饰、领结…逐件列出
    3. 五官逐个:左眼、右眼、睫毛、眉毛、鼻子、嘴、耳朵
    4. 头发(整体发型;有明显分区如双马尾则分区列出)
    5. 手与手臂:每只手、每条手臂、可见手指
    6. 场景与道具:室内(书桌、床、椅、窗、灯、书架…)/ 室外(树、建筑、道路…)逐件列出
    7. 自然元素:花丛、草丛、云、天空、太阳、水面…
    label 必须具体(用 "white pleated skirt" 而非 "skirt"),每个实体描述含主色 hex。
    """

    // MARK: - 数据模型

    struct AnnotateEntity: Equatable {
        /// Plan §4-A 固定类别,无法识别的值归并为 other。
        enum Category: String, Equatable, CaseIterable {
            case person, garment
            case garmentPart = "garment_part"
            case faceFeature = "face_feature"
            case hair
            case handArm = "hand_arm"
            case furniture, nature, other
        }
        var label: String
        var category: Category
        var desc: String
        var colorPalette: [String]
    }

    struct EntityRecognition: Equatable {
        var styleDescription: String
        var highLevelDescription: String
        var entities: [AnnotateEntity]
    }

    /// Ollama 响应耗时(ns → s),wall 由客户端掐表。
    struct OllamaTimings: Equatable {
        var wall: Double = 0
        var loadDuration: Double? = nil
        var promptEvalDuration: Double? = nil
        var evalDuration: Double? = nil
        var promptEvalCount: Int? = nil
        var evalCount: Int? = nil

        var summary: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%.2fs", $0) } ?? "-" }
            var s = "wall=\(String(format: "%.2f", wall))s load=\(f(loadDuration)) prompt_eval=\(f(promptEvalDuration)) eval=\(f(evalDuration))"
            if let n = evalCount { s += " (\(n) tok)" }
            return s
        }
    }

    enum OllamaError: Error, Equatable {
        case badHost(String)
        case http(Int, String)
        case emptyContent
        /// 重试 1 次后仍无法解析为合法实体清单 JSON。
        case undecodableResponse
        case imagePreprocessFailed
    }

    // MARK: - 图片预处理(最长边 1568、JPEG q85)

    /// 返回 (base64, 预处理后宽, 高)。用 ImageIO 缩略图保持方向元数据正确。
    static func preprocessImage(_ data: Data, maxEdge: Int = maxEdge, quality: Double = jpegQuality) -> (base64: String, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return (jpeg.base64EncodedString(), cg.width, cg.height)
    }

    // MARK: - 响应容错解析(纯函数,--selftest 直接断言)

    /// 从模型输出文本中容错解析实体清单:
    /// - 允许前后多余文本(JValParser.parseLoose 提取首个 {...} 块);
    /// - 缺 style/high_level 字段给空串,entities 缺失给空数组;
    /// - 实体缺 label 则丢弃该条,缺 category/desc/color_palette 给默认值;
    /// - 完全无 JSON 块返回 nil(由调用方触发重试)。
    static func parseEntityResponse(_ text: String) -> EntityRecognition? {
        guard let root = JValParser.parseLoose(text), root.isObject else { return nil }
        let style = root["style_description"]?.stringValue ?? ""
        let high = root["high_level_description"]?.stringValue ?? ""
        var entities: [AnnotateEntity] = []
        if let arr = root["entities"]?.arrayValue {
            for e in arr {
                guard let label = e["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else { continue }
                let catRaw = e["category"]?.stringValue ?? ""
                let cat = AnnotateEntity.Category(rawValue: catRaw) ?? .other
                let desc = e["desc"]?.stringValue ?? e["description"]?.stringValue ?? label
                let palette = e["color_palette"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                entities.append(AnnotateEntity(label: label, category: cat, desc: desc, colorPalette: palette))
            }
        }
        return EntityRecognition(styleDescription: style, highLevelDescription: high, entities: entities)
    }

    // MARK: - 模型选择器(只保留 capabilities 含 "vision" 的模型)

    /// GET {host}/api/tags,过滤 capabilities 含 "vision";接口失败时回退 `ollama list`(CLI 无能力信息,不过滤)。
    static func listVisionModels(host: String = defaultHost) async -> [String] {
        guard let url = URL(string: host + "/api/tags") else { return cliListModels() }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = JValParser.parse(String(decoding: data, as: UTF8.self)),
                  let models = root["models"]?.arrayValue else { return cliListModels() }
            let vision = models.compactMap { m -> String? in
                guard let caps = m["capabilities"]?.arrayValue,
                      caps.contains(where: { $0.stringValue == "vision" }) else { return nil }
                return m["name"]?.stringValue
            }
            return vision.isEmpty ? cliListModels() : vision
        } catch {
            return cliListModels()
        }
    }

    /// `ollama list` 输出第一列模型名(跳过表头),作为 /api/tags 不可用时的兜底。
    static func cliListModels() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ollama", "list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .dropFirst() // NAME ID SIZE MODIFIED
            .compactMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) }
    }

    // MARK: - HTTP 调用

    /// 单次 /api/chat 调用,返回 (content, timings)。图片为 base64,经 message.images 传输。
    static func chat(host: String = defaultHost,
                     model: String = defaultModel,
                     imageBase64: String,
                     prompt: String = "请输出该图片的实体清单 JSON。") async throws -> (content: String, timings: OllamaTimings) {
        guard let url = URL(string: host + "/api/chat") else { throw OllamaError.badHost(host) }
        let payload: [String: Any] = [
            "model": model,
            "format": "json",
            "stream": false,
            "options": ["temperature": 0.1],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt, "images": [imageBase64]]
            ]
        ]
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        var timings = OllamaTimings(wall: Date().timeIntervalSince(t0))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw OllamaError.http(code, String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let root = JValParser.parse(String(decoding: data, as: UTF8.self)) else {
            throw OllamaError.emptyContent
        }
        func ns(_ key: String) -> Double? { root[key]?.doubleValue.map { $0 / 1e9 } }
        timings.loadDuration = ns("load_duration")
        timings.promptEvalDuration = ns("prompt_eval_duration")
        timings.evalDuration = ns("eval_duration")
        timings.promptEvalCount = root["prompt_eval_count"]?.doubleValue.map(Int.init)
        timings.evalCount = root["eval_count"]?.doubleValue.map(Int.init)
        guard let content = root["message"]?["content"]?.stringValue, !content.isEmpty else {
            throw OllamaError.emptyContent
        }
        return (content, timings)
    }

    // MARK: - 实体识别(含重试 1 次)

    /// 预处理图片 → /api/chat → 容错解析;解析失败重试 1 次后抛 undecodableResponse。
    static func recognizeEntities(imageData: Data,
                                  host: String = defaultHost,
                                  model: String = defaultModel,
                                  log: (String) -> Void = { print($0) }) async throws -> (result: EntityRecognition, timings: OllamaTimings) {
        guard let img = preprocessImage(imageData) else { throw OllamaError.imagePreprocessFailed }
        log("[OllamaVision] 预处理完成:\(img.width)×\(img.height) JPEG q\(Int(jpegQuality * 100)) base64 \(img.base64.count / 1024)KB,模型 \(model)")
        var lastTimings = OllamaTimings()
        for attempt in 0...1 {
            let (content, timings) = try await chat(host: host, model: model, imageBase64: img.base64)
            lastTimings = timings
            log("[OllamaVision] \(timings.summary)")
            if let parsed = parseEntityResponse(content) {
                return (parsed, timings)
            }
            log("[OllamaVision] 响应解析失败(attempt \(attempt + 1)):\(content.prefix(120))…")
        }
        throw OllamaError.undecodableResponse
    }

    // MARK: - CLI 冒烟(--ollama-smoke <图片路径> [模型])

    static func smokeTest(imagePath: String, model: String = defaultModel, host: String = defaultHost) async -> Int32 {
        guard let data = FileManager.default.contents(atPath: imagePath) else {
            print("[OllamaVision] 读不到图片:\(imagePath)")
            return 1
        }
        let models = await listVisionModels(host: host)
        print("[OllamaVision] 视觉模型列表:\(models.isEmpty ? "(空,Ollama 未在线?)" : models.joined(separator: ", "))")
        do {
            let (result, timings) = try await recognizeEntities(imageData: data, host: host, model: model)
            print("[OllamaVision] style: \(result.styleDescription)")
            print("[OllamaVision] 概括: \(result.highLevelDescription)")
            print("[OllamaVision] 实体清单(\(result.entities.count)):")
            for (i, e) in result.entities.enumerated() {
                print("  \(i + 1). [\(e.category.rawValue)] \(e.label) — \(e.desc) \(e.colorPalette.joined(separator: " "))")
            }
            print("[OllamaVision] timings: \(timings.summary)")
            return 0
        } catch {
            print("[OllamaVision] 识别失败:\(error)")
            return 1
        }
    }
}
