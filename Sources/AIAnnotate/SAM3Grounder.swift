import Foundation
import ImageIO

/// M3 · SAM3 开放词表检测定位客户端(ComfyUI API 格式 workflow,PLAN-image-auto-bbox §2 Step 2)。
/// - workflow 原型 = M0 报告 §2:LoadImage → CheckpointLoaderSimple(sam3.1_multiplex_fp16) →
///   CLIPTextEncode → SAM3_Detect(threshold 0.5, refine_iterations 2, individual_masks false),
///   内嵌为 JVal 构建(保序),不动 Package.swift 资源声明;
/// - 调用流程:POST /upload/image → POST /prompt → 轮询 GET /history/{prompt_id} 取节点 4 bboxes;
/// - 像素 bbox → Ideogram 归一化复用 M2 AutoResolution.pixelsToIdeogram;
/// - 优雅降级:system_stats 不可达 / 权重缺失 → 返回仅清单无 bbox 的合法 GroundedRecognition,
///   M4 管线无需区分在线/离线路径。
///
/// 本机节点源码实测(超出 M0 报告的两点结论,comfy_extras/nodes_sam3.py + comfy/text_encoders/sam3_clip.py):
/// 1. CLIPTextEncode 的 text 逗号分隔即原生多类别单次前向(sam3_multi_cond),
///    且支持 "label:N" 后缀控制每类最大检出数(默认 1!不写 :N 则 hand 等多实例概念只出 1 框);
/// 2. SAM3_Detect 输出的 bbox dict 只有 x/y/width/height/score,**无 label 归属**;
///    检出按 prompt 顺序追加。因此批量结果仅在「返回框数 == 实体数」时可按位归属(每类恰好 1 框),
///    否则(漏检或多实例)转逐实体通道获得正确归属与多实例。
enum SAM3Grounder {
    static let defaultHost = "http://127.0.0.1:8188"
    static let ckptName = "sam3.1_multiplex_fp16.safetensors"

    // MARK: - 阈值与限流参数(M0 §2 结论 + M3 方案)

    /// 批量/首检阈值,与 M0 workflow 一致。
    static let detectThreshold = 0.5
    /// 逐实体重试档阈值:M0 §2 注 4「低置信实体降到 <0.4 重试档」,取 0.3。
    static let retryThreshold = 0.3
    /// 低于该 score 的实体视为低置信,进重试通道。
    static let lowScoreThreshold = 0.4
    /// 每类最大检出数(text "label:N" 后缀),覆盖 hand/eye 等多实例概念。
    static let maxDetectionsPerLabel = 8
    /// 逐实体通道并发上限(信号量)。
    static let retryConcurrency = 4
    /// 单实体超时隔离(秒)。
    static let perEntityTimeout: Double = 60
    /// 批量调用超时(秒)。
    static let batchTimeout: Double = 120

    // MARK: - 数据模型(M4 统一消费,无需区分在线/离线)

    /// SAM3 节点 4 输出的逐实例像素框(orig_size 原图像素坐标)。
    struct SAM3Detection: Equatable, Sendable {
        var x, y, width, height, score: Double
    }

    /// 归一化后的逐实例结果:同概念多实例 hand_1/hand_2 逐条返回。
    struct GroundedInstance: Equatable, Sendable {
        /// 对应 M1 实体的原始 label(用于按 label 反查)。
        var label: String
        /// 同概念实例序号,1 起。
        var instanceIndex: Int
        /// 实例名:label 空格转下划线 + _N,如 hand_1 / left_hand_2。
        var instanceName: String
        /// Ideogram 轴序 [ymin,xmin,ymax,xmax] @0–1000(经 M2 pixelsToIdeogram)。
        var bbox: [Int]
        var score: Double
    }

