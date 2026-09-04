# BBoxDesigner · 图片自动识别 + 自动 BBox 标注 — 实施 Plan

## 0. 目标

在 BBoxDesigner（SwiftUI 本地 App）新增「图片 → 自动标注」流程：

输入图片 → 自动匹配画布分辨率 → 本地 Ollama 视觉模型识别**全部实体**（人物整体 / 服装整体与部件：裙、裤、连裤袜、上衣… / 五官：眼、睫毛、鼻、嘴、眉 / 头发 / 手、手臂、手指 / 背景室内外细节：树、书桌、床… / 自然元素：花丛、草丛、云、天空… / 整体画风）→ 逐实体调用本地 **SAM3** 文本 grounding 批量出 bbox → 汇总为 Ideogram 4 格式 caption JSON（bbox 轴序 `[ymin,xmin,ymax,xmax] @ 0–1000`）→ 一键导入画布 / 复制。

**已核实环境（2026-09-03）：**
- Ollama：`qwen3.8:27b-mlx`（默认视觉模型）、`gemma4:e4b-mlx`（备选，更快）— 模型下拉可选。
- SAM3：存在于 `~/ComfyUI-Installs/ComfyUI/ComfyUI/comfy/ldm/sam3` + 官方蓝图 `Image Segmentation (SAM3).json`（文本提示 → mask/bbox）。走 ComfyUI HTTP API（默认 `http://127.0.0.1:8188`）调用，无需另装 MLX 移植版；预留 MLX-SAM 接口位。
- BBoxDesigner 工程：`/Users/jup33q/Documents/kimi/tasks/2026-09-02/09-56-42-fc8077ae/BBoxDesigner`，已有 `EditorState.parse`（Ideogram JSON 解析）与 MCP 子进程经验（FluxKleinStudio）。

## 1. 架构决策：不用 LangChain/LangGraph

LangGraph 的价值在多轮 agent 状态机；本任务是**固定两段流水线**（识别 → 定位），Swift 原生 `async/await + TaskGroup` 足够，零新依赖、零 Python 侧车进程，与现有 App 同语言同包。能程序化的全部程序化，模型只做两件事：① 实体清单 + 描述；② SAM3 拿文本提示出框。

```
┌─ SwiftUI 新面板「AI 自动标注」────────────────────────────┐
│ 1. 输入图 → AutoResolution：按图宽高比匹配 7 档预设，       │
│    边缘对齐 64，自动设置画布 W×H                           │
│ 2. 图(base64) → Ollama /api/chat  (qwen3.8:27b-mlx 默认)   │
│    单次调用，JSON schema 强约束输出：                       │
│    { style_description, entities: [ {label, category,      │
│       color_palette[], detail} ] }                         │
│ 3. 并发定位：TaskGroup(限流 4) 每个实体 label → SAM3       │
│    (ComfyUI /prompt: SAM3 文本条件检测 → mask → bbox)      │
│ 4. 程序化后处理：去重(NMS/IoU>0.85)、面积过滤(<0.1%丢弃)、  │
│    嵌套保留(睫毛⊂眼 均保留)、归一化 → 0–1000 Ideogram 轴序 │
│ 5. 组装 caption JSON → EditorState.parse 直接进画布，      │
│    全程可人工微调（已有拖拽/手柄/写回闭环）                  │
└───────────────────────────────────────────────────────────┘
```

## 2. 实施步骤（按依赖排序）

### Step 1 — Ollama 视觉识别模块 `Sources/AIAnnotate/OllamaVision.swift`
- HTTP 客户端 `POST {host}/api/chat`，`format: json`（Ollama 原生 JSON 约束），`stream: false`。
- 模型选择器：默认 `qwen3.8:27b-mlx`，备选 `gemma4:e4b-mlx`；读 `ollama list` 自动填充。
- 系统提示词 = 实体清单专用提示（见 §4 激活提示词 A），要求覆盖 7 类：人物整体 / 服装（整体+逐部件）/ 五官（眼、睫毛、眉、鼻、嘴、耳）/ 头发 / 手部（手、手臂、手指）/ 场景道具与背景（室内外：树、书桌、床、家具、建筑）/ 自然元素（花丛、草丛、云、天空、水）；外加 `style_description`（整体画风一句话）与每实体 `color_palette`。
- 图片预处理：最长边缩到 1568（Qwen-VL 甜点），JPEG q85 base64。
- 输出强校验：JSONDecode 失败 → 重试 1 次（temperature 0.1）。

