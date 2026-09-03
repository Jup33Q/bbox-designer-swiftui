---
name: bbox-designer
description: 本地 SwiftUI 版 BBox 位置设计器(复刻 bbox.toolbuddy.art),用于 Ideogram 4 JSON 提示词(compositional_deconstruction / bbox / elements)的可视化编辑、解析、写回,并可调用本地 flux-klein MCP 生成图片。当用户要求"打开/使用 BBox 设计器"、"编辑 ideogram 4 JSON 提示词"、"拖拽排版 bbox 生成 caption"、"用 bbox 布局生成图片"时使用。
---

# BBoxDesigner(SwiftUI 本地版)

复刻 https://bbox.toolbuddy.art/ 的 macOS 原生应用,并集成本地 `flux-klein` MCP 文生图。

## 位置与启动

- 工程:`BBoxDesigner/`(SwiftPM,纯 Command Line Tools 即可编译,无需 Xcode)
- 打包:`cd BBoxDesigner && scripts/make_app.sh` → 生成 `BBoxDesigner.app`
- 启动:`open BBoxDesigner/BBoxDesigner.app`
- 自测:`BBoxDesigner.app/Contents/MacOS/BBoxDesigner --selftest`(36 项断言:JSON 解析/写回闭环 + 智能对齐吸附)
- MCP 冒烟:`BBoxDesigner.app/Contents/MacOS/BBoxDesigner --mcptest`

## 功能对照(与网页版一致)

- 画布:7 档尺寸预设(1024²/1344×768/1408×704/768×1024/768×1152/896×1152/960×1280)、自定义 W×H(64 对齐)、比例锁定(9 种)、参考图(上传/拖拽/⌘⇧V 粘贴)
- 框编辑:拖动移动、8 手柄缩放、双击空白新建、框选/⌘加选/Shift 范围选、多选整体拖动(统一钳制+虚线组框)、对齐×6、等距×2、复制/锁定/隐藏、网格吸附、智能对齐吸附(黄色参考线+触觉反馈,⌘ 拖动禁用)、三分构图线
- 快捷键:⌘Z / ⇧⌘Z 撤销重做、Delete 删除、⌘A 全选、方向键微调(Shift=20px 大步进)
- 导入:粘贴/选文件解析 Ideogram 4 JSON(bbox 轴序 [ymin,xmin,ymax,xmax] @0–1000;兼容 elements / compositional_deconstruction.elements / objects / boxes;字段别名 desc/description/label/name)
- 写回:「更新提示词」带差异确认面板(BBox/描述/全局字段/新增/删除),原地更新保留未知字段与键顺序
- 输出:实时 caption JSON(high_level_description + style_description + compositional_deconstruction),标量数组单行紧凑格式;复制 caption / 复制为提示词
- 色板:对象级 color_palette + desc 内 #rrggbb 提取,单击复制、双击改色(24 预设色 + hex + 系统取色器);整体配色改色同步写回
- 配置管理:保存/还原/删除(持久化到 `~/Library/Application Support/BBoxDesigner/configs.json`,含背景图)

## MCP 集成(flux-klein)

- 子进程方式启动 `~/Desktop/FluxKleinStudio.app/Contents/MacOS/FluxKleinStudio mcp`,行分隔 JSON-RPC 2.0(stdio)
- 「本地生成 · FLUX.2-klein」面板:一键从画布拍平提示词 → `generate_image`(步数 4 / guidance 1.0 / seed / 量化可选)
- 画布尺寸自动对齐到 16 倍数(256–2048)作为生成分辨率
- 输出:`~/Library/Application Support/BBoxDesigner/outputs/gen-*.png`,可勾选自动设为画布参考图
- 若 MCP 二进制缺失,面板显示"未找到 FluxKleinStudio",不影响其他功能

## Agent 协作要点

- 用户给一段 ideogram 4 caption JSON:可直接写入 App 的粘贴框逻辑(见 `EditorState.parse`)——解析规则与网页版逐行对齐
- 新增元素无 `srcIndex`,「更新提示词」时追加到源数组;删除元素同步移除并重排下标
- `JVal`(JVal.swift)是保序 JSON AST,写回不丢字段、不打乱键序;`JValWriter.compact` 复刻网页 stringifyCompact
