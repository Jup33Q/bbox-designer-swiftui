# BBoxDesigner

> BBox 位置设计器 · Ideogram 4 元素定位 — macOS 原生 SwiftUI 版

![screenshot](docs/screenshot.png)

在画布上拖动物体框 → 自动生成 bbox 坐标与描述 → 输出符合 Ideogram 4 caption schema 的结构化 JSON 提示词,并可一键调用本地 FLUX.2-klein(MCP)直接生成图片验证布局。

这是网页工具 **[BBox 位置设计器](https://bbox.toolbuddy.art/)** 的 SwiftUI 复刻版(详见文末 [Acknowledgments](#acknowledgments))。

## 功能

- **画布**:7 档尺寸预设(1024²/1344×768/1408×704/768×1024/768×1152/896×1152/960×1280)、自定义 W×H(64 对齐)、9 种比例锁定、参考图(上传 / 拖拽 / ⌘⇧V 粘贴)
- **框编辑**:拖动移动、8 手柄缩放、双击空白新建、框选 / ⌘加选 / Shift 范围选、6 向对齐、双向等距、复制 / 锁定 / 隐藏、网格吸附、智能对齐吸附(画布/物体边缘与中线,黄色参考线 + 触摸板触觉反馈,⌘ 拖动临时禁用)、三分构图参考线
- **快捷键**:⌘Z / ⇧⌘Z 撤销重做、Delete 删除、⌘A 全选、方向键微调(Shift = 20px 大步进)
- **导入**:粘贴 / 选文件解析 Ideogram 4 JSON(bbox 轴序 `[ymin,xmin,ymax,xmax]` @0–1000;兼容 `elements` / `compositional_deconstruction.elements` / `objects` / `boxes`;字段别名 desc/description/label/name)
- **写回**:「更新提示词」带差异确认面板(BBox / 描述 / 全局字段 / 新增 / 删除),原地更新——**保留未知字段与键顺序**(自研保序 JSON AST `JVal`)
- **输出**:实时 caption JSON(`high_level_description` + `style_description` + `compositional_deconstruction`),标量数组单行紧凑格式;复制 caption / 复制为提示词
- **色板**:对象级 `color_palette` + desc 内 `#rrggbb` 提取,单击复制、双击改色(24 预设色 + hex + 系统取色器)
- **配置管理**:保存 / 还原 / 删除,持久化到 `~/Library/Application Support/BBoxDesigner/configs.json`(含背景图)
- **本地生成**:集成 flux-klein MCP,从画布拍平提示词 → `generate_image`,结果可自动设为参考图

## 构建与运行

无需 Xcode,只需 macOS Command Line Tools(Swift 5.9+ / macOS 14+):

```bash
scripts/make_app.sh        # swift build -c release + 打包 BBoxDesigner.app
open BBoxDesigner.app
```

自测与冒烟:

```bash
BBoxDesigner.app/Contents/MacOS/BBoxDesigner --selftest   # 27 项 JSON 解析/写回闭环断言
BBoxDesigner.app/Contents/MacOS/BBoxDesigner --mcptest    # flux-klein MCP 握手冒烟测试
```

## MCP 集成(可选)

App 以子进程方式启动本机 `~/Desktop/FluxKleinStudio.app/Contents/MacOS/FluxKleinStudio mcp`(行分隔 JSON-RPC 2.0 over stdio),调用 `generate_image`:

- 画布尺寸自动对齐到 16 倍数(256–2048)作为生成分辨率
- 输出到 `~/Library/Application Support/BBoxDesigner/outputs/`
- 若未安装 [flux-klein-studio](https://github.com/) MCP 二进制,生成面板显示不可用,其余功能不受影响

## 项目结构

```
Sources/BBoxDesigner/
├── JVal.swift         # 保序 JSON AST + 解析器 + 紧凑序列化(复刻网页 stringifyCompact)
├── EditorState.swift  # 画布模型 / 解析 / 写回 / 撤销重做 / 配置持久化
├── CanvasView.swift   # 画布渲染与手势(移动/缩放/框选/双击新建)
├── Panels.swift       # 物体列表 / 选中信息 / 全局风格 / 导入 / 输出 / 配置 / 生成面板
├── ContentView.swift  # 主界面布局 / 快捷键 / 差异确认面板
├── FluxMCP.swift      # stdio MCP 客户端 + FLUX 生成状态
└── SelfTest.swift     # --selftest 自测
```

## Acknowledgments

- 本项目的设计与交互复刻自 **[@ToolBuddy 的 BBox 位置设计器](https://bbox.toolbuddy.art/)**(ideogram 4 元素定位网页工具)。原站点为闭源单页应用;我们检索了 GitHub(toolbuddy-io 组织、"ideogram bbox"、特征代码串等),**截至 2026-09 未找到其公开源码仓库**,故无法 fork,本仓库为独立的净室(clean-room)SwiftUI 重实现。若原作者公开仓库,欢迎联系,我们乐意改为 fork 关系并补充署名链接。
- bbox 轴序 `[ymin,xmin,ymax,xmax]` @0–1000 等 caption schema 约定来自 [Ideogram 4](https://github.com/ideogram-oss/ideogram4)。
- 本地文生图由 [FLUX.2-klein](https://huggingface.co/black-forest-labs) (MLX / mflux) 驱动。

## License

[MIT](LICENSE) © 2026 Jup33Q
