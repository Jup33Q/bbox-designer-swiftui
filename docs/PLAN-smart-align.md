# PLAN: 智能对齐吸附(Smart Guides)+ 触摸板触觉反馈

> 目标:画布拖动/缩放 bbox 时,像 Keynote/PPT 一样出现对齐参考线并吸附;
> 吸附发生的瞬间给触摸板触觉反馈(NSHapticFeedbackManager `.alignment`)。

## 1. 需求定义

### 吸附源(候选对齐线)
- 画布:左/右/上/下边缘、水平/垂直中线
- 其他可见物体(非 hidden、非 locked、不在当前拖动集合内):各自的左/中X/右、上/中Y/下

### 触发场景
- **移动**(单个或多选整体):对拖动集合的包围盒做 6 条边线(左/中X/右/上/中Y/下)与候选线的匹配
- **缩放**(8 手柄):只对正在拖动的边做匹配(n/s 配水平线,e/w 配垂直线)

### 吸附行为
- 阈值:画布坐标 6px(约等于屏幕 4-5pt,随缩放换算可后续调)
- 命中时:把拖动整体沿对应轴平移 delta(移动);或把被拖边直接夹到候选线(缩放)
- 多轴独立:X、Y 可同时各自吸附
- 参考线显示:吸附命中期间画 1px 高亮线(贯穿画布,#FACC15 黄,与现有拖动辅助线区分:智能对齐用实线、整体拖动辅助用虚线)
- **触觉反馈**:`NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)`
  - 仅在"吸附状态变化"时触发:从无到有(吸附上)、从某线换到另一线、从有到无(脱开)三档都可触发,初版只做"吸附上"与"脱开"
  - 需要窗口处于 key 状态且有 Force Touch 触摸板;无触摸板时静默跳过(API 本身安全)
- 开关:工具条「智能对齐」toggle(默认开),与现有「网格吸附」独立;两者同时开时**先算智能对齐,未命中再落网格**
- 按住 ⌘ 拖动时临时禁用吸附(Keynote 惯例)

## 2. 技术方案

### 2.1 纯函数核心(可单测)
`EditorState` 新增(或独立文件 `SmartGuides.swift`):

```swift
struct SnapLine: Equatable { enum Axis { case h, v }; var axis: Axis; var pos: Double }  // 画布坐标
struct SnapResult { var deltaX: Double; var deltaY: Double; var lines: [SnapLine] }       // lines 用于绘制

func computeSnap(moving rect: CGRect,          // 拖动集合包围盒(未吸附前)
                 candidates: [SnapLine],       // 所有候选线
                 threshold: Double) -> SnapResult
```

- 移动:`rect` = 拖动集合包围盒,生成 6 条边线,与 candidates 同轴匹配,取 |delta| 最小者
- 缩放:`rect` 只传被拖边的当前位置(单线),逻辑复用

### 2.2 状态接线
- `EditorState` 新增:
  - `@Published var smartSnapEnabled = true`(进 Snapshot,参与撤销/重做与配置持久化)
  - `@Published var activeGuides: [SnapLine] = []`(瞬态,不进历史)
  - `hapticsEnabled`(默认 true,暂不进 UI,预留)
- `moveDragged(to:)` 改写:
  1. 按原逻辑算出整体平移后的目标位置 delta
  2. 若 smartSnapEnabled 且未按 ⌘:用"平移后的包围盒"跑 computeSnap,叠加 delta
  3. 未命中智能对齐且 snapToGrid 开启 → 维持原网格吸附
  4. 比较新旧 activeGuides,变化时触发触觉 + 更新 @Published
- `resizeDragged(id:handle:to:)` 同理,只匹配被拖边
- `endDrag` / `marqueeBegan` 等手势结束时清空 activeGuides

### 2.3 绘制
`CanvasAreaView.canvasContent`:
- `ForEach(state.activeGuides)`:垂直线 `Rectangle().frame(width:1)` 全高,水平线同理;颜色 `Theme.yellow`,允许 hitTesting = false
- 位置:`pos * scale`

### 2.4 触觉反馈封装
```swift
enum Haptics {
    static var lastFiredAt: TimeInterval = 0
    static func alignment() {
        // 60ms 节流,防止 delta 抖动时连发
        guard ProcessInfo.processInfo.systemUptime - lastFiredAt > 0.06 else { return }
        lastFiredAt = ProcessInfo.processInfo.systemUptime
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}
```
触发点:`activeGuides` 从空→非空(吸附上)、从非空→空(脱开)。换线不触发(避免连震)。

### 2.5 UI
- 工具条「对象」组加 GhostButton「智能对齐」active 绑定 smartSnapEnabled,点击 toggle + recordHistory
- 画布 hint 文案可后续补一句;暂不改

## 3. 文件改动清单

| 文件 | 改动 |
|---|---|
| `Sources/BBoxDesigner/SmartGuides.swift` | 新增:SnapLine/SnapResult/computeSnap/Haptics |
| `Sources/BBoxDesigner/EditorState.swift` | smartSnapEnabled、activeGuides;moveDragged/resizeDragged/endDrag 接线;Snapshot 增字段 |
| `Sources/BBoxDesigner/CanvasView.swift` | 参考线绘制;⌘ 修饰键透传(NSEvent.modifierFlags 已有先例) |
| `Sources/BBoxDesigner/Panels.swift` 或 ContentView | 工具条按钮 |
| `Sources/BBoxDesigner/SelfTest.swift` | 新增 computeSnap 单测(见 §4) |
| `README.md` / `SKILL.md` | 功能清单补一行 |

## 4. 测试

### SelfTest 新增断言(纯函数,无 UI)
1. 左边线吸附:moving 左边缘 x=102,候选线 x=100,阈值 6 → deltaX=-2,lines 含 v@100
2. 中线吸附:包围盒中X 命中画布中线(如 IMG_W/2)
3. 双轴同时吸附:X 命中物体边缘 + Y 命中画布中线
4. 超阈值不吸附:距离 7px → 无 lines、无 delta
5. 多候选取最近:两条候选 101 和 104,当前 102 → 选 101
6. 缩放边吸附:拖 e 边到 898,候选 900 → 夹到 900
7. smartSnapEnabled=false 时 computeSnap 不被调用(走原逻辑,行为回归不变)

### 手动验证清单
- [ ] 拖一个框靠近另一个框边缘:出现黄线 + 吸附 + 触摸板"哒"一下
- [ ] 拖过中线:中线吸附
- [ ] 按住 ⌘ 拖动:无吸附无参考线
- [ ] 吸附开启 + 网格吸附开启:靠近物体时优先智能对齐,空白处仍落网格
- [ ] 多选整体移动:包围盒吸附
- [ ] 缩放手柄:被拖边吸附
- [ ] 撤销/重做后 smartSnapEnabled 状态正确恢复

## 5. 风险与注意

- **性能**:候选线数量 = 物体数×6+6,50 个物体也才 300 条,每帧 O(n) 匹配无压力
- **手势冲突**:不改手势结构,只在 move/resize 的数值管线里插一层,风险低
- **触觉反馈兼容性**:无 Force Touch 触摸板的机器 perform 为空操作,不崩
- **多选缩放不存在**(手柄只在单选显示),缩放吸附只需处理单框
- 触觉在 ⌘ 禁用时不触发

## 6. 实施顺序

1. SmartGuides.swift 纯函数 + SelfTest 断言(先让 7 条断言过)
2. EditorState 接线(移动)
3. 参考线绘制 + 工具条开关 → 视觉验证
4. 缩放吸附
5. 触觉反馈 + 节流 → 真机触摸板验证
6. make_app.sh 打包同步桌面,commit + push
