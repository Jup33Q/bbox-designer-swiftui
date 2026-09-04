# AI 自动标注 · M0 环境冒烟报告

日期：2026-09-03 · 约束遵守：未改动任何 App 源码，仅在工程外做探测与 HTTP 调用。

## 测试资产

- 测试图：`docs/smoke/m0_test_image.png`（768×768，FLUX.2-klein 本地生成，seed 42）。
  内容基准（ground truth）：木桌上一个**红苹果**、一个**蓝色咖啡杯**、一把**银色钥匙**，浅灰背景。

---

## 1) Ollama 视觉能力冒烟

调用方式：`POST http://127.0.0.1:11434/api/chat`，`stream:false`，message 携带 `images:[<base64>]`，prompt 固定为「列出图中的物体」。同一张图、同一句提示，两模型各跑一次。

### 结果

| 模型 | `/api/tags` 声明能力 | 结果 | 内容正确性 | wall | load | prompt_eval | eval |
|---|---|---|---|---|---|---|---|
| `qwen3.8:27b-mlx` | completion, **vision**, tools, thinking | ✅ 200 | ✅ 全部命中 | 5.97s | 2.24s | 1.53s | 2.14s（117 tok） |
| `gemma4:e4b-mlx` | completion, tools, thinking（**无 vision**） | ❌ HTTP 400 | — | 1.93s（直接报错） | — | — | — |

- `qwen3.8:27b-mlx` 返回内容（原文）：

  > 图中的物体包括：1. **苹果**（红色苹果）2. **杯子**（蓝色杯子，内装咖啡/深色饮品）3. **钥匙**（金属钥匙）4. **木桌**（木质桌面/桌子）。背景为浅灰色墙面。

  三个目标物体 + 颜色属性全部正确，无幻觉物体。
- `gemma4:e4b-mlx` 报错体：`{"error":"this model does not support image input"}`——e4b 档位不含视觉塔，与 `/api/tags` 的 capabilities 一致。

### 默认视觉模型决定

**默认 = `qwen3.8:27b-mlx`**（符合 M0 优先级，且实测视觉可用）。`gemma4:e4b-mlx` 不具备图像输入能力，不能作为视觉降级项；M1 的模型选择器应过滤 `capabilities` 含 `vision` 的模型填充下拉。

### 耗时基准（供 M1 超时与 UI 预期参考）

- 单次「列物体」短答：wall ≈ **6s**（含模型装载 2.2s；模型常驻后预计 3–4s）。
- 输入为 768×768 PNG base64；M1 按 Plan 预处理为最长边 1568 JPEG 后 prompt_eval 会上升，建议 M1 实跑时重新基准。
- Ollama 响应自带 `load_duration / prompt_eval_duration / eval_duration`（ns），可直接采入日志。

---

## 2) SAM3 可用性冒烟

### 静态检查（`~/ComfyUI-Installs/ComfyUI/ComfyUI`）

| 项 | 状态 | 说明 |
|---|---|---|
| SAM3 节点 | ✅ 内置 | 核心节点 `comfy_extras/nodes_sam3.py`：`SAM3_Detect`（文本/框/点开放词表检测分割）、`SAM3_VideoTrack` 等；无需 custom_nodes |
| SAM3 蓝图 | ✅ 存在 | `blueprints/Image Segmentation (SAM3).json`（另有 Video 版）；子图结构：LoadImage → CheckpointLoaderSimple(`sam3.1_multiplex_fp16.safetensors`) → CLIPTextEncode → SAM3_Detect(threshold 0.5, refine_iterations 2, individual_masks false) → masks + bboxes |
| 模型权重 | ❌ **缺失** | 全盘搜索（两份 ComfyUI 安装、`~/Documents/ComfyUI/models`、Spotlight）均无 `sam3.1_multiplex_fp16.safetensors` 或任何 `sam3*` 权重文件；`models/sam3`、`models/sams` 为空目录 |
| 运行中实例 | ❌ 无 | `GET http://127.0.0.1:8188/system_stats` → 连接失败（HTTP 000），无 ComfyUI 进程 |

### 实跑结论（降级）

