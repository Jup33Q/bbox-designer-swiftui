import Foundation

/// M2 · 自动分辨率建议与 SAM3 ↔ Ideogram 坐标换算(纯函数,不写 UI,M5 才接面板)。
/// - 画布预设与 EditorState.presetSizes 同序;
/// - 归一化约定与 EditorState.normToIdeogram / parse 完全一致:
///   正向 v/size*1000 四舍五入夹到 0...1000,轴序 [ymin,xmin,ymax,xmax];
///   反向 c/1000*size。
enum AutoResolution {

    /// 建议画布预设(1024² / 1344×768 / 1408×704 / 768×1024 / 768×1152 / 896×1152 / 960×1280)。
    static let presets: [(w: Double, h: Double)] = [
        (1024, 1024), (1344, 768), (1408, 704), (768, 1024), (768, 1152), (896, 1152), (960, 1280)
    ]

    // MARK: - 宽高比 → 画布预设

    /// 读输入图宽高比,匹配最近的画布预设。
    /// 主键:log 宽高比距离;同比例并列(3:4 有 768×1024 / 960×1280 两个)时取尺度更接近者,
    /// 因此与某预设完全相同的输入会命中它自己。非法尺寸回退第一个预设(1024²)。
    static func suggestCanvas(imageW: Double, imageH: Double) -> (w: Double, h: Double) {
        guard imageW > 0, imageH > 0, imageW.isFinite, imageH.isFinite else { return presets[0] }
        let target = log(imageW / imageH)
        var best = presets[0]
        var bestKey = (Double.infinity, Double.infinity)
        for p in presets {
            let key = (abs(log(p.w / p.h) - target), abs(log(imageW / p.w)))
            if key < bestKey { bestKey = key; best = p }
        }
        return best
    }

    // MARK: - SAM3 像素 bbox → Ideogram [ymin,xmin,ymax,xmax] @0–1000

    /// SAM3 像素 bbox(x/y/width/height,见 M0 报告 §2 输出格式)→ min/max 归一化到原图
    /// → ×1000 取整 → Ideogram 轴序 [ymin,xmin,ymax,xmax]。越界值夹到 0...1000。
    static func pixelsToIdeogram(x: Double, y: Double, w: Double, h: Double,
                                 imageW: Double, imageH: Double) -> [Int] {
        [norm1000(y, imageH), norm1000(x, imageW), norm1000(y + h, imageH), norm1000(x + w, imageW)]
    }

    private static func norm1000(_ v: Double, _ size: Double) -> Int {
        guard size > 0, v.isFinite else { return 0 }
        return Int(max(0, min(1000, (v / size * 1000).rounded())))
    }

    // MARK: - 反向:Ideogram @0–1000 → 像素

    /// [ymin,xmin,ymax,xmax] @0–1000 → 像素 (x, y, w, h),与 EditorState.parse 反归一化同式。
    static func ideogramToPixels(_ bbox: [Double], imageW: Double, imageH: Double)
        -> (x: Double, y: Double, w: Double, h: Double) {
        guard bbox.count >= 4 else { return (0, 0, 0, 0) }
        let y1 = bbox[0] / 1000 * imageH, x1 = bbox[1] / 1000 * imageW
        let y2 = bbox[2] / 1000 * imageH, x2 = bbox[3] / 1000 * imageW
        return (x1, y1, x2 - x1, y2 - y1)
    }
}
