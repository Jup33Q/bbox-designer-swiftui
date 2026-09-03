# AI 自动标注 · 分阶段激活提示词（M0–M6）

> 每个里程碑一条自包含激活提示词，按顺序逐段喂给开发 Agent；上一阶段验收通过再进下一阶段。
> 完整设计见同目录 `PLAN-image-auto-bbox.md`（或工作区原始 Plan）。
> 工程根目录：`/Users/jup33q/Documents/kimi/tasks/2026-09-02/09-56-42-fc8077ae/BBoxDesigner`

---

## M0 · 环境冒烟（不写产品代码）

**目标**：验证两个外部依赖的真实能力，定下默认模型。

```
在 BBoxDesigner 工程外先做两个冒烟测试，把结果写成报告：
1) Ollama 视觉能力：curl http://127.0.0.1:11434/api/chat，分别用 qwen3.8:27b-mlx 和 gemma4:e4b-mlx 发送同一张测试图（base64）+ 一句"列出图中的物体"，确认哪个能正确描述图像内容、响应耗时多少；定下默认视觉模型（优先 qwen3.8:27b-mlx，若无视觉能力则 gemma4:e4b-mlx）。
2) SAM3 可用性：检查 ~/ComfyUI-Installs/ComfyUI/ComfyUI 的 SAM3 节点与模型权重是否齐全；如本机有运行中的 ComfyUI（http://127.0.0.1:8188/system_stats），用其 SAM3 蓝图对测试图跑一次文本提示 "person"，确认能返回 mask/bbox。
输出：docs/ai-annotate-m0-report.md，含默认模型决定、SAM3 调用方式（workflow JSON 结构）、耗时基准。
约束：不改 App 源码。
```

**验收**：报告落地，默认模型明确，SAM3  workflow 跑通或有明确降级结论。

---

## M1 · Ollama 实体识别模块

```
在 BBoxDesigner 工程实施 M1：
1) 新增 Sources/AIAnnotate/OllamaVision.swift：HTTP 客户端 POST {host}/api/chat（host 默认 http://127.0.0.1:11434），format:json、stream:false、temperature 0.1；图片预处理为最长边 1568、JPEG q85 base64。
2) 模型选择器：默认取 M0 报告定下的模型；启动时读 `ollama list` 自动填充下拉。
3) 实体识别系统提示词固定为 Plan §4-A（穷尽 7 层：人物整体/服装逐部件/五官逐个/头发/手手臂手指/室内外道具/自然元素 + style_description + color_palette）。
4) 输出强校验：JSONDecode 失败重试 1 次。
5) --selftest 增加：Ollama 响应 JSON 容错解析断言（合法/缺字段/带多余文本三种样例）。
验收：swift build 通过 + --selftest 全绿；用 M0 测试图实跑一次打印实体清单。
```

---

## M2 · 分辨率自适应与坐标换算

```
在 BBoxDesigner 工程实施 M2：
1) 新增 Sources/AIAnnotate/AutoResolution.swift：读输入图宽高比 → 匹配最近画布预设（1024²/1344×768/1408×704/768×1024/768×1152/896×1152/960×1280）→ 自动设置画布 W×H 并锁定比例。
2) 坐标换算纯函数：SAM3 像素 bbox → min/max 归一化到原图 → ×1000 取整 → Ideogram 轴序 [ymin,xmin,ymax,xmax] @0–1000；含反向换算。
3) --selftest 增加：已知像素框的正反换算断言（含非方形图、边界 0 与 1000）。
验收：--selftest 全绿；换算函数往返误差 ≤1/1000。
```

---

## M3 · SAM3 批量定位模块

