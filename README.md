# PROJECT STRIKE

原创 5v5 回合制战术竞技第一人称射击游戏。
**引擎：Godot 4.4.1 stable（GDScript） + GodotSteam v4.16（Steamworks 1.62）**

所有资产（地图、武器模型、音效、UI、图标、角色动画）均由代码程序化生成，
不含任何第三方素材，也不复制任何商业游戏的内容。

| | |
|---|---|
| 玩法 | 5v5 回合制战术竞技（进攻方安装装置 / 防守方拆除） |
| 地图 | 3 张竞技图 + 1 个训练场，全部程序化生成 |
| 武器 | 19 把，数据驱动（`data/weapons.json`） |
| 联机 | ENet 服务器权威 + 客户端预测 + Lag Compensation |
| 平台 | Windows x86_64，已导出独立 exe；Steam 集成实测通过 |

---

## 一、为什么是 Godot 而不是 UE5

原始需求首选 Unreal Engine 5。实际环境扫描结果：

| 项目 | 实测 |
|---|---|
| C 盘可用空间 | **18 GB（已用 95%）** |
| D 盘可用空间 | 415 GB |
| 已装引擎 | 无（UE / Unity / Godot 都没有） |
| 已装工具链 | 无 Visual Studio、无 .NET SDK |
| CPU | 32 线程 |

UE5 的问题：引擎本体 40–60 GB，且 **VS2022 无论装到哪个盘都会强制往 C 盘塞 6–8 GB**，
18 GB 的 C 盘几乎必然安装失败。即便勉强装上，C++ 单次编译数分钟 + 首次 shader 编译近 1 小时，
与"小步迭代、每阶段可运行"的开发方式直接冲突。

Unity 6 需要下载 Hub + Editor（15–20 GB）并登录 Unity ID 激活许可证。

**最终选择 Godot**：单文件 57 MB、免安装、免账号、GDScript 修改后即时生效。
其内置物理、射线检测、GPU 粒子、空间音频完全够用，架构上也原生支持
Client-Server 与 headless 导出（为后续 Dedicated Server 留好口子）。

> 这一选择对应需求第 71 条"如环境更适合则替换并说明原因"与第 73 条"功能等价替代方案"。

**后又从 4.3 升到 4.4.1**：GodotSteam 的 Godot 4.x 预编译版本从 v4.13 起才有，
且按小版本精确匹配（v4.16 → `g441` 对应 4.4.1）。4.3 没有可用的 Steam 模板，
所以引擎整体升到 4.4.1 并做了全量回归（4 图 + 战斗 + 装置），零破坏。

---

## 二、当前状态：MVP 完整可玩

四张地图全部通过无头回归（2026-08-31，Godot 4.4.1 + GodotSteam）：

| 地图 | 导航图 | 结果 | 开火 / 命中 | 投掷物 |
|---|---|---|---|---|
| PROJECT ZERO | 42 节点 / 62 边 | ✅ PASS（打完第 2 回合，0:1） | 183 / 18（9.8%） | 8 |
| NIGHT HARBOR | 42 节点 / 73 边 | ✅ PASS（打完第 2 回合，0:1） | 273 / 26（9.5%） | 9 |
| RED DISTRICT | 42 节点 / 121 边 | ✅ PASS（打完第 2 回合，0:1） | 211 / 15（7.1%） | 9 |
| TRAINING RANGE | — | ✅ PASS（训练模式） | 61 / 8（13.1%） | — |

> 自检脚本 `TestBoot.gd` 按**真实时长**预算（210s）而非固定帧数：
> 无头模式帧率随机器在 100~400fps 浮动，帧数固定会导致快机器上回合还没打完就收尾、
> 慢机器上白等——改成"打完第 2 回合或超时即收尾"后才稳定复现。

**五个定向探针全部通过**（2026-08-31 复测）：

| 探针 | 覆盖 | 结果 |
|---|---|---|
| `CombatProbe` | 命中 / 爆头 / 腿部 / 护甲 / 距离衰减 / 武器差异 / 穿透 | ✅ 9/9 OK |
| `PlantProbe` | 装置分配 → 进入点位 → 安装 6s → 倒计时 → 拆除 | ✅ PASS |
| `NetProbe` | 双进程建房/加入，角色下发与快照同步 | ✅ PASS（10 角色下发） |
| `SysProbe` | 设置持久化 / 录像录制回放 / 段位 Elo / 武器数据完整性 | ✅ 17/17 OK |
| `TestBoot` | 四图完整比赛 | ✅ 4/4 PASS |

