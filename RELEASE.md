# PROJECT STRIKE — 发布手册

> **状态(2026-09-01)**：Windows 导出、Steam 集成、图标/版本注入 **均已实际完成并实测通过**。
> 引擎 Godot 4.4.1 stable + GodotSteam v4.16（Steamworks 1.62）。
>
> 本轮修掉了一个会让 exe 完全打不开的构建缺陷：**rcedit 抹掉内嵌 PCK**（详见 1.1b）。
> 在此之前图标 6/6、版本号回读全部"通过"，只有真跑一次才暴露。

---

## 0. 当前已完成的发布链路

| 环节 | 状态 | 证据 |
|---|---|---|
| Godot 4.4.1 官方导出模板 | ✅ 已安装 | `~/AppData/Roaming/Godot/export_templates/4.4.1.stable/` 35 个文件 |
| GodotSteam 编辑器 | ✅ 已安装 | `.tools/GodotSteam_Editor.exe`（158MB） |
| GodotSteam 导出模板 | ✅ 已替换 | release/debug 两个模板已换成带 Steam 的版本 + `steam_api64.dll` |
| Steam 实际连接 | ✅ 实测通过 | 引擎内与导出 exe 均输出 `[Steam] 已连接: Hermes (ID 76561198770663790)` |
| 导出独立 exe | ✅ 完成 | `build/PROJECT_STRIKE.exe`（约 95MB） |
| 图标注入 | ✅ 完成 | `icon/game.ico` 六尺寸，rcedit 验证生效 |
| 版本信息注入 | ✅ 完成 | FileVersion / ProductVersion / 公司 / 描述 / 版权 均可读回 |
| 成就挂钩 | ✅ 代码侧完成 | 6 项，等 Steamworks 后台建同名条目 |
| 云存档 | ✅ 代码侧完成 | `ps_rank.json` / `ps_stats.json` |
| Steam Overlay | ✅ 代码侧完成 | 主菜单按钮（仅 Steam 运行时显示） |

---

## 1. 一键构建

双击 **`build_release.bat`**，或指定版本号：

```bat
build_release.bat 1.2.0.0
```

脚本依次做五件事：

1. 把版本号写进 `export_presets.cfg`
2. `--headless --export-release "Windows Desktop"` 导出单文件 exe
3. **备份内嵌 PCK** → `rcedit` 注入图标 + 版本信息 → **还原内嵌 PCK** → 复核
   （顺序不能乱，理由见 1.1b）
4. 把 `steam_api64.dll` / `steam_appid.txt` 拷到 `build/`
5. 汇总产物信息

### 1.1 依赖路径

| 文件 | 位置 | 说明 |
|---|---|---|
| 引擎（带 Steam） | `../.tools/GodotSteam_Editor.exe` | 缺失时自动回退 `Godot441.exe`（无 Steam） |
| rcedit | `C:\GodotTools\rcedit.exe` | 图标/版本注入；缺失只跳注入，不影响游戏 |
| Steamworks 运行时 | `../.tools/steam_api64.dll` | 必须随 exe 分发 |
| 图标源 | `icon/game.ico` | 程序化生成，六尺寸（16/32/48/64/128/256） |

> rcedit 路径在 Godot 编辑器设置里也配了一份：
> `%APPDATA%\Godot\editor_settings-4.4.tres` → `export/windows/rcedit = "C:/GodotTools/rcedit.exe"`
> 放 ASCII 路径是为了避开中文用户名目录的进程创建问题。

### 1.0 怎么玩

双击 **`play_game.bat`** —— 它优先跑 `build\PROJECT_STRIKE.exe`（独立发布版，
不依赖 Godot），没有构建产物时才退回用 `.tools` 里的引擎跑工程。

操作：`WASD` 移动 · `Shift` 静步 · `Ctrl` 蹲 · `空格` 跳 · `左键` 射击 ·
`右键` 开镜 · `R` 换弹 · `1~4` 切枪 · `B` 购买菜单 · `E/F` 安装或拆除 ·
`Tab` 计分板 · `Esc` 释放鼠标。

### 1.1 已知问题：Godot 自带的 rcedit 步骤会失败

导出日志里会出现一行 `rcedit (...\*.tmp): `（错误文本为空）。**已定位，不用管**：

