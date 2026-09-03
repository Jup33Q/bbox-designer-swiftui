# 激活提示词(Multi-Drag 实施)

把下面这段粘给新会话即可开工(它会自己读 plan 和代码):

---

在 /Users/jup33q/Documents/kimi/tasks/2026-09-02/09-56-42-fc8077ae/BBoxDesigner 实施多选整体拖动功能。先读 docs/PLAN-multi-drag.md(完整方案:整组统一钳制、组包围盒虚线框、7 条 SelfTest 断言),严格按 §6 顺序实施——先写断言确认"每框独立 clamp 导致贴边变形"的缺陷存在,再重写 EditorState.moveDragged 为组包围盒统一钳制;选择语义(点击组内保持/组外单选/⌘移除)不得回归。完成后跑 `swift build`、`BBoxDesigner --selftest` 全过,最后 scripts/make_app.sh 打包(自动同步桌面)并 git commit + push。

---
