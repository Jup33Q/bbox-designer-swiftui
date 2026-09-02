# 激活提示词(Smart Align 实施)

把下面这段粘给新会话即可开工(它会自己读 plan 和代码):

---

在 /Users/jup33q/Documents/kimi/tasks/2026-09-02/09-56-42-fc8077ae/BBoxDesigner 实施智能对齐吸附功能。先读 docs/PLAN-smart-align.md(完整方案:候选线、阈值、参考线绘制、NSHapticFeedbackManager 触觉反馈、测试清单),严格按 §6 顺序实施;再读 Sources/BBoxDesigner/EditorState.swift 的 moveDragged/resizeDragged/endDrag 和 CanvasView.swift 的 canvasContent 了解现有手势管线。完成后跑 `swift build`、`BBoxDesigner --selftest`(含新增 7 条吸附断言须全过),最后 scripts/make_app.sh 打包(会自动同步桌面)并 git commit + push。

---