- Godot 在 `savepack` **之前**就对 `<输出名>.tmp` 调 rcedit，而那个 tmp 此时还没生成
- 换成绝对路径输出（`C:/Temp/ps_test.exe`）同样失败 → 排除相对路径 / 工作目录问题
- rcedit 把 `Unable to load file` 写进 **stderr**，Godot 只拿到 stdout，所以错误信息是空的
- 单独对最终 exe 或模板跑同样的 rcedit 命令，exit code 都是 0

**结论**：`export_presets.cfg` 里的图标/版本字段对这份 GodotSteam 定制构建实际不生效，
真正的注入由 `build_release.ps1` 在导出后完成，并回读校验。

验证图标确实生效的方法（别靠肉眼看文件属性）：

```python
# 解析 icon/game.ico 的 6 个条目, 逐个在 exe 里找字节串
# 6/6 命中 ⇒ 嵌入的是我们的图标, 不是 Godot 默认图标
```

### 1.1b 已知问题：**rcedit 会抹掉内嵌 PCK**（最危险的一个坑）

症状：构建脚本 5 步全绿、图标 6/6、FileVersion 回读正确，但双击 exe 就是黑屏退出，
只有把它真正跑起来才能看到：

```
Error: Couldn't load project data at path "."
If you've renamed the executable, the associated .pck file should also be renamed
to match the executable's name (without the extension).
```

原因链：

1. `binary_format/embed_pck=true` 时，Godot 会**额外建一个名为 `pck` 的 PE 节**，
   把整个包追加在 exe 末尾，并在最后 12 字节写 `[pck_size:u64][magic:"GDPC"]`。
   启动时用 `filesize - 12 - pck_size` 反推包起点。
2. rcedit 2.0.0 改写 PE 资源时**不保留 overlay**：它把文件在 PE 末尾截断，
   再补零到原长度。
3. 结果：**文件体积一字节不变**，`.rsrc` 里图标和版本号确确实实进去了，
   但 `pck` 节的内容整段变成 0，游戏找不到工程数据。

对照实测（`overlay_tool.py check`）：

| 文件 | 大小 | `pck` 节 | 尾部 `GDPC` | 能否启动 |
|---|---|---|---|---|
| 刚导出、未动过 | 99,763,152 | RawPtr=99,310,592 RawSize=452,560 | 有 | ✅ |
| rcedit 之后 | 99,763,152 | 节表还在，内容全 0 | 无 | ❌ 报上面的错 |

**解法**：改 PE 之前先用 `overlay_tool.py save` 把 overlay 整段抠出来存盘，
rcedit 之后再 `restore` 贴回原偏移。贴回前会校验「新的 PE 有没有长过 overlay 起点」
（排除 `pck` 节后算 PE 结束位置），长过了就拒绝，绝不产出一个看起来正常、实际打不开的 exe。

如果因为任何原因定位不到 overlay（比如没有 Python），脚本会**直接跳过 PE 改写**——
一个没图标但能启动的 exe，永远好过一个图标漂亮却打不开的 exe。

### 1.2 产物结构

```
build/
├── PROJECT_STRIKE.exe    # 95 MB 单文件，PCK 已嵌入，双击即玩
├── steam_api64.dll       # 必须同目录，否则 Steam 初始化失败
├── steam_appid.txt       # 当前 480（Spacewar 测试），发布前改正式 AppID
├── run.log               # 本次构建的完整输出
├── trace.log             # 构建步骤耗时追踪（排查"卡在哪一步"用）
└── (templates/ 已清理，见下)
```

#### `build/templates/` 为什么可以删（已核实，不是猜的）