**战斗系统定向测试明细**（`scenes/Dev/CombatProbe.tscn`）：

| 用例 | 结果 |
|---|---|
| 基础命中（15m 胸口，P01） | 27.5 伤害 |
| 爆头 vs 腿部倍率 | 100.0 vs 20.6（比值 4.85） |
| 护甲吸收 | 27.5 → 16.2，护甲消耗至 86 |
| 距离衰减 | 8m 28.0 → 30m 14.8 |
| 武器差异 | AR-17 36.0 vs Vector-X 21.0 |

### 已实现（对照需求第 51 条 MVP 清单）

- **3 张竞技地图 + 训练场**（主菜单地图选项切换）：
  - **PROJECT ZERO** 工业园区：3 Lane + Mid，中路狙击通道，木箱/集装箱掩体
  - **NIGHT HARBOR** 夜间港口：集装箱堆场夹道（矮箱可跳上）+ 码头栈桥 + 仓库天窗，
    低照度夜间 + 冷月光 + 暖色吊灯，暗但有氛围、不黑到看不见人
  - **RED DISTRICT** 霓虹街区：商店屋顶可跳上（垂直交火层）+ 公寓楼 lane 分隔 +
    地铁入口亭 + 玻璃橱窗穿射 + 红/青霓虹招牌，黄昏橙色夕阳
  - **TRAINING RANGE** 训练场：100m 靶道（每 10m 距离标记）、3 静态假人 + 2 左右巡逻移动靶、
    木/玻璃/金属/混凝土四材质穿透测试墙；无回合推进、假人 2.5 秒自动复活、备弹无限、
    B 键随时换枪
- 两阵营 STRIKE（进攻）/ GUARD（防守），第 13 回合半场交换，12:12 进加时
- 5v5：玩家 1 人 + Bot 9 人
- **19 把武器**（4 手枪 / 3 冲锋枪 / 4 步枪 / 3 狙击 / 2 霰弹 / 2 轻机枪 / 1 近战），全部数据驱动
- 射击：Hip Fire / ADS、半自动 / 三连发 / 全自动 / 栓动 / 泵动
- **可学习后坐力曲线**（每把枪有确定性 pattern，压枪手感成立）
- 爆头 / 身体 / 腿部独立倍率、护甲穿透与吸收、距离衰减
- **墙体穿透**（木 0.70 / 玻璃 0.90 / 金属 0.40 / 混凝土 0.15 四档材质）
- 4 种投掷物：高爆 / 闪光 / 烟雾（体积烟雾，参与真实视线遮挡）/ 燃烧
- 目标装置：携带 → 安装 6s → 40s 倒计时 → 拆除 7s（拆弹器 4s）
- 经济系统：胜负奖励、连败补偿递增、击杀奖励、安装/拆除奖励
- 购买菜单（8 分类、数字键快捷购买、复购上次装备）
- 观战（死亡后自动跟随队友第一人称）、小地图、击杀信息流、计分板
- 程序化音效（枪声/脚步/换弹/爆炸全部由代码合成 PCM，按材质改变音高）

### 联机与竞技系统（阶段 16-19、21、25、37-38）

- **网络架构（服务器权威）**：ENet，服务器跑完整模拟，客户端只上行输入意图，
  伤害/命中全部服务器判定（客户端根本无法上报伤害）
- **Client Prediction 简化版**：本地角色即时模拟 + 快照校正（偏差 >6m 直接对齐，
  否则每快照收敛 25%）；远端角色 30Hz 快照驱动
- **断线与晚加入**：晚加入的玩家会收到对局中全部角色（含 Bot）的补发
- **反作弊校验（服务器端）**：移动速度校验（超理论上限 1.6 倍连续 5 次回退位置）、
  射速校验（fire_interval 容差 25%）、客户端伤害上报直接拒绝
- **局域网对战**：主菜单「建立主机」开 24565 端口，「加入」填 IP 直连；
  加入者自动进入人数较少的一方
