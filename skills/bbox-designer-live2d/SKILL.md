---
name: bbox-designer-live2d
description: 用 BBoxDesigner(SwiftUI 版 bbox.toolbuddy.art)+ 本地 flux-klein MCP 生成 Live2D 风格立绘/角色的专用工作流:竖版单人构图、front-facing 对称站姿、分层部件 bbox 布局、透明背景抠图(sam_edit remove_background)。当用户要求"生成 Live2D 风格立绘"、"Live2D 皮/角色"、"虚拟主播立绘"、"VTuber 角色图"、"可做 Live2D 的角色设计"、"正面立绘 透明背景"时使用。依赖 bbox-designer skill 提供的 App 与 flux-klein MCP。
---

# Live2D 风格立绘生成(BBoxDesigner × flux-klein)

面向"可拆分做 Live2D 绑定"的角色立绘:正面、全身/半身、对称、少遮挡、透明背景。
先读 `bbox-designer` skill 了解 App 启动与 JSON 规则;生成/抠图走 `flux-klein` MCP(generate_image / edit_image / sam_edit)。

## 构图约定(在 App 画布上排 bbox)

- **画布**:竖版 `768×1152` 或 `896×1152`(预设里有);全身像优先
- **背景**:留空 background 描述;透明背景靠生成后 `sam_edit(op="remove_background")` 抠出
- **元素布局**(由密到疏,按需要选):
  - 单人全身:1 个大 bbox 几乎撑满画布(ymin≈2%,ymax≈98%,横向居中,xmin≈15%,xmax≈85%)
  - 分层部件(便于后续 PSD 拆分/绑定参考):hair / face / eyes / upper_body / arms / lower_body / accessory 各占一个 bbox,互不重叠、边界对齐
- **姿势关键词**(写进元素 description):`front-facing, standing straight, symmetrical A-pose, arms slightly away from body, looking at viewer, full body visible, no cropping`
- **风格**(style_description):`art_style=true`,aesthetics 例:`anime cel shading, clean lineart, Live2D-style character sheet art, flat colors with soft gradient shading`

## 部件级布局(头发 / 五官 / 衣物细节,坐标为 [ymin,xmin,ymax,xmax] @0-1000)

生成 Live2D 立绘或人脸时,**必须**把头发、五官(眉/眼/鼻/嘴)、衣物细节拆成独立 bbox 并放在正确位置——不能只给一个大框。竖版 768×1152 竖构图的参考布局(可按角色比例微调):

| 部件 | bbox | 说明 |
|---|---|---|
| 整体头发 hair | [40,180,520,820] | 覆盖头顶到肩,含刘海与两侧垂发 |
| 脸 face | [220,300,600,700] | 脸部皮肤区域,在头发之下 |
| 左眉 eyebrow_left | [300,340,345,470] | 眉比眼略宽、略高 |
| 右眉 eyebrow_right | [300,530,345,660] | 与左眉水平对称 |
| 左眼 eye_left | [345,350,425,475] | 眉正下方 |
| 右眼 eye_right | [345,525,425,650] | |
| 鼻子 nose | [425,460,510,540] | 两眼之间中轴线 |
| 嘴 mouth | [520,420,575,580] | 鼻正下方 |
| 左耳 ear_left | [330,215,430,295] | 可选 |
| 右耳 ear_right | [330,705,430,785] | 可选 |
| 脖子 neck | [590,430,665,570] | |
| 衣领 collar | [640,360,740,640] | 领口/领巾/项链区 |
| 上身衣物 upper_clothing | [660,180,1000,820] | 肩线到下摆,含褶皱/扣子/花纹等细节描述 |
| 发饰 accessory | [120,230,220,350] | 可选(发夹/缎带) |

要点:左右部件以 x=500 中轴严格对称;五官全部落在 face 框内部;衣物框与 neck/collar 衔接不留缝。

## 迭代流程(重要)

1. **先生成基础部件集**:头发 + 脸 + 五官 + 脖子 + 上身衣物(约 10 个框),输出 JSON
2. **等用户调整**:用户在 App 里拖框微调位置/大小,或口头提修改要求
3. **再加细节**:确认后追加衣物细节(扣子/花纹/口袋)、发饰、手部等框
4. 每轮**保存 JSON 到工作区文件**(如 `live2d-layout-<时间戳>.json`),并在回复里用 ```json ``` 代码块完整包裹输出,方便用户直接复制粘贴到 App「导入」框
5. 用户满意后再走「生成与后处理」

## 现成 caption 模板(可直接粘贴进 App「导入」再拖框微调)

```json
{
  "high_level_description": "Live2D-style character standing illustration, front view, full body, plain light background",
  "style_description": {
    "aesthetics": "anime cel shading, clean lineart, character sheet art",
    "lighting": "even soft studio light",
    "medium": "digital illustration",
    "art_style": true,
    "color_palette": ["#E8B04B", "#38BDF8", "#E8EEFB"]
  },
  "compositional_deconstruction": {
    "background": {"bbox": [0,0,1000,1000], "description": "plain solid light gray background, no shadow"},
    "elements": [
      {"type": "obj", "bbox": [20,150,980,850], "description": "a girl with short dark hair, wearing a light blue shirt, front-facing, standing straight, symmetrical A-pose, arms slightly away from body, looking at viewer, full body visible, no cropping"}
    ]
  }
}
```

## 生成与后处理

1. App 内「本地生成 · FLUX.2-klein」面板:点「从画布生成提示词」→ 生成(步数 4 / guidance 1.0;同角色迭代时固定 seed)
2. 抠透明底:`sam_edit(image_path=<生成图>, op="remove_background")` → RGBA PNG
3. 局部修改(改色/换配饰):`edit_image(prompt=..., image_paths=[图])`,klein 引擎 guidance 1.0、4 步
4. 交付:给出 PNG 绝对路径 Markdown 链接;提醒用户 Live2D 绑定还需在 PSD 里按部件分层(本工具输出的分层 bbox 布局可作为拆分参考)

## 注意

- Klein 是 4 步蒸馏模型,复杂多层部件一次全画容易混色;部件多时对每个部件单独生成再合成更稳
- 生成分辨率会被 App 对齐到 16 倍数;竖版画布无需改动
- 若 flux-klein 报 "backend not ready":`~/Documents/kimi/workspace/flux-klein-studio/scripts/setup_backend.sh`
