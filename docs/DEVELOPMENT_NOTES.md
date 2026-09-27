# PROJECT STRIKE

原创 5v5 回合制战术竞技第一人称射击游戏。
**引擎：Godot 4.4.1 stable（GDScript） + GodotSteam v4.16（Steamworks 1.62）**

所有资产（地图、武器模型、音效、UI、图标、角色动画）均由代码程序化生成，
不含任何第三方素材，也不复制任何商业游戏的内容。

| | |
|---|---|
| 玩法 | 5v5 回合制战术竞技（进攻方安装装置 / 防守方拆除） |
| 地图 | 3 张竞技图 + 1 个训练场，全部程序化生成 |
| 武器 | 22 把，数据驱动（`data/weapons.json`） |
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

**七个定向探针全部通过**（2026-09-27 复测，OK 数为实测断言条数）：

| 探针 | 覆盖 | 结果 |
|---|---|---|
| `CombatProbe` | 命中 / 爆头 / 腿部 / 护甲 / 距离衰减 / 武器差异 / 穿透 / 准星忠实度 | ✅ 52/52 OK |
| `PlantProbe` | 装置分配 → 进入点位 → 安装 6s → 倒计时 → 拆除 | ✅ 4/4 OK |
| `NetProbe` | 双进程建房/加入，角色下发与快照同步 | ✅ PASS（10 角色下发） |
| `SysProbe` | 设置持久化 / 录像录制回放 / 段位 Elo / 武器数据完整性 | ✅ 19/19 OK |
| `TestBoot` | 四图完整比赛 | ✅ 4/4 PASS |
| `ShopProbe` | 商城数据完整性 / 经济闭环 / 开箱概率与保底 / 库存与货币 / 多玩家 profile 隔离 / RPC 伪造防护 / Steam 适配器降级 | ✅ 117/117 OK |
| `UIProbe` | 商城界面结构 / 页签 / 筛选 / 3D 预览 / 动作按钮 / 主菜单入口接线 | ✅ 47/47 OK |

> `ShopProbe` 与 `UIProbe` 全程把后端指向独立测试存档
> （`use_local_save_at()`），跑完即删，不会污染 `user://` 下的玩家真实库存与装备档。

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
- **22 把武器**（4 手枪 / 4 冲锋枪 / 5 步枪 / 4 狙击 / 2 霰弹 / 2 轻机枪 / 1 近战），全部数据驱动
- **5 种投掷物**（高爆 / 闪光 / 烟雾 / 燃烧 / 撞击引爆）
- 射击：Hip Fire / ADS、半自动 / 三连发 / 全自动 / 栓动 / 泵动
- **可学习后坐力曲线**（每把枪有确定性 pattern，压枪手感成立）
- 爆头 / 身体 / 腿部独立倍率、护甲穿透与吸收、距离衰减
- **墙体穿透**（木 0.70 / 玻璃 0.90 / 金属 0.40 / 混凝土 0.15 四档材质）
- 5 种投掷物：高爆 / 闪光 / 烟雾（体积烟雾，参与真实视线遮挡）/ 燃烧 / 撞击引爆
- 目标装置：携带 → 安装 6s → 40s 倒计时 → 拆除 7s（拆弹器 4s）
- 经济系统：胜负奖励、连败补偿递增、击杀奖励、安装/拆除奖励
- 购买菜单（8 分类、数字键快捷购买、复购上次装备）
- **商城与皮肤**（纯视觉）：四档稀有度 / 武器与角色皮肤 / 补给箱开箱（地板线 + 保底双线）
  / 双轨货币（技能点 + 钻石）/ 重复外观折算积分 / 外观随角色同步给其他玩家
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
双击 **`build_release.bat`** 即可，版本号默认取根目录 `VERSION` 文件；
需要临时覆盖时才传参（如 `build_release.bat 1.2.0.0`）。
`verify_exe.py` 的期望版本同样读 `VERSION`，所以升版本只改这一个文件。
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