```
在 BBoxDesigner 工程实施 M3（依赖 M0 的 workflow 结论与 M1 的实体清单）：
1) 新增 Sources/AIAnnotate/SAM3Grounder.swift + Resources/sam3_detect.json（ComfyUI API 格式 workflow，文本条件可注入）。
2) 调用策略：优先批量——所有实体 label 逗号分隔单次 /prompt 提交（SAM3 原生多类别一次前向、逐实例返回 masks/boxes/scores）；轮询 /history/{id} 取结果，mask 求外接矩形。
3) 低置信度（<0.4）或缺失实体单独重试：Swift TaskGroup 并发、信号量限流 4、单实体超时 60s 隔离；内置同义词回退（tights↔pantyhose 等）。
4) 同概念多实例：每实例一个结果（hand_1/hand_2）。
5) 优雅降级：GET /system_stats 失败 → 返回「仅清单无 bbox」结果，不阻塞管线；面板提供「启动 ComfyUI」按钮（子进程模式复用 FluxKleinStudio 的 MCP 启动经验）。
6) --selftest 增加：降级路径断言（mock 离线 → 输出无 bbox 的合法结果）。
验收：--selftest 全绿；ComfyUI 在线时测试图实体检出率 ≥80%，离线时降级正确。
```

---

## M4 · 后处理管线与生成视图折叠

```
在 BBoxDesigner 工程实施 M4：
1) 新增 Sources/AIAnnotate/AnnotatePipeline.swift，全部程序化无模型参与：
   - NMS 去重（同类 IoU>0.85 保大框）；
   - 极小框过滤（面积 <0.1% 画布）；
   - 嵌套框保留（睫毛⊂眼这类层级是有意的）；
   - 排序：人物整体在前，其后按面积降序。
2) 组装 EditorState.parse 兼容的 caption JSON：high_level_description + style_description + compositional_deconstruction.elements[]（desc + bbox + color_palette），结果直接进画布。
3) 「生成视图」折叠（Plan §3.1）：导出/复制为提示词时按 category 把 face_feature/hair/hand_arm/garment_part 并入父级 person 的 bbox 与 desc，背景小件并入 background 字段，输出 3–6 个不重叠主元素；画布始终保留全量标注。
4) --selftest 增加：NMS 断言、折叠规则断言（全量→生成视图的元素数与 bbox 并集正确性）。
验收：--selftest 全绿；一张测试图端到端（M1→M3→M4）产出合法 caption JSON 并正确进画布。
```

---

## M5 · UI 面板与底面背景

```
在 BBoxDesigner 工程实施 M5：
1) 左侧工具栏新增「✨ AI 自动标注」面板：图片拖入/粘贴（复用参考图通道）、模型下拉、逐实体进度列表（✅/⏳/❌ 实时刷新）、每实体 label 可编辑+⟳ 单独重跑、「导入画布」「复制 JSON」按钮。
2) 底面背景：导入图片自动设为画布底面背景（bbox 叠图对照微调），透明度 30%/60%/100% 三档可调，⌥B 一键隐藏/恢复；复用现有参考图渲染层加 visible/opacity 状态位；状态持久化 ~/Library/Application Support/BBoxDesigner/configs.json。
3) 全部网络调用 async/await，UI 主线程不阻塞；面板显示模型冷启动加载状态。
验收：swift build 通过；手动跑通 拖图→识别→定位→进画布→微调→复制 JSON 全流程；⌥B 与透明度切换即时生效，重启 App 状态保留。
```

---

## M6 · 自测收尾与打包

```
在 BBoxDesigner 工程实施 M6：
1) 汇总 --selftest（原 27 项 + 新增：Ollama JSON 容错、轴序往返、NMS、折叠规则、SAM3 降级），全部通过。
2) scripts/make_app.sh 打包生成 BBoxDesigner.app；--mcptest 回归不破坏。
3) 端到端冒烟：flux-klein 生成一张人物图 → AI 自动标注 → 人工核对 IoU，结果写入 docs/ai-annotate-m6-report.md。
4) 更新 README 与 SKILL.md（新功能、快捷键 ⌥B、依赖 Ollama+ComfyUI SAM3）。
验收：App 打包成功、自测全绿、端到端报告落地。
```

---

## 附 · 提示词 A（Ollama 视觉实体识别系统提示，M1 内置，运行时调用）

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