- **匹配系统**：第一阶段假匹配（匹配面板 1.2~2.4s 后本地开局，接口与真实匹配一致）
- **段位系统**：MMR(初始 1000, Elo K=32) + 九段位 Bronze→Legend，连胜小额加成，
  本地持久化 user://rank.json，比赛结束自动结算
- **结算画面**：比赛结束展示胜负/比分/双方 K·D·A·伤害/命中率/MMR 变化，任意键返回
- **Lag Compensation（命中回溯）**：服务器保存角色 1 秒位置历史，射击按 RTT/2+33ms
  回溯判定，高延迟玩家打移动目标不再吃亏（上限 250ms 防异常客户端）
- **Demo 录像/回放**：每局自动录制 30Hz 全角色状态 + 击杀事件，结束后存
  user://replays/；主菜单「观看上一局录像」回放，支持暂停/倍速
- **断线重连**：客户端 5 分钟窗口内每 3 秒自动重试，重新下发角色
- **专用服务器**：`-- --server [--port N] [--bots N] [--map X]` 无 UI 启动。
  `--bots 0` 为纯观察者模式 —— 不生成任何 Bot，停在「热身等待」等玩家连入，
  **两队各够 1 人自动开赛**（详见 `RELEASE.md` 第 2 节）
- **程序化角色动画**：走/跑摆腿摆臂、空中张腿、蹲伏持枪姿态，无需任何骨骼模型资源

---

## 三、运行方式

### 最简单
双击项目根目录下的 **`play_game.bat`** 直接开始游戏。它优先跑
`build\PROJECT_STRIKE.exe`（独立发布版，不依赖 Godot），没有构建产物时
才退回用 `.tools` 里的引擎跑工程。

需要改代码或导出时用 **`open_editor.bat`** 打开 Godot 编辑器；
`run_game.bat` 则是强制走引擎运行（调试用）。

### 打出可分发的 exe
双击 **`build_release.bat`**（或 `build_release.bat 1.2.0.0` 指定版本）。
产物在 `build/`，单文件、PCK 已嵌入、已注入图标与版本信息。详见 `RELEASE.md`。

> 构建脚本会在改 PE（注入图标/版本号）前后自动备份并还原内嵌 PCK。
> 这一步不能省：**rcedit 2.0.0 会抹掉 Godot 追加在 exe 尾部的内嵌包**，
> 而且文件体积一字节不变、图标和版本号都注入成功，只有真跑一次才会暴露
> `Couldn't load project data at path "."`。详见 `RELEASE.md` 第 1.1b 节。

构建完建议跑一遍自查（详见 `RELEASE.md` 第 1.3 节）：

```bash
python verify_exe.py                                   # 图标 6/6 + 版本信息 + Steam 运行时
python overlay_tool.py check build\PROJECT_STRIKE.exe  # 内嵌 PCK 完整性
python smoke_test.py --mode windowed --seconds 15      # 真跑一次, 抓启动日志
```

### 局域网对战
1. 一台机器点「建立主机 (局域网)」，自动开局并监听 24565 端口
2. 另一台机器(或本机另一个实例)填 IP 点「加入」，2 秒内进入对局
3. 加入者自动分配到人数较少的一方；晚加入也能看到全部 Bot

### 命令行
```bash
# 直接运行
Godot.exe --path . --resolution 1600x900

# 打开编辑器
Godot.exe --editor --path .

# 无头自检（跑完整 Bot 对战, 打完第 2 回合自动收尾并输出统计）
Godot.exe --headless res://scenes/Dev/TestBoot.tscn -- --map project_zero
# --map 可选: project_zero / night_harbor / red_district / training_range

# 战斗系统定向测试（命中/爆头/护甲/衰减/穿透，9 项）
Godot.exe --headless res://scenes/Dev/CombatProbe.tscn --quit-after 400

# 装置全流程（分配 → 进入点位 → 安装 → 倒计时 → 拆除）
# 注意: 安装要 6 秒, --quit-after 必须 >=9000, 否则会在安装中途被掐断
Godot.exe --headless res://scenes/Dev/PlantProbe.tscn --quit-after 9000

# 系统功能测试（设置持久化 / 录像 / 段位 / 武器数据, 17 项）
Godot.exe --headless res://scenes/Dev/SysProbe.tscn

# 网络快照同步（双进程: 先起 host, 再起 join）
# 可选 --port N / --bots N / --waits N; 加 --dedicated 走 host_dedicated()
Godot.exe --headless res://scenes/Dev/NetProbe.tscn -- --host
Godot.exe --headless res://scenes/Dev/NetProbe.tscn -- --join

# 装置链路诊断 / 攻防平衡测试台（纯 AI 5v5, 无本地玩家, 输出 T1~T4 判定）
# --aionly 走专用服务器分支: 只有 10 个 Bot, 没有"永不死亡的本地木桩"干扰
Godot.exe --headless res://scenes/Dev/BombTraceProbe.tscn -- --map project_zero --rounds 6 --aionly

# 纯观察者服务器: 0 Bot, 等两队各来 1 人自动开赛
Godot.exe --headless res://scenes/Dev/NetProbe.tscn -- --dedicated --bots 0 --port 24574
```