七个探针都会自行调用 `get_tree().quit()`，`--quit-after` 只是防挂死的兜底。
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
│   ├── weapons.json           22 把武器的全部平衡数据
│   ├── grenades.json          5 种投掷物数据
│   ├── rarity_tiers.json      稀有度四档（颜色 / 掉落权重）
│   ├── skins/                 weapon_skins / character_skins / accessories / effects
│   └── shop/                  currency_config / loot_boxes / store_catalog
├── scripts/                   65 个 GDScript
│   ├── Core/          GameManager(全局) EventBus(信号总线) MatchManager(回合状态机)
│   │                  GameRoot(场景装配) SpectatorSystem(观战)
│   │                  NetworkManager(ENet 服务器权威) RankSystem(MMR 段位)
│   │                  AntiCheat(服务器校验) ReplaySystem(录像录制/回放)
│   │                  SteamManager(Steam 集成: 成就/云存档/Overlay)
│   ├── Data/          GameConfig(常量+输入注册) WeaponDatabase(JSON 加载)
│   ├── Shop/          SkinDatabase(外观/商城数据加载) InventoryService(后端选择)
│   │                  CurrencyManager(双轨货币) ShopManager(业务编排 + 路由)
│   │                  ShopProfile(按玩家分档的库存/余额/保底/装备)
│   │                  LootBoxResolver(概率与保底, 纯静态可复现)
│   │                  LoadoutCosmetics(外观装备态)
│   │                  IInventoryBackend + LocalInventoryAdapter + SteamInventoryAdapter
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
│   │                  MatchResult(结算) ReplayViewer(回放) ShopUI(商城界面)
│   └── Dev/           TestBoot(无头自检) CombatProbe PlantProbe NetProbe
│                      SysProbe ShopProbe UIProbe
└── scenes/            Main.tscn MainMenu.tscn Game.tscn ReplayViewer.tscn
                       Dev/ Map/ UI/(ShopUI.tscn) ...
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

### 6. 商城：状态按玩家分档，而不是按进程分档
`SkinDatabase` / `ShopManager` 等虽然是 autoload，但**库存、余额、保底计数、已装备外观
并不存在单例里**，而是收在 `ShopProfile`（一个玩家一份）。业务方法一律是
`purchase_entry_for(profile, ...)` / `unbox_for(profile, ...)` 这种显式带 profile 的形式，
不带 profile 的旧签名只是"本机玩家"的糖。

这么设计是为了堵一个很隐蔽的坑：如果服务器直接读写"本机那一份"状态，
它拿**自己**的钱包去校验**别人**的购买，RPC 在、返回值在、日志也漂亮，
但校验完全无效。所以 `server_shop_action()` 里的身份永远来自
`multiplayer.get_remote_sender_id()`，客户端在参数里自称"我是 7001"没有任何意义。

远端 profile 落盘在 `user://shop_profiles/<key>.json`，key 优先用 SteamID
（peer id 重连会变，只有 SteamID 能跨局认人）。

### 7. 商城：为什么购买要"先扣钱再发货"
`_route` / `purchase_entry_for` 里顺序是固定的：**扣款 → 发货 → 发货失败立即退款**。
反过来（先发货再扣款）会在扣款失败时留下白送的物品，而那种数据不一致是安静的、
不会被任何断言立刻抓到。同理，开箱先摇一次确认能出货再扣钱，避免配置坏掉时白扣一次。

两条相关不变量：
- **保底计数必须持久化**（跟库存同档）。它只在内存里递增的话，重启即清零，
  "10 抽必出史诗"就是句空话。
- **拥有态必须在发货之前问**。先发再问，每件都会被判成"重复"并折算积分。

> **重复折算额必须严格低于箱子价格。** 最初配的是"稀有度越高返得越多"
> （史诗 400 / 传说 1200，而标准箱只卖 300 积分）。一个集齐全池的玩家
> 每次开箱都**净赚**，可以无限刷积分 —— 而单次开箱的断言当时是**通过**的，
> 因为"返还额与配置一致"这条性质本身没被检查过。
> 现在 `ShopProbe` 直接钉住这个不等式（四档折算均 < 最低箱价），
> 并且做过反向验证：把传说档折算额改成 900 后断言确实会红。
> 教训是同一类："绿"不等于"有效"，没被见过失败的守卫等于没有守卫。