    /// M3 输出:M1 实体清单原样携带 + 定位实例数组。
    /// 离线/降级时 instances 为空、sam3Online=false,结构同样合法,M4 同一条消费路径。
    struct GroundedRecognition: Equatable, Sendable {
        var recognition: OllamaVision.EntityRecognition
        var instances: [GroundedInstance]
        var sam3Online: Bool
        /// 降级原因或运行摘要(日志性质)。
        var note: String

        /// 按 label 取全部实例(在线/离线同一入口,离线返回空数组)。
        func instances(forLabel label: String) -> [GroundedInstance] {
            instances.filter { $0.label == label }
        }

        /// 按 label 取最高分实例的归一化 bbox(离线返回 nil)。
        func bestBBox(forLabel label: String) -> [Int]? {
            instances(forLabel: label).max(by: { $0.score < $1.score })?.bbox
        }
    }

    enum SAM3Error: Error, Equatable {
        case badHost(String)
        case http(Int, String)
        case uploadFailed
        case promptRejected(String)
        case executionError(String)
        case timeout(Double)
        case badResponse
    }

    // MARK: - 同义词回退表(逐实体重试未检出时按序替换再试)

    static let synonymTable: [String: String] = [
        "tights": "pantyhose", "pantyhose": "tights",
        "skirt": "dress", "dress": "skirt",
        "sneakers": "shoes", "shoes": "sneakers",
        "sofa": "couch", "couch": "sofa",
        "cup": "mug", "mug": "cup",
        "cellphone": "phone", "phone": "cellphone",
        "tie": "necktie", "necktie": "tie",
        "pupil": "eye", "iris": "eye",
        "bangs": "hair", "ponytail": "hair",
    ]

    /// 对 label 内命中同义词表的词做替换,返回去重后的候选(不含原 label)。
    /// 如 "black tights" → ["black pantyhose"]。
    static func synonymCandidates(for label: String) -> [String] {
        let words = label.split(separator: " ").map(String.init)
        var out: [String] = []
        for (i, w) in words.enumerated() {
            guard let syn = synonymTable[w.lowercased()] else { continue }
            var alt = words
            alt[i] = syn
            let s = alt.joined(separator: " ")
            if s != label && !out.contains(s) { out.append(s) }
        }
        return out
    }

    // MARK: - workflow 构建(保序 JVal,对应 M0 报告 §2 API 格式)

    /// SAM3 text 输入清洗:逗号是类别分隔符、":N" 是检出数后缀、括号会被分词器剥离,
    /// 一律从 label 中移除,防止破坏批量协议。
    static func sanitizeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "[,():]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 构建 M0 §2 的 API 格式 workflow。text = 逗号分隔 label 列表,每个带 ":N" 最大检出数后缀。
    static func buildWorkflow(imageName: String,
                              labels: [String],
                              threshold: Double = detectThreshold,
                              refineIterations: Int = 2,
                              individualMasks: Bool = false,
                              maxDetPerLabel: Int = maxDetectionsPerLabel) -> JVal {
        let text = labels.map { "\(sanitizeLabel($0)):\(maxDetPerLabel)" }.joined(separator: ", ")
        return .obj([
            ("1", .obj([
                ("class_type", .str("LoadImage")),
                ("inputs", .obj([("image", .str(imageName))]))
            ])),
            ("2", .obj([
                ("class_type", .str("CheckpointLoaderSimple")),
                ("inputs", .obj([("ckpt_name", .str(ckptName))]))
            ])),
            ("3", .obj([
                ("class_type", .str("CLIPTextEncode")),
                ("inputs", .obj([
                    ("text", .str(text)),
                    ("clip", .arr([.str("2"), .num(1)]))
                ]))
            ])),
            ("4", .obj([
                ("class_type", .str("SAM3_Detect")),
                ("inputs", .obj([
                    ("model", .arr([.str("2"), .num(0)])),
                    ("image", .arr([.str("1"), .num(0)])),
                    ("conditioning", .arr([.str("3"), .num(0)])),
                    ("threshold", .num(threshold)),
                    ("refine_iterations", .num(Double(refineIterations))),
                    ("individual_masks", .bool(individualMasks))
                ]))
            ]))
        ])
    }