五个探针都会自行调用 `get_tree().quit()`，`--quit-after` 只是防挂死的兜底。
（CombatProbe / PlantProbe 需要 `--quit-after`，其余靠自身逻辑结束。）

引擎位置（相对项目目录 `../.tools/`）：

| 文件 | 用途 |
|---|---|
| `GodotSteam_Editor.exe` | 带 Steamworks 的定制编辑器，开发/导出/测试默认用它 |
| `Godot441.exe` | 官方 4.4.1，无 Steam 环境下的回退引擎 |
| `Godot.exe` | 最初的 4.3，仅作兜底 |

---

## 四、操作

| 按键 | 动作 |
|---|---|
| W A S D | 移动 |
| Shift | 静步（大幅降低脚步声） |
| Ctrl / C | 蹲下 |
| 空格 | 跳跃 |
| 鼠标左键 | 射击 |
| 鼠标右键 | 开镜 |
| R | 换弹 |
| 1 / 2 / 3 / 4 | 主武器 / 手枪 / 刀 / 投掷物 |
| G / 滚轮 | 循环切换武器 |
| E / F | 安装 / 拆除目标装置（按住） |
| B | 购买菜单（训练场中随时可用） |
| Tab | 计分板（按住） |
| Esc | 关闭菜单 / 暂停 |

---

## 五、目录结构

```
PROJECT_STRIKE/
├── project.godot              项目配置（128Hz 物理、自动加载、物理层命名）
├── play_game.bat              ★ 启动游戏（优先发布版 exe，无产物时退回引擎）
├── run_game.bat               强制用引擎运行工程（调试用）
├── open_editor.bat            打开编辑器
├── build_release.bat          一键构建发布版（导出 + 图标/版本注入 + Steam 运行时）
├── build_release.ps1          构建脚本本体（含内嵌 PCK 保护）
├── verify_exe.py              产物自查：图标 6/6、版本信息、Steam 运行时
├── overlay_tool.py            内嵌 PCK 的备份 / 还原 / 完整性校验
├── smoke_test.py              把发布版 exe 真跑一次并抓启动日志
├── export_presets.cfg         Windows 导出预设
├── steam_appid.txt            Steam AppID（当前 480 测试值）
├── icon/                      game.ico（六尺寸）/ icon_256.png，程序化生成
├── data/
│   ├── weapons.json           19 把武器的全部平衡数据
│   └── grenades.json          4 种投掷物数据
├── scripts/                   45 个 GDScript
│   ├── Core/          GameManager(全局) EventBus(信号总线) MatchManager(回合状态机)
│   │                  GameRoot(场景装配) SpectatorSystem(观战)
│   │                  NetworkManager(ENet 服务器权威) RankSystem(MMR 段位)
│   │                  AntiCheat(服务器校验) ReplaySystem(录像录制/回放)
│   │                  SteamManager(Steam 集成: 成就/云存档/Overlay)
│   ├── Data/          GameConfig(常量+输入注册) WeaponDatabase(JSON 加载)
│   ├── Player/        Actor(角色本体) ActorIntent(意图) HealthComponent Loadout
│   │                  PlayerController(输入→意图) RemoteController(远端玩家)
│   ├── Weapons/       WeaponSystem(射击/后坐力/扩散/换弹) WeaponViewModel(程序化枪模)
│   ├── Combat/        HitSystem(命中/穿透) FXManager(特效对象池)
│   ├── Grenades/      GrenadeManager GrenadeBase SmokeVolume FireZone
│   ├── Objectives/    BombSite ObjectiveSystem(装置全流程)
│   ├── AI/            BotController(感知/决策/A*寻路/战斗)
│   ├── Economy/       EconomyManager
│   ├── Maps/          MapBuilder(四张图程序化生成 + 导航图)
│   ├── Network/       LagComp(服务器位置历史回溯)
│   ├── Audio/         AudioForge(PCM 合成) SoundManager(3D 播放 + 对象池)
│   ├── UI/            HUD HudCanvas(准星/小地图) BuyMenu Scoreboard MainMenu
│   │                  MatchResult(结算) ReplayViewer(回放)
│   └── Dev/           TestBoot(无头自检) CombatProbe PlantProbe NetProbe
└── scenes/            Main.tscn MainMenu.tscn Game.tscn ReplayViewer.tscn Dev/ Map/ ...
```

