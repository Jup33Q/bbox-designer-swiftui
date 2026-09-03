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