    /// /prompt 提交体:{"prompt": workflow},保序。
    static func buildPromptBody(workflow: JVal) -> JVal {
        .obj([("prompt", workflow)])
    }

    // MARK: - history 解析与 masks 互验(纯函数,--selftest 直接断言)

    /// 从 GET /history/{prompt_id} 响应体中取节点 4 的逐实例 bboxes。
    /// 兼容两种形态:逐帧嵌套 [[{...}]](节点输出 list[list[dict]])与扁平 [{...}]。
    /// 返回 nil = 结果未就绪(outputs 未出现);空数组 = 已就绪但零检出。
    static func parseDetections(_ historyBody: JVal, promptID: String) -> [SAM3Detection]? {
        guard let nodeOut = historyBody[promptID]?["outputs"]?["4"],
              let raw = nodeOut["bboxes"]?.arrayValue else { return nil }
        var flat: [JVal] = []
        for item in raw {
            if let inner = item.arrayValue { flat.append(contentsOf: inner) } else { flat.append(item) }
        }
        var dets: [SAM3Detection] = []
        for item in flat {
            guard let x = item["x"]?.doubleValue, let y = item["y"]?.doubleValue,
                  let w = item["width"]?.doubleValue, let h = item["height"]?.doubleValue else { continue }
            dets.append(SAM3Detection(x: x, y: y, width: w, height: h,
                                      score: item["score"]?.doubleValue ?? 0))
        }
        return dets
    }