---

## 六、架构要点

### 1. ActorIntent：玩家 / Bot / 网络共用一条代码路径
输入不直接改角色状态，而是先写入 `ActorIntent`（移动、视角、开火、换弹……）。
`Actor` 在物理帧开头调用各 controller 的 `poll()` 采样，再统一消费。
好处：移动和射击逻辑只有一份，Bot 和真人走完全相同路径，将来接网络时
远端玩家只需把 intent 传过来即可。

### 2. 服务器权威式命中检测
`HitSystem` 用相机中心射线做判定（"准星指哪打哪"），曳光弹从枪口绘制。
射线逐段推进实现穿透：命中角色继续飞（伤害递减），命中墙体按材质扣穿透力，
扣光即停。全部判定集中在服务端，客户端只提交意图。

### 3. 后坐力是"叠加在视角上的偏移量"
开枪时 `recoil_pitch/yaw` 累积，停止射击后平滑归零。
玩家下拉鼠标改变的是 `base_pitch` —— 后坐力归零后准星停在玩家压到的位置，
这就是标准"压枪"手感的成因，也让后坐力曲线可以被学习和记忆。

### 4. 数据驱动
武器伤害、射速、价格、后坐力曲线、扩散、穿透全部在 `data/weapons.json`。
改数值不需要动代码，运行时可热重载（`WeaponDatabase.load_all()`）。

### 5. 性能
物理 128Hz；所有临时对象（曳光弹/弹孔/火花/弹壳/枪口火焰）走对象池，运行期零分配；
特效放在独立 visual layer，主光源 cull mask 排除它，不参与光照与阴影计算。

---

## 七、已知问题与下一步

**已修复的关键 Bug（记录以便回溯）**
- 子弹射线掩码原含 `LAYER_PLAYER`，导致射线先命中角色物理胶囊（无 `hit_group` 元数据）
  被当成混凝土墙处理，穿透力瞬间耗尽 —— 表现为"子弹永远打不中人"。
  现改为 `LAYER_WORLD | LAYER_HITBOX`。
- `String(bool)` 在 Godot 4 无对应构造函数，统一改用 `str()`。
- `PlaneMesh` 枚举是 `FACE_X/Y/Z` 而非 `FACING_*`。
- `GeometryInstance3D.SHADOW_CASTING_SETTING_OFF` 在 4.3 会中断脚本，改用渲染层隔离。
- 无头自检原按固定 8500 帧收尾，但一个回合约需 135 秒，快机器上会误报
  "回合未推进"。现改为真实时长预算（210s）+ 打完第 2 回合即收尾。
- GodotSteam 4.x 的 `steamInit()` 返回 `bool`（旧版返回 Dictionary），
  按旧写法赋值会直接抛类型错误，现用 `Variant` + 类型分支兼容。
- 无 Steam 引擎里 `Engine.get_singleton("Steam")` 会刷
  `Failed to retrieve non-existent singleton`，改用 `Engine.has_singleton()` 先判断。

**已知限制**
- 无头模式下（`--headless`）会有 `mesh_get_surface_count` 的 dummy 渲染驱动告警，
  不影响任何游戏逻辑；窗口模式（真实 Vulkan 驱动）下不出现。
