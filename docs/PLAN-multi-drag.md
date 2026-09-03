# PLAN: 多选整体拖动(Multi-Select Group Drag)

> 目标:框选/⌘加选/Shift 范围选多个 bbox 后,拖动其中任意一个,整组保持相对位置一起移动;
> 行为对齐 Keynote/PPT 的多选拖动体验。

## 0. 现状审计(先做)

代码里已有雏形(`EditorState.boxDown` 记录 `moveOrigins`、`moveDragged` 统一应用 delta),但存在已知缺陷与未验证项:

| 项 | 现状 | 目标 |
|---|---|---|
| 点击已选中组内的框 | 保持多选 ✓ | 保持 |
| 点击未选中的框 | 重置为单选 ✓ | 保持 |
| 边界钳制 | **每个框独立 clamp** → 贴边时框被逐个卡住,相对位置被压扁变形 | **整组统一钳制**:先算组包围盒可用 delta 范围,全组应用同一 delta,相对布局永不变形 |
| 组包围盒可视化 | 无 | 多选拖动期间显示组包围盒虚线框(可选,低优先) |
| 拖动中与其他物体对齐 | 待 smart-align plan 落地后,多选拖动应以**组包围盒**参与吸附 | 联动(见 §5) |
| 锁定/隐藏框 | 不随动 ✓(movableSelection 已过滤) | 保持,并补测试 |
| 撤销/重做 | endDrag 记一次历史 ✓ | 保持,补断言:多选拖动后 undo 一次全部归位 |

## 1. 技术方案

### 1.1 整组统一钳制(核心改动)
`moveDragged(to:)` 重写:

```swift
// 1. 原始 delta = 当前点 - dragStart
// 2. 对 moveOrigins 的组包围盒 bboxUnion(origins),计算 delta 可行域:
//    dx ∈ [-union.minX, imgW - union.maxX]
//    dy ∈ [-union.minY, imgH - union.maxY]
// 3. clamp 后的 (dx, dy) 应用到每个 origin:
//    boxes[i].x = orig.x + dx; boxes[i].y = orig.y + dy
//    (网格吸附开启时,先对 delta 做 snap 再 clamp;smart-align 落地后同理先吸附)
```

### 1.2 组包围盒虚线框(可选增强)
- `moveDragged` 期间 `@Published var groupBounds: CGRect?`(瞬态,不进历史)
- `CanvasAreaView` 在 `activeGuides` 同层绘制:黄色虚线 `stroke(style: StrokeStyle(lineWidth: 1, dash: [5,4]))`
- `endDrag` / 手势结束时置 nil

### 1.3 选择语义保持不变(回归测试锁住)
- 普通点击组内框 → 保持整组,可拖
- 普通点击组外框 → 单选该框
- ⌘点击组内框 → 从组移除(剩 1 个时不允许移除)
- ⌘点击组外框 → 加入组
- 空白拖动 → 框选替换;⌘空白拖动 → 框选 toggle

## 2. 文件改动清单

| 文件 | 改动 |
|---|---|
| `Sources/BBoxDesigner/EditorState.swift` | `moveDragged` 统一钳制重写;新增 `groupBounds` 瞬态发布;`endDrag` 清理 |
| `Sources/BBoxDesigner/CanvasView.swift` | 组包围盒虚线框绘制(可选) |
| `Sources/BBoxDesigner/SelfTest.swift` | 新增 §3 断言 |
| `README.md` / `SKILL.md` | 功能清单更新一行 |

## 3. SelfTest 新增断言

1. **整组移动**:A(100,100,50,50) B(300,300,50,50) 全选,拖 dx=20,dy=30 → A(120,130) B(320,330),相对偏移不变
2. **统一钳制(右/下)**:同上,拖 dx=+10000 → 组右缘贴 imgW,B.x = imgW-50,A.x = imgW-50-200(间距保持 200)
3. **统一钳制(左/上)**:拖 dx=-10000 → A.x=0,B.x=200
4. **锁定框不随动**:A locked,全选 A+B 拖动 → A 不动,B 动;组包围盒钳制只按可动框计算
5. **隐藏框不随动**:同上
6. **undo 一次全部归位**:多选拖动后 undo → A、B 均回原位
7. **选择语义回归**:点击组内框保持多选;点击组外框变单选;⌘点击组内仅剩 1 个时不移除

## 4. 手动验证清单

- [ ] 框选 3 个框,拖任意一个,三个一起动且间距不变
- [ ] 整组拖到画布边缘,整组贴边停下,无框被单独卡住变形
- [ ] 组内含锁定框,只有未锁定的动
- [ ] ⌘Z 一次全部归位
- [ ] 方向键微调(已有)在多选下仍正常

## 5. 与 smart-align 的联动(后做,不在本次范围)

smart-align 落地时,多选拖动以**组包围盒的 6 条边线**作为 moving rect 参与吸附(PLAN-smart-align §2.2 已按此设计,本次的 bboxUnion 工具函数直接复用)。

## 6. 实施顺序

1. SelfTest 先写 7 条断言(此时 §1.1 未改,断言 2/3 应失败,确认缺陷存在)
2. `moveDragged` 统一钳制重写 → 断言全过
3. (可选)组包围盒虚线框 → 视觉验证
4. make_app.sh 打包同步桌面,commit + push
