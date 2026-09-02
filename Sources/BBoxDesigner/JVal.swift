import Foundation

/// 保序 JSON 值:对象键按原文顺序保存,保证"解析 → 修改 → 写回"时不打乱原始 JSON 的字段顺序。
indirect enum JVal: Equatable {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JVal])
    case obj([(String, JVal)])

    static func == (a: JVal, b: JVal) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.num(let x), .num(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.arr(let x), .arr(let y)): return x == y
        case (.obj(let x), .obj(let y)):
            guard x.count == y.count else { return false }
            for i in x.indices { guard x[i].0 == y[i].0 && x[i].1 == y[i].1 else { return false } }
            return true
        default: return false
        }
    }

    // MARK: accessors
    var isObject: Bool { if case .obj = self { return true }; return false }
    var isArray: Bool { if case .arr = self { return true }; return false }

    subscript(key: String) -> JVal? {
        get {
            guard case .obj(let pairs) = self else { return nil }
            return pairs.first(where: { $0.0 == key })?.1
        }
        set {
            guard case .obj(var pairs) = self else { return }
            if let idx = pairs.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { pairs[idx].1 = v } else { pairs.remove(at: idx) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
            self = .obj(pairs)
        }
    }

    var arrayValue: [JVal]? { if case .arr(let a) = self { return a }; return nil }
    var stringValue: String? {
        switch self {
        case .str(let s): return s
        case .num(let n): return JVal.formatNumber(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var doubleValue: Double? {
        if case .num(let n) = self { return n }; return nil
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    // 字段别名容错,等价 JS 的 getFirst
    func first(_ keys: [String]) -> JVal? {
        for k in keys { if let v = self[k] { return v } }
        return nil
    }

    static func formatNumber(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }
}

// MARK: - Parser (recursive descent, preserves key order)
struct JValParser {
    private var s: [Character]
    private var i = 0

    static func parse(_ text: String) -> JVal? {
        var p = JValParser(s: Array(text))
        p.skipWS()
        guard let v = p.parseValue() else { return nil }
        return v
    }

    /// 容错:从混合文本中提取第一个 {...} 块解析
    static func parseLoose(_ text: String) -> JVal? {
        if let v = parse(text) { return v }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start else { return nil }
        return parse(String(text[start...end]))
    }

    private mutating func skipWS() {
        while i < s.count && (s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r") { i += 1 }
    }

    private mutating func parseValue() -> JVal? {
        skipWS()
        guard i < s.count else { return nil }
        switch s[i] {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .str($0) }
        case "t": return match("true") ? .bool(true) : nil
        case "f": return match("false") ? .bool(false) : nil
        case "n": return match("null") ? .null : nil
        default: return parseNumber().map { .num($0) }
        }
    }

    private mutating func match(_ lit: String) -> Bool {
        let cs = Array(lit)
        guard i + cs.count <= s.count else { return false }
        for (k, c) in cs.enumerated() where s[i + k] != c { return false }
        i += cs.count
        return true
    }

    private mutating func parseObject() -> JVal? {
        i += 1 // {
        var pairs: [(String, JVal)] = []
        skipWS()
        if i < s.count && s[i] == "}" { i += 1; return .obj(pairs) }
        while i < s.count {
            skipWS()
            guard let key = parseString() else { return nil }
            skipWS()
            guard i < s.count && s[i] == ":" else { return nil }
            i += 1
            guard let v = parseValue() else { return nil }
            pairs.append((key, v))
            skipWS()
            guard i < s.count else { return nil }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { i += 1; return .obj(pairs) }
            return nil
        }
        return nil
    }

    private mutating func parseArray() -> JVal? {
        i += 1 // [
        var items: [JVal] = []
        skipWS()
        if i < s.count && s[i] == "]" { i += 1; return .arr(items) }
        while i < s.count {
            guard let v = parseValue() else { return nil }
            items.append(v)
            skipWS()
            guard i < s.count else { return nil }
            if s[i] == "," { i += 1; continue }
            if s[i] == "]" { i += 1; return .arr(items) }
            return nil
        }
        return nil
    }

    private mutating func parseString() -> String? {
        guard i < s.count && s[i] == "\"" else { return nil }
        i += 1
        var out = ""
        while i < s.count {
            let c = s[i]
            if c == "\"" { i += 1; return out }
            if c == "\\" {
                i += 1
                guard i < s.count else { return nil }
                let e = s[i]
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard i + 4 < s.count else { return nil }
                    let hex = String(s[i + 1 ... i + 4])
                    guard var code = UInt32(hex, radix: 16) else { return nil }
                    i += 4
                    // 代理对
                    if code >= 0xD800 && code <= 0xDBFF, i + 6 < s.count, s[i + 1] == "\\", s[i + 2] == "u" {
                        let hex2 = String(s[i + 3 ... i + 6])
                        if let lo = UInt32(hex2, radix: 16), lo >= 0xDC00 && lo <= 0xDFFF {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                            i += 6
                        }
                    }
                    if let sc = Unicode.Scalar(code) { out.append(Character(sc)) }
                default: return nil
                }
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }

    private mutating func parseNumber() -> Double? {
        let start = i
        if i < s.count && s[i] == "-" { i += 1 }
        var sawDigit = false
        while i < s.count && (s[i].isNumber || s[i] == "." || s[i] == "e" || s[i] == "E" || s[i] == "+" || s[i] == "-") {
            if s[i].isNumber { sawDigit = true }
            i += 1
        }
        guard sawDigit else { i = start; return nil }
        return Double(String(s[start..<i]))
    }
}

// MARK: - Compact stringify (bbox 等标量数组单行,其余 2 空格缩进,与网页版一致)
enum JValWriter {
    static func escape(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if c < " " { out += String(format: "\\u%04x", c.unicodeScalars.first!.value) }
                else { out.append(c) }
            }
        }
        out += "\""
        return out
    }

    static func compact(_ v: JVal) -> String { walk(v, 0) }

    private static func walk(_ v: JVal, _ d: Int) -> String {
        let pad = String(repeating: "  ", count: d)
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .num(let n): return JVal.formatNumber(n)
        case .str(let s): return escape(s)
        case .arr(let items):
            if items.isEmpty { return "[]" }
            let allScalar = items.allSatisfy {
                if case .num = $0 { return true }
                if case .str = $0 { return true }
                return false
            }
            if allScalar {
                return "[" + items.map { walk($0, 0) }.joined(separator: ",") + "]"
            }
            return "[\n" + items.map { pad + "  " + walk($0, d + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .obj(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { pad + "  " + escape($0.0) + ": " + walk($0.1, d + 1) }.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }
}