- 体积烟雾在无头模式下不生成 GPU 粒子（dummy 驱动不支持），但遮挡与生命周期逻辑完整。
- ~~Bot 命中率 7%~13%，属于"普通偏弱"水平~~
  **已修复（2026-09-12）**：根因是 `_burst_remaining` 按帧递减（4~9 帧短于
  `fire_interval`，每次扳机只出 1 发）+ 14m 内强制腰射。改为按发计数 +
  步枪全程开镜 + 「停住射击/间隙推进」后，命中率 17.8%~18.8%。
- ~~Bot 在 `TestBoot` 里几乎不安装装置（实测 0 次）~~
  **已修复（2026-09-12）**：三个叠加根因 —— 携带者被"跟随队尾"逻辑锁死在
  点位之外、装置掉落后 `_am_nearest_to` 无人响应、`_navigate` 到达半径 2.2m
  大于拾取半径 1.1m（去捡也捡不到）。修复后纯 AI 5v5 下携带者 5/6 回合进点、
  安装 2~4 次、掉落回收 4/5。详见 `docs/CORE_LOOP_REBALANCE.md`。
  注意：`TestBoot` 里本地玩家是一个不移动也不死亡的木桩，会把回合结束原因
  扭曲成"时间耗尽" —— 测核心循环请用 `BombTraceProbe --aionly`。
- 导出时 Godot 自带的 rcedit 调用在中文路径下会失败，已把 rcedit 放到
  `C:\GodotTools\` 并在编辑器设置里指定路径；`build_release.bat` 里还有一道兜底注入。

**已完成（原"尚未实现"清单中的条目，现全部落地）**

| 原条目 | 现状 |
|---|---|
| Lag Compensation（回溯命中） | ✅ `scripts/Network/LagComp.gd`，服务器存 1s/60Hz 位置历史，按 RTT/2+33ms 回溯，上限 250ms |
| Dedicated Server | ✅ `--headless -- --server [--port N] [--bots N] [--map X]`，带 Bot 模拟 + 客户端加入 |
| 纯观察者（无 Bot）模式 | ✅ `--bots 0`，停在 `热身等待`，两队各够 1 人自动开赛 |
| 断线重连 | ✅ 客户端 5 分钟窗口、每 3 秒重试，重新下发角色 |
| 训练场与靶场 | ✅ TRAINING RANGE：100m 靶道、静/动靶、四材质穿透测试墙 |
| 录像回放（Demo Replay） | ✅ `ReplaySystem` 30Hz 录制，`ReplayViewer.tscn` 暂停/倍速回放 |
| 反作弊框架 | ✅ `AntiCheat.gd` 服务器端速度/射速校验，客户端伤害上报直接拒绝 |
| 角色动画 | ✅ 程序化肢体动画（走跑摆腿摆臂 / 空中 / 蹲伏 / 持枪），无骨骼资源 |
| Steam 集成 | ✅ 成就 / 云存档 / Overlay，实测连上账号；AppID 待换正式值 |

**仍未实现**

- 跨网匹配服务器与账号数据库（当前匹配是本地假匹配，接口已对齐真实匹配）
- 商城与皮肤（纯视觉，不影响平衡）
- 骨骼动画与第三方美术资源（本项目刻意保持零外部资源）

---

## 八、修改平衡数据

编辑 `data/weapons.json` 后重启即可生效。常用字段：

```jsonc
"ar17": {
  "damage": 36,              // 基础伤害
  "rpm": 600,                // 射速
  "recoil_pattern": [[yaw, pitch], ...],   // 每发后坐力偏移(度), 超出后循环末 6 发
  "spread_hip": 3.4,         // 腰射扩散(度)
  "spread_ads": 0.22,        // 开镜扩散
  "penetration_power": 1.2,  // 穿透力(可穿过的材质成本总和)
  "headshot_mult": 4.0,      // 爆头倍率
  "armor_penetration": 0.70, // 护甲穿透
  "range_falloff": [[0,1.0],[20,1.0],[40,0.95],[70,0.85]]  // 距离衰减曲线
}
```

地图布局改 `scripts/Maps/MapBuilder.gd` 顶部的 `WALLS` / `COVERS` / `WAYPOINTS` 常量
（修改路点后导航图会在启动时按距离 + 视线可达性自动重算连边）。