构建真正依赖的模板在 **`%APPDATA%\Godot\export_templates\4.4.1.stable\`**（1.88GB，36 个文件），
里面 `windows_release_x86_64.exe`（94.81 MB）和 `steam_api64.dll` 都在。
`build/templates/` 只是当初下载和解压时留下的**第二份副本**：

| 内容 | 大小 | 性质 |
|---|---|---|
| `Godot_v4.4.1-stable_win64.exe` | 149.1 MB | Godot 安装包本体，`.tools/` 里已有 |
| `godot441_templates.tpz` | 1150.2 MB | 模板下载包，已解压安装到 APPDATA |
| `gs413/416_*.zip`、`godot441_engine.zip` | 224.5 MB | GodotSteam 各版本 zip，已解压 |
| `templates/` | 1880.7 MB | 与 APPDATA 里那份 1.88GB **完全重复** |
| `gs_editor/`、`gs_tpl/` | 992.0 MB | 解压中间产物，已产出 `.tools/GodotSteam_Editor.exe` |

> ✅ **已清理**：用 `python recycle_templates.py` 送进回收站（4.78 GB，
> 可恢复）。删了之后重新构建不受任何影响（`.tools/` 的引擎、APPDATA 的模板、
> C 盘的 rcedit 三样都还在，已自动验证）。
>
> 顺带记录两个 WinAPI 的边角行为，供以后碰到时参考：
> - 整目录 `SHFileOperationW(FO_DELETE | FOF_ALLOWUNDO)` 返回 124 (0x7C)；
>   小目录同函数返回 0/2，所以不是配额也不是权限。
> - `send2trash.send2trash(整个目录)` 报 `PermissionError [WinError 5]`。
> - **可行方案**：`send2trash.send2trash()` 逐项调用，10 个顶层条目全部 OK。
>   推测是 SHFileOperation 的批处理入口在递归 + 大体积组合下的副作用。

`steam_api64.dll` 和 `steam_appid.txt` **必须和 exe 同目录**，所以 `play_game.bat`
会先 `cd` 到 `build/` 再启动。

### 1.3 构建期的三个自查脚本

构建脚本自己说"通过"不够，这三个是独立复核用的：

| 脚本 | 作用 | 用法 |
|---|---|---|
| `verify_exe.py` | 图标 6 个尺寸逐个字节比对 + 版本字符串回读 + Steam 运行时是否齐全 | `python verify_exe.py` |
| `overlay_tool.py` | 内嵌 PCK 的备份 / 还原 / 完整性校验 | `python overlay_tool.py check build\PROJECT_STRIKE.exe` |
| `smoke_test.py` | 真正把 exe 跑起来，抓 stdout 看有没有报错 | `python smoke_test.py --mode windowed --seconds 15` |

> **构建产物必须真的跑一次才算数。** 本次就是靠 `smoke_test.py` 才抓出
> rcedit 抹掉内嵌 PCK 的问题——在那之前图标 6/6、版本号回读全部"通过"。

> ⚠ **跑完 `smoke_test.py` 必须先结束进程再构建。**
> 它默认"结束后保留进程"，而 Windows 不允许删除正在运行的 exe，
> 于是下一次 `build_release.ps1` 会在第一步 `[2/5] 导出` 前抛
> `Access to the path ... is denied` 并中止。
> 如果构建命令是 `... | tail` 这类管道收尾，**管道退出码会盖掉真正的失败**，
> 看起来"构建成功"，实际 `build/PROJECT_STRIKE.exe` 还是上一次的旧文件——
> 里面是所有改动之前的配置。2026-09-27 就这么差点把一个含**错误折算表**的包当成
> 已验证产物发布出去（旧值让玩家可以无限刷积分）。
>
> 收尾二选一：`taskkill /F /IM PROJECT_STRIKE.exe`，或构建前先确认没有该进程。
> 另外别只信退出码——抽查包里是否真有新内容的特征字符串。

存档位置：`%APPDATA%\Godot\app_userdata\PROJECT STRIKE\`
（`settings.cfg` / `rank.json` / `replays/`）

---

## 2. 专用服务器

**A. 同一 exe 跑服务器（推荐，零额外构建）**

```bat
PROJECT_STRIKE.exe --headless -- --server [--port 24565] [--bots 9] [--map project_zero]
```

无 UI 模式：加载地图、生成 Bot、监听端口。

| 参数 | 默认 | 说明 |
|---|---|---|
| `--port` | 24565 | 监听端口 |
| `--bots` | 9 | Bot 数量，0~10 |
| `--map` | project_zero | project_zero / night_harbor / red_district |

**纯观察者模式（`--bots 0`）**

```bat
PROJECT_STRIKE.exe --headless -- --server --bots 0
```

一个 Bot 都不生成，服务器停在 `热身等待` 阶段，等玩家连进来；
**两队各够 1 人时自动开赛**，无需任何人工干预。

实测时间线（两个 headless 客户端依次连入）：

```
0s    热身等待中: 0 人 (每队至少 1 人开赛)
12s   热身等待    actors=0      ← 客户端1 连入
17s   热身等待    actors=1      ← 只有 STRIKE 有人, GUARD 还空着
      _on_net_peer_joined actors_before=1   ← 客户端2 连入
      "人数足够, 开始比赛 (2 人)"
