# M6 · 自测收尾与打包 — 验收报告

日期:2026-09-04 · 工程:`BBoxDesigner/` · 里程碑定义:`docs/AI-ANNOTATE-MILESTONES.md`

## 1. --selftest 汇总

- 结果:**ALL PASS,178 项断言、0 失败**(debug 与 release 包内二进制均验证)。
- 覆盖:原解析/写回/吸附/多选/标签断言 + M1 Ollama JSON 容错、M2 轴序往返、M3 降级、M4 NMS/折叠、M5 状态映射/底图状态位/导入接线。
- M6 修复的 2 个 FAIL(非新断言,是 M5 测试隔离缺陷):
  - `EditorState.init()` 在测试钩子 `configsURLForTesting` 赋值前就读了真实 `~/Library/Application Support/BBoxDesigner/configs.json`(本机当时为 `bg_opacity: 0.3`),污染「默认 visible + 60%」与「旧格式兼容读取」两条断言。
  - 修复:新增 `EditorState(testConfigsURL:)` 专用初始化器(先设路径再加载,不动原有接口);`loadConfigs(from:)` 在文件缺失/旧裸数组无 settings 位时显式将 `bgVisible/bgOpacity` 复位默认(与原有文档注释「无 settings 位给默认」一致)。
  - 自测全程不再读写真实 configs.json(已验证文件内容前后不变)。

## 2. 打包与 MCP 回归

- `scripts/make_app.sh`:`swift build -c release` 通过,生成 `BBoxDesigner.app` 并已同步覆盖 `~/Desktop/BBoxDesigner.app`(执行前已向用户确认)。
- 包内二进制 `--selftest` → ALL PASS;`--mcptest` → `MCP OK, tools: generate_image, edit_image, sam_edit, depth_map`。

## 3. 端到端冒烟(降级路径)

**环境判定**:ComfyUI 未启动(`http://127.0.0.1:8188/system_stats` 连接失败),`models/checkpoints/` 为空、`sam3.1_multiplex_fp16.safetensors` 权重缺失(同 m0 报告 M3/M4/M5 回填结论)→ 按**降级路径**验收,在线 IoU 核对待权重补齐后进行。

**测试图**:flux-klein 生成的人物图 `docs/smoke/m6_test_person.png`(1024×1024,seed 118853115:牛仔夹克/白百褶裙/红帆布鞋女性,手持咖啡杯,木桌/琴叶榕/窗)。

**命令**:`BBoxDesigner --annotate-smoke docs/smoke/m6_test_person.png`(默认模型 qwen3.8:27b-mlx),exit=0。

**耗时**(wall):
- M1 Ollama 实体识别:50.17s(load 0.01s + prompt_eval 0.14s + eval 49.94s,1664 tok)
- M3 SAM3 定位:即时降级(system_stats 不可达)
- M4 后处理 + caption:毫秒级 · **全程 50.5s**

**逐实体检出**:M1 识别 **28 实体**(穷尽 7 层,与人眼核对图面内容一致,无明显漏检/幻觉):

| 层 | 检出 |
|---|---|
| 人物整体 | 年轻女性(长直棕发、捧杯站立) |
| 服装逐件 | 牛仔夹克 / 白色圆领内搭 / 白色百褶短裙 / 红色帆布鞋 |
| 五官逐个 | 左眼 / 右眼 / 睫毛 / 眉毛 / 鼻子 / 嘴 / 耳朵 |
| 头发 | 中分长直棕发 |
| 手与手臂 | 左手 / 右手 / 左臂 / 右臂 |
| 场景道具 | 咖啡杯 / 原木书桌 / 桌上书堆 / 窗台多肉 / 窗台陶瓷杯 / 玻璃窗 / 琴叶榕 / 圆柱花盆+托盘 / 木地板 / 墙面 / 窗台台面 |

- M3:`online=false`,28 实体全部「仅清单无 bbox」返回,**不阻塞管线**(降级行为符合设计)。
- M4:全量 caption 28 元素(person 在前 + 面积降序);生成视图折叠为 16 元素;`EditorState.parse` 安全落地(boxes=0 为离线设计行为,style=photo、aesthetics/background 正确回填)。
- 结论:**降级路径端到端验收通过**。SAM3 离线时 IoU 无从核对;待用户补齐权重并启动 ComfyUI 后重跑同一命令即可走在线全流程做人工 IoU 核对。

**观察(不阻塞验收,留后续)**:两次冒烟 M1 实体数为 28 / 14(视觉模型采样有波动,temperature 0.1 下仍非完全确定);生成视图 16 元素高于 Plan §3.1 的 3–6 目标——garment 整体与家具道具按现折叠规则各自独立成元素,如需收紧应在后续里程碑调整折叠策略,不在 M6 范围内改动 M4 逻辑。

**附**:首次冒烟(同一图片)14 实体、48.9s、exit=0,降级行为一致;上表以第二次全量日志为准。

## 4. 文档更新

- `README.md`:新增「AI 自动标注」章节(面板位置、Ollama + ComfyUI SAM3 依赖与降级行为、模型下拉)、⌥B 与透明度三档、configs.json 新格式与旧裸数组兼容说明、--annotate-smoke 用法、AIAnnotate 目录结构;自测断言数更新为 178。
- `SKILL.md`:同步上述功能说明与协作要点。

## 验收核对

- [x] App 打包成功(debug/release 自测均全绿,桌面版已同步)
- [x] `--selftest` ALL PASS(178 项)
- [x] `--mcptest` MCP OK
- [x] 端到端报告落地(本文档;降级路径结论 + 耗时 + 逐实体检出)
- [x] README.md / SKILL.md 已更新
