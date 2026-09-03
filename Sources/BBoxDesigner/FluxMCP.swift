import Foundation
import AppKit

/// 极简 stdio MCP 客户端:按行读写 JSON-RPC 2.0(与 FluxKleinStudio `mcp` 子进程通信)。
final class FluxMCPClient {
    enum MCPError: Error, LocalizedError {
        case binaryMissing(String)
        case serverError(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .binaryMissing(let p): return "未找到 FluxKleinStudio: \(p)"
            case .serverError(let m): return m
            case .timeout: return "请求超时"
            }
        }
    }

    static func defaultBinaryPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Desktop/FluxKleinStudio.app/Contents/MacOS/FluxKleinStudio",
            "\(home)/Documents/kimi/workspace/flux-klein-studio/FluxKleinStudio.app/Contents/MacOS/FluxKleinStudio",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return candidates[0]
    }

    private var process: Process?
    private var stdinFH: FileHandle?
    private var stdoutFH: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()

    var isRunning: Bool { process?.isRunning ?? false }

    func start(binaryPath: String = FluxMCPClient.defaultBinaryPath()) throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw MCPError.binaryMissing(binaryPath)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["mcp"]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc
        self.stdinFH = inPipe.fileHandleForWriting
        self.stdoutFH = outPipe.fileHandleForReading
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            if data.isEmpty {
                self.failAll(MCPError.serverError("MCP 进程已退出"))
                fh.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
            self.drainLines()
        }
    }

    func stop() {
        stdoutFH?.readabilityHandler = nil
        process?.terminate()
        process = nil
        failAll(MCPError.serverError("已停止"))
    }

    private func drainLines() {
        lock.lock()
        defer { lock.unlock() }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let cont = pending.removeValue(forKey: id) else { continue }
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: MCPError.serverError(err["message"] as? String ?? "未知错误"))
            } else if let result = obj["result"] as? [String: Any] {
                cont.resume(returning: result)
            } else {
                cont.resume(returning: [:])
            }
        }
    }

    private func failAll(_ err: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, c) in all { c.resume(throwing: err) }
    }

    @discardableResult
    func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        if !isRunning { try start() }
        lock.lock()
        let id = nextID; nextID += 1
        lock.unlock()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: msg)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            stdinFH?.write(data)
            stdinFH?.write(Data([0x0A]))
        }
    }

    func notifyInitialized() {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            stdinFH?.write(data)
            stdinFH?.write(Data([0x0A]))
        }
    }

    func initialize() async throws {
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "BBoxDesigner", "version": "1.0.0"],
        ])
        notifyInitialized()
    }

    /// 文生图:返回保存的 PNG 路径
    func generateImage(prompt: String, width: Int, height: Int, steps: Int, guidance: Double, seed: Int, quantize: Int, outputPath: String?) async throws -> String {
        var args: [String: Any] = [
            "prompt": prompt, "width": width, "height": height,
            "steps": steps, "guidance": guidance, "seed": seed, "quantize": quantize,
        ]
        if let outputPath { args["output_path"] = outputPath }
        let result = try await request(method: "tools/call", params: [
            "name": "generate_image", "arguments": args,
        ])
        // MCP 文本内容里找路径
        if let content = result["content"] as? [[String: Any]] {
            for c in content where (c["type"] as? String) == "text" {
                if let text = c["text"] as? String {
                    if let p = Self.extractPath(from: text) { return p }
                }
            }
        }
        if let p = outputPath, FileManager.default.fileExists(atPath: p) { return p }
        return outputPath ?? ""
    }

    static func extractPath(from text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(/[^\s"'`]+\.png)"#, options: .caseInsensitive) else { return nil }
        let ms = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in ms {
            let p = String(text[Range(m.range, in: text)!])
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - 生成面板状态

@MainActor
final class FluxGenState: ObservableObject {
    enum Status: Equatable { case idle, generating, done, failed(String) }
    @Published var status: Status = .idle
    @Published var prompt = ""
    @Published var steps = 4
    @Published var guidance = 1.0
    @Published var seed = -1
    @Published var quantize = 8
    @Published var resultPath: String? = nil
    @Published var resultImage: NSImage? = nil
    @Published var setAsReference = true

    private let client = FluxMCPClient()

    var mcpAvailable: Bool {
        FileManager.default.fileExists(atPath: FluxMCPClient.defaultBinaryPath())
    }

    var outputsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BBoxDesigner/outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 从 caption JSON 拍平成英文提示词
    func flattenPrompt(from state: EditorState) {
        var parts: [String] = []
        let hl = state.highLevel.trimmingCharacters(in: .whitespaces)
        if !hl.isEmpty { parts.append(hl) }
        var styleBits: [String] = []
        if !state.aesthetics.trimmingCharacters(in: .whitespaces).isEmpty { styleBits.append(state.aesthetics.trimmingCharacters(in: .whitespaces)) }
        if !state.lighting.trimmingCharacters(in: .whitespaces).isEmpty { styleBits.append(state.lighting.trimmingCharacters(in: .whitespaces) + " lighting") }
        if !state.medium.trimmingCharacters(in: .whitespaces).isEmpty { styleBits.append(state.medium.trimmingCharacters(in: .whitespaces)) }
        if state.styleType == .photo { styleBits.append("photorealistic photo") }
        if state.styleType == .artStyle { styleBits.append("stylized illustration") }
        let palette = state.paletteText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !palette.isEmpty { styleBits.append("color palette " + palette.joined(separator: ", ")) }
        if !styleBits.isEmpty { parts.append("Style: " + styleBits.joined(separator: "; ")) }
        let bg = state.bgDesc.trimmingCharacters(in: .whitespaces)
        if !bg.isEmpty { parts.append("Background: " + bg) }
        // 拍平提示词只用 desc;annotation 是画布注释,不进提示词
        for (i, b) in state.boxes.enumerated() where !b.desc.trimmingCharacters(in: .whitespaces).isEmpty {
            let bb = state.normToIdeogram(b)
            parts.append("Element \(i + 1) at region [\(bb.map(String.init).joined(separator: ","))]: \(b.desc.trimmingCharacters(in: .whitespaces))")
        }
        prompt = parts.joined(separator: ". ")
    }

    func generate(canvasW: Double, canvasH: Double, editor: EditorState) async {
        status = .generating
        do {
            try await client.initialize()
            // 画布尺寸对齐到 16 的倍数(256–2048)
            let w = max(256, min(2048, Int(canvasW / 16) * 16))
            let h = max(256, min(2048, Int(canvasH / 16) * 16))
            let out = outputsDir.appendingPathComponent("gen-\(Int(Date().timeIntervalSince1970)).png").path
            let path = try await client.generateImage(
                prompt: prompt, width: w, height: h,
                steps: steps, guidance: guidance, seed: seed, quantize: quantize,
                outputPath: out)
            let finalPath = path.isEmpty ? out : path
            resultPath = finalPath
            resultImage = NSImage(contentsOfFile: finalPath)
            if setAsReference, let img = resultImage {
                editor.bgImage = img
            }
            status = .done
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func revealInFinder() {
        if let p = resultPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
    }
}