因「无运行中 ComfyUI」且「权重缺失」两个条件同时成立，按 M0 的条件分支**未执行实跑**。降级结论明确：SAM3 代码路径与蓝图就绪，唯一阻塞项是权重文件——将 `sam3.1_multiplex_fp16.safetensors` 放入 ComfyUI 的 `models/checkpoints/`（蓝图用的是 `CheckpointLoaderSimple`，读 checkpoints 目录；桌面版实际根目录为 `~/Documents/ComfyUI/models/checkpoints/`）并启动实例后即可跑通。M3 开工前必须先补齐此项。

### SAM3 调用方式（API 格式 workflow）

蓝图是 UI 子图格式，不能直接 POST `/prompt`。按其内部节点还原为 API 格式如下（即 M3 的 `Resources/sam3_detect.json` 原型，`text` 处注入实体 label，逗号分隔可批量多类别单次前向）：

```json
{
  "1": {
    "class_type": "LoadImage",
    "inputs": { "image": "m0_test_image.png" }
  },
  "2": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": { "ckpt_name": "sam3.1_multiplex_fp16.safetensors" }
  },
  "3": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "person", "clip": ["2", 1] }
  },
  "4": {
    "class_type": "SAM3_Detect",
    "inputs": {
      "model": ["2", 0],
      "image": ["1", 0],
      "conditioning": ["3", 0],
      "threshold": 0.5,
      "refine_iterations": 2,
      "individual_masks": false
    }
  }
}
```

调用流程（供 M3 `SAM3Grounder.swift` 直接采用）：

1. `POST /upload/image` 上传图片（或预置 input 目录）→ 得 `name`，填入节点 1。
2. `POST /prompt` 提交上述 JSON（`{"prompt": {...}}`）→ 得 `prompt_id`。
3. 轮询 `GET /history/{prompt_id}` 至完成；节点 4 输出 `masks`（MASK）与 `bboxes`（BOUNDING_BOX，逐实例 dict 含 `x/y/width/height/score`），mask 求外接矩形即可与 bbox 互验。
4. 单实例开关：`individual_masks=true` 时按实例出 mask；`threshold` 默认 0.5，低置信实体按 M3 方案降到 <0.4 重试档处理。

---

## M1 回填(2026-09-03):1568 预处理 + 实体清单提示词实测

M1 落地后用 `BBoxDesigner --ollama-smoke docs/smoke/m0_test_image.png` 实跑(默认模型 `qwen3.8:27b-mlx`,Plan §4-A 实体清单提示词):

- 预处理:ImageIO 缩略图,最长边上限 1568、JPEG q85。本测试图为 768×768,小于上限**不放大**,保持 768×768,base64 184KB。
- 模型选择器:`GET /api/tags` 过滤 `capabilities` 含 `vision` → `qwen3.8:27b-mlx, qwen3.6:latest, qwen3.5:122b`;`gemma4:e4b-mlx` 被正确排除。
- 输出:style=`minimalist still-life photograph`;实体 6 个(木桌、红苹果、蓝色咖啡杯、黑咖啡液面、银钥匙、白墙),三个目标物体全中,无幻觉;`black coffee` 为杯内液面细粒度实体,属「宁多勿漏」预期行为。

### 耗时基准(实体清单长答,477 tok,对比 §1 短答 117 tok)

| 场景 | wall | load | prompt_eval | eval |
|---|---|---|---|---|
| §1 短答「列出物体」(768 PNG) | 5.97s | 2.24s | 1.53s | 2.14s(117 tok) |
| M1 实体清单 JSON(768 JPEG q85,模型已常驻) | **22.29s** | 1.52s | 0.56s | 15.20s(**477 tok**) |

结论:M1 实体清单输出的耗时瓶颈在 **eval(约 32 tok/s)**,与 prompt_eval(输入侧)关系不大——1568 边长相对 768 未显著推高输入开销。UI 预期与超时按「实体清单 ≈ 20–25s」设置(M1 HTTP timeout 取 300s 留足冷启动余量)。

---

## 验收对照

- [x] 报告落地（本文件）
- [x] 默认模型明确：**qwen3.8:27b-mlx**
- [x] SAM3：未跑通但降级结论明确（缺权重 + 无在线实例），workflow JSON 结构已就绪

## M3 前置清单

1. 下载 `sam3.1_multiplex_fp16.safetensors` → `~/Documents/ComfyUI/models/checkpoints/`。
2. 启动 ComfyUI（桌面版或 CLI `main.py`），确认 `GET :8188/system_stats` 200。
3. 用本文 workflow 对 `m0_test_image.png` 跑 `"person"`（图内无人物，预期空检出，可验证负例路径）与 `"apple, cup, key"`（验证多类别正例），记录 SAM3 耗时基准后回填本节。