    /// MASK(行主序二维数组,值 ≥ threshold 视为前景)求外接矩形,返回像素 (x,y,w,h);空 mask 返回 nil。
    static func maskBoundingRect(_ mask: [[Double]], threshold: Double = 0.5) -> (x: Double, y: Double, w: Double, h: Double)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for (r, row) in mask.enumerated() {
            for (c, v) in row.enumerated() where v >= threshold {
                minX = min(minX, c); maxX = max(maxX, c)
                minY = min(minY, r); maxY = max(maxY, r)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (Double(minX), Double(minY), Double(maxX - minX + 1), Double(maxY - minY + 1))
    }

    /// mask 外接矩形与检测 bbox 互验(中心与边长容差 tolerancePx)。
    static func crossCheck(_ det: SAM3Detection, maskRect: (x: Double, y: Double, w: Double, h: Double), tolerance: Double = 2) -> Bool {
        abs(det.x - maskRect.x) <= tolerance && abs(det.y - maskRect.y) <= tolerance
            && abs(det.width - maskRect.w) <= tolerance * 2 && abs(det.height - maskRect.h) <= tolerance * 2
    }

    /// history 中若携带可序列化 masks(通常为 tensor 不会出现,防御性处理),逐实例与 bboxes 互验,
    /// 返回不一致说明;无 masks 或全部一致返回 nil。
    static func verifyAgainstMasks(_ historyBody: JVal, promptID: String, detections: [SAM3Detection]) -> String? {
        guard let masks = historyBody[promptID]?["outputs"]?["4"]?["masks"]?.arrayValue, !masks.isEmpty else { return nil }
        var mismatches: [String] = []
        for (i, m) in masks.enumerated() {
            guard let rows = m.arrayValue?.map({ row in row.arrayValue?.compactMap { $0.doubleValue } ?? [] }),
                  let rect = maskBoundingRect(rows) else { continue }
            if i < detections.count, !crossCheck(detections[i], maskRect: rect) {
                mismatches.append("#\(i + 1) bbox(\(detections[i].x),\(detections[i].y) vs mask(\(rect.x),\(rect.y))")
            }
        }
        return mismatches.isEmpty ? nil : "masks 互验不一致:" + mismatches.joined(separator: ";")
    }

    /// 像素检出 → Ideogram 归一化逐实例结果(复用 M2 AutoResolution.pixelsToIdeogram,不另写换算)。
    static func makeInstances(label: String, detections: [SAM3Detection],
                              imageW: Double, imageH: Double) -> [GroundedInstance] {
        let base = sanitizeLabel(label).replacingOccurrences(of: " ", with: "_")
        return detections.enumerated().map { (i, d) in
            GroundedInstance(
                label: label,
                instanceIndex: i + 1,
                instanceName: "\(base)_\(i + 1)",
                bbox: AutoResolution.pixelsToIdeogram(x: d.x, y: d.y, w: d.width, h: d.height,
                                                      imageW: imageW, imageH: imageH),
                score: d.score)
        }
    }

    // MARK: - HTTP 原语

    /// GET /system_stats 探活(短超时,降级判据之一)。
    static func systemStatsOK(host: String) async -> Bool {
        guard let url = URL(string: host + "/system_stats") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// GET /object_info/CheckpointLoaderSimple 取可用 ckpt 列表,确认 sam3 权重已就位。
    static func listCheckpoints(host: String) async -> [String]? {
        guard let url = URL(string: host + "/object_info/CheckpointLoaderSimple") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = JValParser.parse(String(decoding: data, as: UTF8.self)),
                  let list = root["CheckpointLoaderSimple"]?["input"]?["required"]?["ckpt_name"]?.arrayValue?.first?.arrayValue
            else { return nil }
            return list.compactMap { $0.stringValue }
        } catch { return nil }
    }

    /// POST /upload/image(multipart),返回 LoadImage 可用的文件名(含 subfolder 前缀)。
    static func uploadImage(host: String, data: Data, filename: String) async throws -> String {
        guard let url = URL(string: host + "/upload/image") else { throw SAM3Error.badHost(host) }
        let boundary = "BBDSAM3" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("overwrite", "true")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200, let root = JValParser.parse(String(decoding: respData, as: UTF8.self)),
              let name = root["name"]?.stringValue else {
            throw SAM3Error.http(code, String(decoding: respData.prefix(300), as: UTF8.self))
        }
        let sub = root["subfolder"]?.stringValue ?? ""
        return sub.isEmpty ? name : sub + "/" + name
    }

    /// POST /prompt 提交 workflow(JValWriter 保序序列化),返回 prompt_id。
    static func submitPrompt(host: String, workflow: JVal) async throws -> String {
        guard let url = URL(string: host + "/prompt") else { throw SAM3Error.badHost(host) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(JValWriter.compact(buildPromptBody(workflow: workflow)).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200, let root = JValParser.parse(String(decoding: data, as: UTF8.self)),
              let pid = root["prompt_id"]?.stringValue else {
            throw SAM3Error.promptRejected("HTTP \(code): " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return pid
    }

    /// 提交 + 轮询 GET /history/{prompt_id} 至完成,取节点 4 bboxes;masks 存在时顺便互验。
    static func detect(host: String, imageName: String, labels: [String],
                       threshold: Double, timeout: Double,
                       log: (String) -> Void = { _ in }) async throws -> [SAM3Detection] {
        let wf = buildWorkflow(imageName: imageName, labels: labels, threshold: threshold)
        let pid = try await submitPrompt(host: host, workflow: wf)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let url = URL(string: host + "/history/" + pid) else { throw SAM3Error.badHost(host) }
            guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = JValParser.parse(String(decoding: data, as: UTF8.self)),
                  root[pid] != nil else { continue }
            if let dets = parseDetections(root, promptID: pid) {
                if let warn = verifyAgainstMasks(root, promptID: pid, detections: dets) { log("[SAM3Grounder] \(warn)") }
                return dets
            }
            if root[pid]?["status"]?["status_str"]?.stringValue == "error" {
                throw SAM3Error.executionError(String(decoding: data.prefix(300), as: UTF8.self))
            }
        }
        throw SAM3Error.timeout(timeout)
    }

    // MARK: - 并发原语

    /// 简单信号量 actor(逐实体通道限流 4)。
    actor AsyncSemaphore {
        private var permits: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(permits: Int) { self.permits = permits }
        func acquire() async {
            if permits > 0 { permits -= 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
        }
    }

    /// 单实体超时隔离:到时抛 SAM3Error.timeout 并取消底层任务。
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw SAM3Error.timeout(seconds)
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    // MARK: - 逐实体重试通道(TaskGroup 并发 + 信号量限流 + 60s 超时 + 同义词回退)

    /// 对漏检/低置信实体逐个重试:threshold 降至 retryThreshold,仍未检出按同义词表替换再试。
    /// 单实体失败/超时不扩散,返回空数组。
    static func detectPerEntity(host: String, imageName: String, labels: [String],
                                log: @escaping (String) -> Void = { _ in }) async -> [String: [SAM3Detection]] {
        let sem = AsyncSemaphore(permits: retryConcurrency)
        return await withTaskGroup(of: (String, [SAM3Detection]).self) { group in
            for label in labels {
                group.addTask {
                    await sem.acquire()
                    var dets: [SAM3Detection] = []
                    if let d = try? await withTimeout(perEntityTimeout, {
                        try await detect(host: host, imageName: imageName, labels: [label],
                                         threshold: retryThreshold, timeout: perEntityTimeout)
                    }) { dets = d }
                    for syn in synonymCandidates(for: label) where dets.isEmpty {
                        log("[SAM3Grounder] 「\(label)」未检出,同义词回退试「\(syn)」")
                        if let d = try? await withTimeout(perEntityTimeout, {
                            try await detect(host: host, imageName: imageName, labels: [syn],
                                             threshold: retryThreshold, timeout: perEntityTimeout)
                        }), !d.isEmpty { dets = d }
                    }
                    await sem.release()
                    return (label, dets)
                }
            }
            var out: [String: [SAM3Detection]] = [:]
            for await (label, dets) in group { out[label] = dets }
            return out
        }
    }

    // MARK: - 主编排(永不抛出:任何失败降级为仅清单结果)

    /// M1 实体清单 → SAM3 定位。优先批量(逗号分隔单次 /prompt,框数==实体数时按位归属);
    /// 漏检/多实例/低置信(score<0.4)实体转逐实体重试通道。
    /// system_stats 不可达或权重缺失 → 返回仅清单无 bbox 的合法 GroundedRecognition,不阻塞管线。
    static func ground(imageData: Data,
                       recognition: OllamaVision.EntityRecognition,
                       host: String = defaultHost,
                       log: @escaping (String) -> Void = { print($0) }) async -> GroundedRecognition {
        let t0 = Date()
        func degrade(_ reason: String) -> GroundedRecognition {
            log("[SAM3Grounder] 降级:\(reason);返回仅清单结果(\(recognition.entities.count) 实体)")
            return GroundedRecognition(recognition: recognition, instances: [], sam3Online: false, note: reason)
        }

        var seen = Set<String>()
        let labels = recognition.entities.map(\.label).filter { seen.insert($0).inserted }
        guard !labels.isEmpty else { return degrade("实体清单为空") }

        // 1) 前置:实例在线 + 权重就位
        guard await systemStatsOK(host: host) else { return degrade("system_stats 不可达(\(host))") }
        guard let ckpts = await listCheckpoints(host: host) else { return degrade("object_info 读取失败") }
        guard ckpts.contains(ckptName) else { return degrade("权重缺失:\(ckptName)") }

        // 2) 原图尺寸(检出为 orig_size 原图像素坐标) + 上传
        guard let (imgW, imgH) = imageSize(imageData) else { return degrade("图片尺寸读取失败") }
        let imageName: String
        do {
            imageName = try await uploadImage(host: host, data: imageData, filename: "bbdesigner_m3_upload.png")
        } catch { return degrade("图片上传失败:\(error)") }

        // 3) 批量优先:所有 label 逗号分隔单次前向;bbox 无 label 归属,
        //    仅当返回框数 == 实体数(每类恰好 1 框)时可按 prompt 顺序按位归属。
        var resolved: [String: [SAM3Detection]] = [:]
        do {
            let tb = Date()
            let batch = try await detect(host: host, imageName: imageName, labels: labels,
                                         threshold: detectThreshold, timeout: batchTimeout, log: log)
            log("[SAM3Grounder] 批量一次前向:\(labels.count) 实体 → \(batch.count) 框,\(String(format: "%.2f", Date().timeIntervalSince(tb)))s")
            if batch.count == labels.count {
                for (i, label) in labels.enumerated() { resolved[label] = [batch[i]] }
            } else {
                log("[SAM3Grounder] 框数≠实体数(存在漏检或多实例),转逐实体通道")
            }
        } catch {
            log("[SAM3Grounder] 批量调用失败:\(error),转逐实体通道")
        }

        // 4) 漏检/低置信实体 → 逐实体重试通道(并发 4、单实体 60s、threshold 0.3、同义词回退)
        let pending = labels.filter { label in
            guard let dets = resolved[label], let best = dets.map(\.score).max() else { return true }
            return best < lowScoreThreshold
        }
        if !pending.isEmpty {
            let retried = await detectPerEntity(host: host, imageName: imageName, labels: pending, log: log)
            for (label, dets) in retried where !dets.isEmpty { resolved[label] = dets }
        }

        // 5) 像素框 → Ideogram 归一化,按实体清单顺序逐实例输出
        var instances: [GroundedInstance] = []
        for label in labels {
            guard let dets = resolved[label] else { continue }
            instances.append(contentsOf: makeInstances(label: label, detections: dets, imageW: imgW, imageH: imgH))
        }
        let note = "\(instances.count) 实例/\(labels.count) 实体,wall \(String(format: "%.2f", Date().timeIntervalSince(t0)))s"
        log("[SAM3Grounder] 完成:\(note)")
        return GroundedRecognition(recognition: recognition, instances: instances, sam3Online: true, note: note)
    }

    /// 供 --selftest 同步上下文调用的阻塞包装(内部 Task.detached,30s 兜底不卡死)。
    static func groundBlocking(imageData: Data,
                               recognition: OllamaVision.EntityRecognition,
                               host: String) -> GroundedRecognition {
        final class Box: @unchecked Sendable { var v: GroundedRecognition? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.v = await ground(imageData: imageData, recognition: recognition, host: host, log: { _ in })
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        return box.v ?? GroundedRecognition(recognition: recognition, instances: [],
                                            sam3Online: false, note: "groundBlocking 等待超时兜底")
    }

    /// 读原图像素尺寸(ImageIO,不解码)。
    static func imageSize(_ data: Data) -> (w: Double, h: Double)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return (w, h)
    }

    // MARK: - CLI 冒烟(--sam3-smoke <图片路径> [逗号分隔 label],默认 "apple,cup,key")

    static func smokeTest(imagePath: String, labels: [String], host: String = defaultHost) async -> Int32 {
        guard let data = FileManager.default.contents(atPath: imagePath) else {
            print("[SAM3Grounder] 读不到图片:\(imagePath)")
            return 1
        }
        let rec = OllamaVision.EntityRecognition(
            styleDescription: "", highLevelDescription: "",
            entities: labels.map { OllamaVision.AnnotateEntity(label: $0, category: .other, desc: $0, colorPalette: []) })
        let r = await ground(imageData: data, recognition: rec, host: host)
        print("[SAM3Grounder] online=\(r.sam3Online) note=\(r.note)")
        for inst in r.instances {
            print("  \(inst.instanceName) bbox=\(inst.bbox) score=\(String(format: "%.3f", inst.score))")
        }
        if !r.sam3Online { print("[SAM3Grounder] 离线降级:仅清单(\(r.recognition.entities.count) 实体),无 bbox") }
        return 0
    }
}