---

## 七、已知问题与下一步

### 2026-09-27 更新（商城 / 皮肤系统落地）

新增 `scripts/Shop/` 九个脚本 + `scripts/UI/ShopUI.gd` + 9 个 JSON 配置，
以及 `ShopProbe`(116 断言) 与 `UIProbe`(47 断言) 两个新探针。基线版本 → v1.3.0.0。

**仍未验证 / 未做的事，别当成已完成**：

- **`SteamInventoryAdapter` 没有真机验证过。** 需要真实 AppID + Steamworks 后台
  配好的商品目录 + 已登录 Steam 的引擎，当前用的还是 480(Spacewar 占位)。
  探针只覆盖了"不该工作的部分"：无 Steam 时不接管后端、`grant_item` 明确返回 false、
  余额与保底不由它代管。上架前必须在自己 AppID 上重验拉取/消耗/回调时序。
- **客户端不能发货**，这是 Steam 的限制而非本项目的偷懒：授予物品要用 Web API 的
  publisher 权限，游戏客户端拿不到也不该拿到那套凭据。真正的充值发货链路需要
  一个自有后端服务，目前完全不存在。
- **后端只在启动时选一次**。Steam 若晚于 autoload 就绪，本次会话仍用本地存档，
  要重启才切过去（中途换源得把已加载的 ShopProfile 一起迁移，没做也没测）。
- **商城 UI 的实际观感没有验过。** 无头探针能证明接线正确（页签、筛选、
  按钮真的驱动了结算、预览确实调了和实机同一个 `apply_item_skin`），
  但配色、排版疏密、3D 预览转得顺不顺，必须开编辑器实跑一遍。
- **配件/喷漆尚无挂点**。`slot_for_item()` 对 `accessory` / `spray` 返回空串，
  界面会显示"该外观无需装备"。等角色模型加上 attach 骨点才能接。
- 皮肤目前只有 `tint` + `material_params`（改色/金属度/粗糙度）生效，
  `mesh_override` / `texture_override` / `inspect_animation` 字段是留的接口位，
  接入真实模型资源时才需要实现 `LoadoutCosmetics._swap_mesh()`。

### 2026-09-24 更新（射击手感 / 目标标识 / 人物 / 画质落地）

- **射击再平衡**：此前"瞄得准打不中"的机械缺陷（开火强制退镜、准星不反映真实扩散）已由 E1/G1 修复；
  本次进一步下调 17 把非狙击武器的 `spread_hip / spread_move_add / spread_air_add`
  （狙击枪保留"必须站定"手感不动）。ar17 在 20m 准星正中胸口的一发命中率：
  腰射静止 18%→40%、腰射走 7%→26%、开镜走 55%→100%、开镜跑 39%→99%、开镜空中 12%→47%；
  开镜静止仍为 100%。CombatProbe 52/52、SysProbe 全过。
- **目标标识**：HudCanvas 新增屏幕标记——下包点 A/B（含距离）、队友携带者头顶 C4 图标+名字、
  已安装装置红色标记；屏幕外时显示边缘方向箭头。小地图携带者加 C4 脉冲标签。
- **人物建模**：重做程序化第三人称身体为分层材质战术士兵（皮肤/作战服/护甲/头盔/腰带/战靴，
  去掉冗余的合并腿几何），换队时按材质重着色而非遍历重建。
- **画质落地**：发现桌面快捷方式运行的 `build/PROJECT_STRIKE.exe` 为 9-13 旧构建，早于 A1 画质升级；
  已重建为 **v1.1.0.0**（PCK 完整性校验通过），并将本机存档画质档位由"中"提到"高"。

> 注意：以上改动需**重新构建 exe** 才会进入可玩包（见第三节）。源码改动不会自动反映到 `build/` 旧产物。

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