22s   购买阶段    actors=2      ← 自动开赛
37s   进行中      actors=2
```

> 为什么要单独做这个模式：人数为 0 时 `_check_alive_condition()`
> 两边存活数都是 0，会立刻判平局并空转回合。所以必须停在 WARMUP
> 不启动回合状态机，靠 `_warmup_recheck()` 每 0.5 秒重判一次。

**B. 导出 Linux Server**

Export 面板复制预设 → 平台选 Linux → 勾选 *Export as dedicated server*。
云主机上同样用 `--headless -- --server` 启动。

---

## 3. Steam 接入

### 3.1 已完成的实现

`scripts/Core/SteamManager.gd`（autoload 单例）：

- **动态检测**：`Engine.has_singleton("Steam")` 判断，无 Steam 引擎时静默降级为本地模式，
  不会像 `get_singleton()` 那样刷 ERROR
- **初始化兼容**：GodotSteam 4.x 的 `steamInit()` 返回 `bool`（旧版返回 Dictionary），
  代码用 `Variant` + `is bool` / `is Dictionary` 双分支处理
- **成就**：`unlock_achievement(id)`
- **云存档**：`cloud_write(key, data)` / `cloud_read(key)`
- **Overlay**：`open_overlay(name)`

### 3.2 成就清单 — **需在 Steamworks 后台按此 API Name 创建**

| API Name | 显示名 | 触发点 |
|---|---|---|
| `FIRST_KILL` | 首杀 | `MatchManager` 首次击杀 |
| `HEADSHOT_MASTER` | 爆头王 | 爆头击杀 |
| `BOMB_PLANTED` | 爆破专家 | `ObjectiveSystem` 装置安装 |
| `FIRST_WIN` | 首胜 | 比赛胜利 |
| `RANK_SILVER` | 白银之上 | `RankSystem.tier_index() >= 2` |
| `TRAINING_STAR` | 训练标兵 | 进入训练场 |

### 3.3 发布前必须改的两处

1. **`steam_appid.txt`**：`480` → 你的正式 AppID（否则成就/云存档写到 Spacewar 里）
2. **Steamworks 后台**：建上面 6 个成就条目，名称必须完全一致

### 3.4 身份与存档

- 玩家名：`GameManager.player_name`，接入后用 `Steam.getPersonaName()`
- 段位/MMR：仍本地存 `user://rank.json`，跨设备靠 Steam 云存档同步

---

## 4. 发布前检查清单

回归测试（无头探针，`scenes/Dev/`）：

- [x] 四张地图各跑完整比赛 —— `TestBoot.tscn -- --map <id>`
- [x] 战斗系统定向测试 —— `CombatProbe.tscn`
- [x] 装置全流程 —— `PlantProbe.tscn`
- [x] 网络快照同步 —— `NetProbe.tscn`
- [x] 商城系统 —— `ShopProbe.tscn`（117 断言：数据完整性 / 折算经济闭环 /
      开箱概率与保底 / 多玩家 profile 隔离 / RPC 伪造防护 / Steam 适配器降级）
- [x] 商城界面接线 —— `UIProbe.tscn`（47 断言：页签 / 筛选 / 3D 预览 /
      按钮真的驱动结算 / 主菜单入口）
- [x] Windows exe 导出并可运行（Steam 连接、图标 6/6、版本信息回读校验）
- [x] 图标 / 版本信息注入
- [x] **内嵌 PCK 完整性**（`overlay_tool.py check`，rcedit 之后必须过）
- [x] **商城 JSON 已进包**（构建产物里 grep 得到 `ws_falcon_crimson_tide` /
      `repeat_refund_credits` / `lb_standard_case`，新目录 `data/skins|shop/` 未被漏掉）
- [x] **发布版 exe 实跑冒烟**（`smoke_test.py`：Vulkan Forward+ 起来、22 把武器加载、
      17 个外观条目 / 2 个开箱 / 5 个商城条目加载、无报错）
- [x] 纯观察者专用服务器（两个客户端依次连入，两队各 1 人自动开赛）

**上架前仍必须补做（当前环境无法验证，不要签掉）**：

- [ ] **Steam 真实商品目录验证** —— `SteamInventoryAdapter` 只在无 Steam 环境下
      验证过"正确地不接管后端、正确地拒绝发货"。拉取 / 消耗 / 回调时序需要
      真实 AppID + Steamworks 后台商品配置，当前 AppID 480 是 Spacewar 占位值。