### Step 2 — SAM3 定位模块 `Sources/AIAnnotate/SAM3Grounder.swift`
- 优先路线：ComfyUI API。
  - `GET /system_stats` 探活；未运行则提示一键启动 `ComfyUI`（可复用现有子进程模式）。
  - 构造 SAM3 蓝图 workflow（LoadImage → SAM3 文本条件分割 → mask → bbox 提取），`POST /prompt`，轮询 `/history/{id}`，取 mask 求外接矩形。
  - 蓝图 JSON 内嵌 App bundle（`Resources/sam3_detect.json`），实体 label 作为文本条件注入。
- 并发：Swift `TaskGroup` + 信号量限流 4（SAM3 显存友好）。
- 兜底路线：若 ComfyUI 不可用 → 面板显示「SAM3 离线」，仅输出实体清单 JSON（无 bbox），不阻塞主流程。
- 同类多实例（如两只手）：SAM3 返回多 mask → 每个 mask 一个元素，`label` 加序号（hand_1 / hand_2）。

### Step 3 — 分辨率自适应 `AutoResolution.swift`
- 读图宽高比 → 匹配最近预设（1024²/1344×768/1408×704/768×1024/768×1152/896×1152/960×1280）→ 锁定比例 → 画布自动设为该尺寸。
- bbox 坐标换算：SAM3 像素坐标 → `min/max` 归一化到原图 → ×1000 取整 → Ideogram 轴序 `[ymin,xmin,ymax,xmax]`。

### Step 4 — 后处理与 JSON 组装 `AnnotatePipeline.swift`
- 纯程序化：NMS 去重（IoU>0.85 保大框）、极小框过滤、嵌套框保留（睫毛/眼这类层级是有意保留的）、CLIP 级排序（按面积降序，人物整体在前）。
- 组装为现有 `EditorState.parse` 兼容的 caption JSON：`high_level_description`（Ollama 总结或首实体）+ `style_description` + `compositional_deconstruction.elements[]`（desc + bbox + color_palette）。
- 结果直接走现有解析闭环进画布；「更新提示词」、差异确认、写回全部免费复用。

### Step 5 — UI 面板
- 左侧工具栏新增「✨ AI 自动标注」：图片拖入/粘贴（复用参考图通道）、模型下拉、进度列表（每个实体 ✅/⏳/❌ 实时状态）、「导入画布」「复制 JSON」按钮。
- 每个实体可单独重跑 SAM3（改 label 措辞后点 ⟳）。
- **导入图片「底面背景」开关**：标注用输入图默认自动设为画布底面背景（透明度可调，30%/60%/100%），bbox 直接叠在图上对照微调；一键隐藏/恢复（快捷键 ⌥B），隐藏时显示纯网格画布。状态持久化到 configs.json。复用现有「参考图」渲染层，加 visible/opacity 两个状态位即可。

### Step 6 — 自测
- `--selftest` 增加：轴序换算断言（已知像素框 → 0–1000）、NMS 断言、Ollama JSON 容错解析断言、SAM3 离线降级断言。
- 冒烟：一张 flux-klein 生成图跑全流程，对比人工标注 IoU。

## 3. 并发与程序化清单

| 环节 | 方式 |
|---|---|
| 实体识别 | 单次 Ollama 调用（不逐实体问，省 10× 时间） |
| SAM3 定位 | **批量优先**：逗号分隔多标签单次调用（SAM3 原生支持 `"person,shoe,car"` 多类别一次前向，逐实例返回 masks/boxes/scores）；仅对低置信度/漏检实体单独重试，重试时 TaskGroup 并发限流 4、单实体超时 60s 隔离 |
| 去重/过滤/归一化/排序/JSON 组装 | 纯程序化，无模型参与 |
| 分辨率匹配/轴序换算 | 纯程序化 |
| 失败重试 | Ollama JSON 解析失败重试 1 次；SAM3 单实体失败不影响其余 |

## 3.1 SAM3 实例化与 Ideogram 4 适配（已核实，2026-09-03）

- **SAM3 逐实例输出**：同一概念多个体（如两只手）返回独立 mask/box + score，JSON 中生成独立 element（`hand_1`/`hand_2`）。SAM3 即 Promptable Concept Segmentation，一次前向穷尽所有匹配实例，无需 GroundingDINO 级联。
- **Ideogram 4 JSON 无实例 ID 语义**，但 elements 数组天然支持同类别多实例（两猫 = 两个 `type:"obj"` 元素各自 bbox/desc）。
- **「生成视图」折叠开关（重要）**：官方经验是一个主体一个框、3–6 个不重叠强元素远好于 20 个重叠框（重叠污染文字与内容）。因此：
  - 画布保留**全量标注**（睫毛/手指/服装部件级，供编辑）；
  - 「复制为提示词 / 生成」时程序化折叠为**生成视图**：默认将 五官+头发+服装部件+四肢 合并进所属人物整体的 bbox 与 desc，背景小件并入 background 字段，输出 3–6 个不重叠主元素；
  - 折叠规则纯程序化（category 字段驱动：face_feature/hair/hand_arm/garment_part → 并入父级 person；嵌套 bbox 并入外层）。