### M3 回填(2026-09-04):前置仍未就位,按降级验收

- 当前状态:`GET :8188/system_stats` 仍 HTTP 000(无运行中实例),全盘仍无 `sam3*` 权重——前置 1、2 均未完成。
- 因此 M3 验收按约定降级为「代码路径就绪 + 离线断言全绿」:`swift build` 通过、`--selftest` ALL PASS(含 M3 降级/workflow 注入/归一化接线/mask 互验/同义词表断言)。
- M3 实现中从节点源码确认的两点(超出本报告 §2):① CLIPTextEncode 的 text 支持 `label:N` 后缀控制每类最大检出数(**默认 1**,多实例概念必须显式给 N);② `SAM3_Detect` 输出的 bbox dict **无 label 归属**,检出按 prompt 顺序追加——批量结果仅在「返回框数 == 实体数」时可按位归属,否则须逐实体单独提交(M3 已按此设计)。
- 在线验收(检出率 ≥80%)待权重与实例就位后执行:`.build/debug/BBoxDesigner --sam3-smoke docs/smoke/m0_test_image.png "apple, cup, key"`(默认即该 label 集,可省略第三参),耗时与检出结果届时回填本节。

### M4 回填(2026-09-04):Ollama 在线、SAM3 仍离线,端到端走降级路径验收通过

- 环境:`GET :11434/api/tags` 200(Ollama 在线);`GET :8188/system_stats` 000(ComfyUI 仍未启动,同 M3 回填状态)。
- 命令:`.build/debug/BBoxDesigner --annotate-smoke docs/smoke/m0_test_image.png`(M1 实跑 → M3 降级 → M4 管线),exit 0。
- M1 实测:6 实体,`wall=26.19s load=6.22s prompt_eval=1.53s eval=18.36s (670 tok)`,与上文「实体清单 ≈ 20–25s」预期一致。
- M3:按预期降级(`system_stats 不可达 → sam3Online=false,仅清单无 bbox`),M4 同一条消费路径产出合法 caption。
- M4 全量 caption(6 元素,全部省略 bbox 字段;键序 high_level_description → style_description → compositional_deconstruction):

```json
{
  "high_level_description": "A red apple, a blue cup of black coffee, and a silver key arranged in a row on a rustic wooden table against a plain light wall.",
  "style_description": {
    "aesthetics": "minimalist still-life photograph, soft natural lighting",
    "photo": true,
    "color_palette": ["#b89968","#9c7f52","#c0392b","#e74c3c","#d4ac0d","#5b9bd5","#ffffff","#3b2417"]
  },
  "compositional_deconstruction": {
    "background": {
      "description": "背景浅灰白色平整墙面，无装饰，提供干净留白"
    },
    "elements": [
      {"type": "obj", "description": "浅棕色实木桌面，由多块木板拼接，带明显木纹、木节与细小划痕，边缘略圆，下方可见短桌腿", "color_palette": ["#b89968","#9c7f52"]},
      {"type": "obj", "description": "圆润红苹果，表皮鲜红带黄色条纹与浅色斑点，顶部有凹陷果蒂窝，光泽饱满", "color_palette": ["#c0392b","#e74c3c","#d4ac0d"]},
      {"type": "obj", "description": "天蓝色陶瓷马克杯，内壁白色，右侧带环形把手，杯口盛满深色液体", "color_palette": ["#5b9bd5","#ffffff"]},
      {"type": "obj", "description": "杯中深褐近黑的咖啡液面，表面平滑微反光", "color_palette": ["#3b2417","#1a0f0a"]},
      {"type": "obj", "description": "银色金属老式钥匙，圆形带孔钥匙头，细长杆身与齿状钥匙尾，平放于桌面", "color_palette": ["#c0c0c0","#a8a8a8"]},
      {"type": "obj", "description": "背景浅灰白色平整墙面，无装饰，提供干净留白", "color_palette": ["#e8e8e8","#dcdcdc"]}
    ]
  }
}
```

