# Changelog

All notable changes to **Tension HUD** are documented here.
关于本项目的所有重要变更都记录在此文件。

---

## v1.0.0 — First stable release · 首个正式版 (2026-11-12)

### Added · 新增

- Real-time display of the hidden **Tension** score (−100 … +100, one decimal)
  实时显示隐藏的 **Tension（受压评分）**：−100 ~ +100，一位小数
- **Six semantic tiers** with short captions: 从容 / 沉稳 / 相持 / 吃紧 / 失措 / 难支
  六档语义化档位，各配四字短评
- **30-second smoothed score curve**, trend (Δ/s) and 10-second peak
  30 秒平滑曲线、趋势（每秒变化）与 10 秒峰值
- **Four combat dimensions**: Defense / Dodge / Offense / Rhythm
  四维：防御 / 闪避 / 进攻 / 节奏
- **Live event feed** — one line per action: score · event name · base weight, 6 rows on screen
  战况事件流：每个动作一行（分值 / 事件名 / 基础权重），同屏 6 行
- **20-entry base weight table** with pagination (`F8` / `F9`)
  20 条基础权重表，支持分页
- Player & boss health bars
  玩家 / BOSS 双层血条
- Environment self-check script (`检查环境.bat`) in the release package
  发布包内置环境自检脚本

### Design · 视觉

- Chinese ink-and-gold visual language matching the game's native UI
  中式墨金风格，与游戏原生 UI 同源
- Brush calligraphy font (Ma Shan Zheng) for titles and tier words
  标题与档位词使用马善政楷书
- Text rendered at native device resolution — no blurry upscaling
  文字按设备像素直出，小字号清晰不发虚
- Adaptive panel opacity sampled from the scene behind it
  面板半透明背景按场景明暗自适应

### Stability · 稳定性

- Single-instance lock; overlay exits automatically when the game closes
  单实例锁；游戏退出后覆盖层自动结束
- `eof` sentinel protects against torn state-file writes
  `eof` 哨兵：状态文件撕裂写入时保留上一帧
- Fight-id tracking clears the event feed and chart at the start of every fight
  场次计数：每场战斗开始自动清空战况与曲线
- Heartbeat file + `F10` manual restart; no background polling, no console windows
  心跳文件 + F10 手动重启；无后台轮询、无控制台弹窗

### Fixed · 修复

- Event rows were inserted twice per action (duplicate lines)
  修复战况事件被重复插入两行
- `evseq` fingerprint used a memory address, causing missed or duplicated rows
  修复 evseq 指纹使用内存地址导致的漏行/刷屏
- Stale event rows remained after a fight ended
  修复战斗结束后战况残留旧行
- Flicker caused by time-based row expiry
  修复基于时间过期的行删除导致闪烁
- `F7` / `F10` could silently stop working when the boot sequence was incomplete
  修复启动序列缺失导致快捷键失效

### Known limitations · 已知限制

- The weight table shows **base weights**, not the final values after multipliers
  权重表显示基础权重，不含乘数结算后的最终值
- Stance / health dimensions are not exposed by the engine and are not displayed
  架势 / 血量维度引擎未暴露，不显示
- Borderless fullscreen / windowed mode only
  仅支持无边框全屏 / 窗口模式

---

## Earlier versions · 早期测试版

| Version | Milestone · 里程碑 |
|---|---|
| 0.1.x | Initial: score / tier / event stream |
| 0.9.0 | Weight table, dimension values, boss name resolution |
| 1.x | Native-style UI, health reading, Chinese boss names, weight pagination |
| 2.0–2.3 | Device-pixel text rendering, ink-seal tier block, per-event feed, self-healing |
| 2.4–2.5 | QA fixes: clearing logic, event fingerprint, torn-write guard, fight id, reference-style three-column layout |