- **image edit 路线**：Ideogram 4 是文生图模型，无原生指令编辑；局部修改走 inpainting（ComfyUI mask 工作流，bbox 直接当修复区域）或本地 flux-klein `edit_image`。

## 4. 激活提示词

### A. Ollama 视觉实体识别系统提示（喂给 qwen3.8:27b-mlx）

```
你是图像实体清点专家。仔细审视这张图片，输出严格 JSON（不要输出任何其他文字）：
{
  "style_description": "<整体画风一句话，如 anime illustration, soft watercolor, cinematic photo>",
  "high_level_description": "<全图一句话概括>",
  "entities": [
    {"label": "<2-5词的简短英文名词短语，用于检测模型文本提示>", "category": "<person|garment|garment_part|face_feature|hair|hand_arm|furniture|nature|other>", "desc": "<中文详细描述，含颜色/材质/姿态>", "color_palette": ["#rrggbb"]}
  ]
}
必须穷尽以下层次（存在才输出，宁多勿漏）：
1. 人物整体（person: girl, boy, woman…）
2. 服装整体与每个部件：连衣裙、上衣、裙子、裤子、连裤袜、袜子、鞋、帽子、发饰、领结…逐件列出
3. 五官逐个：左眼、右眼、睫毛、眉毛、鼻子、嘴、耳朵
4. 头发（整体发型；有明显分区如双马尾则分区列出）
5. 手与手臂：每只手、每条手臂、可见手指
6. 场景与道具：室内（书桌、床、椅、窗、灯、书架…）/ 室外（树、建筑、道路…）逐件列出
7. 自然元素：花丛、草丛、云、天空、太阳、水面…
label 必须具体（用 "white pleated skirt" 而非 "skirt"），每个实体描述含主色 hex。
```

### B. 给开发 Agent 的激活提示词（粘贴即用）

```
打开 /Users/jup33q/Documents/kimi/tasks/2026-09-02/09-56-42-fc8077ae/BBoxDesigner，按 PLAN-image-auto-bbox.md 实施「AI 自动标注」功能：
1) 新增 Sources/AIAnnotate/{OllamaVision,SAM3Grounder,AutoResolution,AnnotatePipeline}.swift；
2) Ollama 走 http://127.0.0.1:11434/api/chat，默认模型 qwen3.8:27b-mlx（下拉可选 gemma4:e4b-mlx），JSON 强约束输出实体清单（提示词见 Plan §4-A）；
3) SAM3 走 ComfyUI http://127.0.0.1:8188 API（蓝图 Resources/sam3_detect.json），优先逗号分隔多标签单次调用（SAM3 原生多类别逐实例输出），低置信/漏检实体单独重试时 TaskGroup 并发限流 4，ComfyUI 不在线时优雅降级为「仅清单无 bbox」；
4) bbox 像素坐标 → 归一化 → Ideogram 轴序 [ymin,xmin,ymax,xmax] @0–1000，NMS(IoU>0.85) 去重，组装成 EditorState.parse 兼容的 caption JSON 直接进画布；
5) 左侧新增「✨ AI 自动标注」面板：拖图、模型选择、逐实体进度、导入画布/复制 JSON；导入图片自动设为画布底面背景（透明度 30/60/100% 可调，⌥B 一键隐藏/恢复，状态持久化 configs.json）；
6) 实现「生成视图」折叠：复制为提示词/生成时按 category 把 face_feature/hair/hand_arm/garment_part 并入父级 person，背景小件并入 background，输出 3–6 个不重叠主元素；画布始终保留全量标注；
7) 扩展 --selftest（轴序换算、NMS、折叠规则、降级路径），scripts/make_app.sh 打包验证。
约束：不引入 Python/LangChain，全部 Swift 原生 async/await；遵守工程现有 JVal 保序 JSON 与写回闭环。
```

## 5. 风险与备选

- **SAM3 需 ComfyUI 运行**：首次在面板提供「启动 ComfyUI」按钮（子进程，复用 FluxKleinStudio 模式）；未来可换 mlx-community SAM 移植版去掉 ComfyUI 依赖。
- **27B MLX 模型冷启动慢**：面板显示加载状态；提供 gemma4:e4b-mlx（9.5GB）作为快速档。
- **实体措辞影响 SAM3 命中**：label 允许手动编辑后单实体重跑；内置同义词重试（如 "tights" ↔ "pantyhose"）。
- **qwen3.8 是否为视觉模型未 100% 确认**：Step 1 先跑一张图冒烟，若无视觉能力则默认切 gemma4:e4b-mlx 并在文档记录。
