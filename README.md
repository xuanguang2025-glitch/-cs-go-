# PROJECT STRIKE

**原创 5v5 回合制战术竞技第一人称射击游戏（类 CS 爆破玩法）**

> Original 5v5 round-based tactical FPS · one person + AI, zero third-party assets.

![engine](https://img.shields.io/badge/engine-Godot_4.4.1-blue) ![language](https://img.shields.io/badge/language-GDScript-green) ![platform](https://img.shields.io/badge/platform-Windows_x86__64-lightgrey) ![assets](https://img.shields.io/badge/assets-100%25_procedural-orange) ![dev](https://img.shields.io/badge/dev_mode-AI__driven-purple)

PROJECT STRIKE 是一款由**个人开发者 + AI 全流程协作开发**的战术射击游戏：玩法对标《反恐精英》的经典攻防爆破——进攻方（STRIKE）在包点安装目标装置，防守方（GUARD）负责拆除；13 回合半场交换攻防，12:12 进入加时，经济系统管理每一回合的装备购买。

项目基于 **Godot 4.4.1**（纯 GDScript，无 C++/C#），**所有游戏资产均由代码程序化生成**——地图几何、武器视图模型、角色动画、枪声音效（PCM 合成、按命中材质变音高）、UI 与游戏图标——不含任何第三方素材，也不复制任何商业游戏内容。

---

## 为什么值得一看

1. **AI 全流程开发** —— 从架构设计、网络同步、战斗数值到构建发布脚本，整个项目由一个人与 AI 协作完成，全部过程可追溯（见 `docs/` 下的开发记录）。
2. **零第三方资产** —— 四张地图、19 把武器的模型、角色肢体动画、音效、图标全部代码生成，克隆仓库即拥有全部"美术"。
3. **服务器权威架构** —— 联机对战中伤害、命中、经济、回合推进全部在服务端判定，客户端只上报输入意图，从架构层面杜绝"改客户端就能作弊"。
4. **完整的竞技循环** —— 经济系统、购买菜单、Elo 段位、比赛录像回放、观战、反作弊校验一应俱全。

---

## 特性总览

| 系统 | 内容 |
|---|---|
| 玩法 | 5v5 爆破模式：安装 6s → 倒计时 40s → 拆除 7s（拆弹器 4s）；第 13 回合半场交换攻防，12:12 进加时 |
| 武器 | **19 把**：手枪 4 / 冲锋枪 3 / 步枪 4 / 狙击 3 / 霰弹 2 / 轻机枪 2 / 近战 1，全部数据驱动 |
| 投掷物 | 高爆 / 闪光 / 烟雾（体积烟雾参与真实视线遮挡）/ 燃烧 |
| 地图 | 3 张竞技图 + 1 训练场，全部程序化生成 |
| 网络 | ENet 服务器权威 + 客户端预测 + 命中回溯（Lag Compensation）+ 断线重连 |
| 反作弊 | 服务器端移动速度 / 射速校验，客户端伤害上报直接拒绝 |
| 竞技 | MMR 段位系统（Elo K=32，Bronze → Legend 九段位）、连胜加成、比赛结算画面 |
| 经济 | 胜负奖励、连败补偿递增、击杀奖励、安装 / 拆除奖励、8 分类购买菜单 |
| 录像 | 每局自动录制 30Hz 全角色状态 + 击杀事件，回放支持暂停 / 倍速 |
| 联机 | 局域网直连 + 无头专用服务器（`--server`），支持纯观察者模式 |
| 平台 | Windows x86_64 独立 exe（约 95 MB 单文件，双击即玩） |
| Steam | GodotSteam v4.16 集成：成就（6 项）/ 云存档 / Overlay，已实测连接 |

---

## 地图

| 地图 | 风格 | 特色 |
|---|---|---|
| **PROJECT ZERO** | 工业园区（白昼） | 3 Lane + Mid 经典结构，中路狙击通道，木箱 / 集装箱掩体 |
| **NIGHT HARBOR** | 夜间港口 | 集装箱堆场夹道（矮箱可跳上）、码头栈桥、仓库天窗；低照度夜战氛围，暗但不影响辨识 |
| **RED DISTRICT** | 霓虹街区（黄昏） | 商店屋顶可跳上（垂直交火层）、玻璃橱窗可穿射、红 / 青霓虹招牌 |
| **TRAINING RANGE** | 训练场 | 100m 靶道（每 10m 距离标记）、静态假人 + 移动巡逻靶、木 / 玻璃 / 金属 / 混凝土四材质穿透测试墙 |

---

## 快速开始

### 玩游戏

双击项目根目录的 **`play_game.bat`** —— 优先运行 `build/PROJECT_STRIKE.exe` 独立发布版（约 95 MB 单文件，PCK 已嵌入，不依赖 Godot），没有构建产物时自动回退为引擎模式。

> 本仓库只托管源代码（构建产物约 300 MB，已被 `.gitignore` 排除）。克隆后想直接玩，用下面的方式从源码运行，或运行 `build_release.bat` 自行构建 exe。

### 从源码运行

1. 下载 [Godot 4.4.1](https://godotengine.org/download/windows/) 标准版（免安装单文件，约 100 MB）
2. 打开 Godot → Import → 选择本目录的 `project.godot`
3. 按 **F5** 运行

> 无 Steam 环境时游戏自动降级为本地模式（成就 / 云存档不可用，不影响任何玩法）。

### 局域网对战

1. 一台机器主菜单点「**建立主机（局域网）**」——监听 24565 端口自动开局
2. 其他机器（或本机另一实例）点「**加入**」填主机 IP，2 秒内进入对局
3. 加入者自动分配到人数较少的一方，支持对局中途加入

### 操作键位

| 按键 | 动作 |
|---|---|
| W A S D | 移动 |
| Shift | 静步（大幅降低脚步声） |
| Ctrl / C | 蹲下 |
| 空格 | 跳跃 |
| 鼠标左键 / 右键 | 射击 / 开镜 |
| R | 换弹 |
| 1 / 2 / 3 / 4 | 主武器 / 手枪 / 刀 / 投掷物 |
| G / 滚轮 | 循环切换武器 |
| E / F | 安装 / 拆除装置（按住） |
| B | 购买菜单 |
| Tab | 计分板（按住） |
| Esc | 关闭菜单 / 释放鼠标 |

---

## 技术架构（给技术访客）

### 服务器权威网络

- **ENet** 传输，服务器跑完整模拟，客户端只上行输入意图；伤害 / 命中全部在服务端判定，客户端**无法**上报伤害
- **客户端预测（简化版）**：本地角色即时模拟 + 快照校正（偏差 >6m 直接对齐，否则每快照收敛 25%），远端角色 30Hz 快照驱动
- **Lag Compensation（命中回溯）**：服务器保存角色 1 秒 / 60Hz 位置历史，射击按 RTT/2+33ms 回溯判定（上限 250ms），高延迟玩家打移动目标不吃亏
- **反作弊**：移动速度校验（超理论上限 1.6 倍连续 5 次回退位置）、射速校验（±25% 容差）、客户端伤害上报直接拒绝
- **断线重连**：5 分钟窗口内每 3 秒自动重试，角色以新 peer 重新下发
- **专用服务器**：`PROJECT_STRIKE.exe --headless -- --server [--port N] [--bots N] [--map X]` 无 UI 启动；`--bots 0` 纯观察者模式，两队各来 1 人自动开赛

### 战斗系统

- 射线判定"准星指哪打哪"，曳光弹从枪口绘制
- **可学习后坐力**：每把枪有确定性弹道 pattern，压枪手感成立（后坐力归零后准星停在玩家压到的位置）
- 爆头 / 身体 / 腿部独立伤害倍率（如 4.0 / 1.0 / 0.75）、护甲穿透与吸收、距离衰减曲线
- **墙体穿透**四档材质：木 0.70 / 玻璃 0.90 / 金属 0.40 / 混凝土 0.15

### 数据驱动与性能

- 武器全部数值（伤害 / 射速 / 后坐力曲线 / 扩散 / 穿透 / 价格）在 `data/weapons.json`，改数值不动代码，运行时可热重载
- 物理 128Hz；曳光弹 / 弹孔 / 火花 / 弹壳 / 枪口火焰全部走对象池，运行期零分配
- 渲染：Forward+ 管线，TAA + SDFGI 动态全局光照 + BVH 遮挡剔除，四档画质可切换
- 实测（RTX 5060 Laptop / 9 Bot 交战）：三图均值 175–179 FPS（贴 180 vsync 上限），内存工作集稳定 ~530 MB

### 质量保障

无头自动化回归：四张地图完整 Bot 对战 + 五个定向探针（战斗数值 / 装置全流程 / 网络快照同步 / 系统功能 / 核心循环平衡）全部通过。构建产物另有图标逐字节校验、内嵌 PCK 完整性校验、真机冒烟三重自查。详见 [RELEASE.md](RELEASE.md) 与 [docs/DEVELOPMENT_NOTES.md](docs/DEVELOPMENT_NOTES.md)。

---

## 目录结构（精简）

```
PROJECT_STRIKE/
├── project.godot          引擎配置（128Hz 物理 / autoload / 渲染基线）
├── play_game.bat           双击启动游戏（优先发布版 exe）
├── open_editor.bat         打开 Godot 编辑器
├── build_release.bat       一键构建发布版 exe（含图标 / 版本注入）
├── data/
│   ├── weapons.json        19 把武器全部平衡数据
│   └── grenades.json       4 种投掷物数据
├── scripts/                45+ 个 GDScript
│   ├── Core/               GameManager / EventBus / MatchManager / NetworkManager
│   │                       RankSystem / ReplaySystem / AntiCheat / SteamManager
│   ├── Player/             Actor / ActorIntent / PlayerController / RemoteController
│   ├── Weapons/            WeaponSystem（射击 / 后坐力 / 扩散）/ WeaponViewModel
│   ├── Combat/             HitSystem（命中 / 穿透）/ FXManager（对象池）
│   ├── AI/                 BotController（感知 / 决策 / A* 寻路 / 战斗）
│   ├── Maps/               MapBuilder（四张图程序化生成 + 导航图）
│   ├── Network/            LagComp（服务器位置历史回溯）
│   ├── Audio/              AudioForge（PCM 合成）/ SoundManager（3D 播放）
│   └── UI/                 HUD / BuyMenu / MainMenu / Scoreboard / MatchResult ...
├── scenes/                 Main / Game / MainMenu / ReplayViewer / Dev 探针场景
├── docs/                   开发文档（DEVELOPMENT_NOTES.md / CORE_LOOP_REBALANCE.md）
└── RELEASE.md             发布手册（构建链路 / Steam 接入 / 发布检查清单）
```

---

## 开发状态

当前基线 **v1.2.0.16** + 持续迭代（近期落地：射击手感再平衡、屏幕目标标识、程序化人物重做、A1 画质升级）。游戏已完整可玩，仍在开发完善阶段。

**已实现**：5v5 完整对局 / 19 武器 / 4 地图 / 局域网与专用服务器 / 段位与录像 / 反作弊 / Steam 集成

**计划中**：

- 跨网匹配服务器与账号系统（当前为接口对齐的本地匹配）
- 商城与皮肤（纯视觉，不影响平衡）

**刻意不做**：第三方美术资源与骨骼动画（保持零外部依赖的项目特色）

---

## 关于这个项目

本项目是「一个人 + AI」开发模式的完整实践：没有团队、没有美术外包、没有购买任何素材，从第一行代码到可独立运行的 exe，全部由个人开发者与 AI 协作完成。

- GitHub：<https://github.com/xuanguang2025-glitch/-cs-go->
- Gitee：<https://gitee.com/xuanguang2025/xuhaoran>

更多开发过程记录见 [docs/DEVELOPMENT_NOTES.md](docs/DEVELOPMENT_NOTES.md)，构建与 Steam 发布细节见 [RELEASE.md](RELEASE.md)。