- [ ] **充值发货后端** —— 客户端无 publisher 权限，无法授予 Steam 库存物品。
      "钻石到账 → 发货"这条链路依赖一个尚不存在的自有后端服务。
- [ ] **商城 UI 人工过一遍** —— 无头探针测的是接线，不是观感。配色、排版疏密、
      3D 预览镜头与开箱揭示动画的实际表现必须开编辑器实跑确认。
- [ ] 联机下真实走一遍商城（`NetProbe` 目前只覆盖角色与快照，未覆盖商城 RPC 往返）

待人工确认：

- [x] 局域网双端实测（无头 NetProbe 双进程，2026-09-01）：连接 ✓ 角色下发 ✓
      快照/状态同步 ✓ 阶段推进 ✓。测试中发现并修复了 **快照 RPC 目标写错的
      严重 bug**（`_broadcast_snapshot.rpc()` 应为 `_receive_snapshot.rpc()`，
      修复前位置快照从未送达客户端，联机远端角色全部静止）。
      遗留噪音（已解决 2026-09-06）：真凶是 `estimate_rewind_for()` 给机器人
      角色查 ENet RTT（`peer.get_peer(nid)` 踩空），且无客户端也触发；
      修复后机器人/本地角色直接 0 回溯，真客户端才取 RTT/2+33ms；
      另将 `_do_spawn`/`_receive_loadout` 残留全体广播改为定向 rpc_id。
      三图 TestBoot + NetProbe 双进程全部 0 噪音 0 脚本错误。
- [x] 训练场：假人命中 ✓（伤害归因修复后 TestBoot 实测 202 伤害/10 命中）、
      复活 ✓（respawn 队列 2.5s）、备弹无限 ✓（WeaponSystem._training_mode）
- [x] 性能（2026-09-08 实测，RTX 5060 Laptop / Vulkan Forward+ / 垂直同步
      180Hz / 专用服务器视角 + 全环境特效 + 9 Bot 交战）：
      PROJECT ZERO 均值 179 FPS（贴 180 上限）；RED DISTRICT 均值 178；
      NIGHT HARBOR 购买阶段 ~143、交战阶段 175-180（最低 141）。
      内存：工作集稳定 ~530MB（40s 无增长），单进程 CPU 约合 0.8 核。
      注：该口径不含第一人称 viewmodel/PostFX/HUD（专用服务器不建 UI），
      真实客户端略高，但余量充足。
- [ ] 导出 exe 在无 Godot 的机器上双击可玩（本机已验证 exe 不依赖引擎目录；
      导入表分析确认唯一非系统依赖是 steam_api64.dll，Win10+ 其余全自带，
      但仍建议在干净机器上过一遍）
- [x] 音量/灵敏度/FOV 设置持久化（SysProbe 2026-09-08 重跑 18/18 全过；
      另有玩家真实 settings.cfg 存档为实战佐证）
- [x] 录像生成与回放可用（SysProbe：录制 2937ms → 落盘 JSON → 加载 90 帧
      → 采样插值 → kill 事件保留）
- [x] 联机配装同步（2026-09-06 完成）：新增 `broadcast_loadout` 配装同步 RPC
      与 `request_purchase` 客户端购买请求 RPC（服务器权威结算后回执）；
      NetProbe `--buytest` 端到端实测：客户端购买 viper → secondary
      ""→"viper"、金钱 800→300，回执正确。HUD 弹药/金钱/持枪模型均随同步更新。

---

## 5. 已知限制（如实说明）

| 模块 | 状态 |
|---|---|
| 客户端预测 | 简化版：本地模拟 + 快照校正（>6m 直接对齐，否则 25% 收敛），非完整帧级预测 |
| Lag Compensation | 已实现：服务器 1s/60Hz 位置历史回溯，按 RTT/2+33ms，上限 250ms |
| 断线重连 | 客户端 5 分钟窗口、每 3 秒重试，角色以新 peer 重新下发 |
| Dedicated Server | 可用（带 Bot 模拟 + 客户端加入）；`--bots 0` 纯观察者模式已完成并实测 |
| Steam 集成 | 代码 + 运行时已完成；AppID 为测试值 480，成就条目待后台创建 |
| 骨骼动画 | 无外部模型，程序化肢体动画（走跑摆腿摆臂 / 蹲伏 / 持枪） |
| 美术资源 | 零外部资源：地图几何、枪械视图模型、音效 PCM、角色动画、游戏图标全部代码生成 |