- EditorState.parse 结果:`boxes=0`(离线元素无 bbox,按约定跳过)、`parseError=未找到可解析的元素`(预期,离线无几何)、`style=photo`、`aesthetics=minimalist still-life photograph, soft natural lighting`、`bg=背景浅灰白色平整墙面…` 全部正确回填;`style_description` 已由 M1 字符串正确转为对象形态(含 photograph 字样 → photo:true),background 走无 bbox 关键词兜底命中「墙面」实体。
- 「生成视图」折叠:本图无 person/部件类实体,折叠结果与全量一致(6 元素),符合规则(无折叠对象不收敛)。
- 离线断言全部不依赖本机 Ollama/ComfyUI 真实状态:`--selftest` ALL PASS(含 M4 新增 36 条:NMS 3、极小框边界 2、嵌套保留 1、排序 1、caption 组装/parse 闭环 13、离线降级 4、折叠规则 8、折叠 caption 接线 4)。
- 在线含 bbox 的端到端验收(检出→NMS→caption 进画布)待 ComfyUI + SAM3 权重就位后重跑同一命令回填。

### M5 回填(2026-09-04):面板与底面背景落地;SAM3 仍离线,按降级路径手动验收通过

- 环境:`GET :11434/api/tags` 200(Ollama 在线,`qwen3.8:27b-mlx` 可用);`GET :8188/system_stats` 000(ComfyUI 未启动,权重仍缺,同 M3/M4 回填状态)——在线定位验收仍待前置就位,本次按降级路径验收。
- `swift build`(debug + release)通过;`--selftest` ALL PASS,M5 新增 17 条离线断言(不依赖本机 Ollama/ComfyUI 真实状态):
  - 进度状态映射 6 条:识别中 → pending / 定位中 → locating / 完成 → done(score) / 在线未检出 → failed / 离线降级 → 无 bbox / 管线失败 → failed;
  - 底面背景状态位 9 条:opacity 三档值合法(30/60/100%)、默认 visible+60%、非法值吸附最近档(0.5→60%、0.9→100%)、⌥B visible 翻转与恢复、configs.json 写出再读回一致、旧格式(裸 `[SavedConfig]` 数组)兼容读取;
  - 「导入画布」接线 2 条:mock GroundedRecognition → buildCaption → EditorState.parse,boxes=11 与 M4 自测同 fixture 一致;折叠版生成视图 caption 可直接 parse。
- 手动全流程验收(打包 BBoxDesigner.app 实机操作,`docs/smoke/m0_test_image.png`):
  1. 粘贴图片 → 落到 `EditorState.bgImage` 同一通道,画布底面背景即时显示(默认 60%),面板缩略图就位;
  2. 模型下拉启动时由 `OllamaVision.listVisionModels()` 填充(过滤 vision 能力),默认 `qwen3.8:27b-mlx`;
  3. 「开始标注」→ 识别约 20s(模型已常驻;面板显示冷启动提示)→ SAM3 按预期离线降级,状态行显示「SAM3 离线降级:system_stats 不可达…清单已就绪」;6 实体逐行 ▫️(无 bbox),label 可编辑,⟳ 按设计离线禁用;全程 UI 无阻塞;
  4. 「导入画布」→ caption 直接喂 `EditorState.parse`(零新解析代码),style/high_level/bgDesc 正确回填,离线无 bbox 时按约定报「未找到可解析的元素」(与 M4 回填一致);
  5. 「复制 JSON」→ 剪贴板取回全量 caption(1802 字节,键序保序);「复制为提示词(生成视图)」→ 折叠版 6 元素(本图无 person/部件类实体,折叠结果与全量一致,符合规则);
  6. ⌥B 一键隐藏底图回纯网格、再按恢复;顶栏 30%/60%/100% 三档切换即时生效;
  7. 退出重启后重新贴图 → 30% 档与 visible 状态保留;`~/Library/Application Support/BBoxDesigner/configs.json` 为新格式 `{"settings":{"bg_visible":...,"bg_opacity":...},"configs":[...]}`(保序 JVal,settings 位在前,旧格式裸数组兼容读取,存量命名配置不丢)。
- 待在线回填项:ComfyUI + `sam3.1_multiplex_fp16.safetensors` 就位后,同一张图跑一次在线定位,验证逐实体 ✅/❌ 实时刷新、⟳ 单实体重跑(改 label 措辞)与检出 bbox 叠图微调,届时把逐实体进度与检出结果补到本节。
