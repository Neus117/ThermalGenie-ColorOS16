# Thermal Genie

ColorOS 16（一加 Ace 5 Pro / PKR110）的降温解锁模块：骗过壳温上报、放开充电降温钳制、解锁游戏帧率档位、抬高温控 trip 点，再用一道 52.0℃ 的护栏把控制权交回系统。

KernelSU / Magisk 模块，id `thermal_genie`。所有动作都是运行时写 sysfs 或 bind mount，不改写任何一个固件文件；重启后模块会在开机时重新应用，卸载即恢复原状。

## 它解决什么问题

ColorOS 16 会在电池还不到 40℃ 时就按「壳温」压性能、按「电池温度」限充电功率，并在 CPU 结温 88~92℃ 时直接压 `scaling_max_freq`。这个模块把这四道闸分别按回去，然后用电池温度做统一护栏。

| 现象 | 模块的应对 | 落到哪里 |
|---|---|---|
| 框架读到 35℃ 以上的壳温就开始压性能 | 电池 ≥35.0℃ 时把壳温上报成 37.0℃ | `/proc/shell-temp` |
| 充电发热后系统用 `cool_down` 限功率 | 充电且电池 ≥30.0℃ 时持续写 `cool_down=0` | `/sys/class/oplus_chg/battery/cool_down` |
| 温控档位表把游戏 fps 卡在 60/90，刷新率被锁 | 开机把档位表的 `fps` 全改成 144、解掉刷新率锁定 | `/vendor/etc/display/thermallevel_to_fps.xml`、`/my_product/etc/refresh_rate_config.xml`（bind mount） |
| CPU 结温 trip 在 92℃ 降频，冷却设备在 88~92℃ 压频 | 可选：trip 抬到 97℃，并把 `cpu-cluster*` 的 `cur_state` 钉在 0 | `/sys/class/thermal/thermal_zone*/trip_point_*_temp`、`cooling_device*/cur_state` |
| 上面这些都会让芯片更热 | 电池 52.0℃ 停写并上报 60.0℃，47.0℃ 恢复 | 护栏（见下） |

## 它是怎么起作用的

四层，按开机顺序：

1. **开机早期 `post-fs-data.sh`**：用 `sed` 从原文件生成补丁版 `work/*.xml`，校验字节数与标签数后 bind mount 到原位；同时把补丁文件铺进 `/mnt/vendor/mountify/vendor/etc` 的 lowerdir —— `mountify` 用 overlay 盖住 `/vendor/etc`，单靠 bind 会被遮住。
2. **开机后 `service.sh`**：等 `sys.boot_completed=1` 再等 5 秒，用 `cmp` 校验两处补丁「读到的到底是不是补丁版」，不是就补挂（最多 5 次）；应用温度墙（可选）；再拉起守护进程并监护它。
3. **守护进程 `bin/genie.sh`**：拿单实例锁（`mkdir` 锁目录 + pid + 心跳接管），每个 tick 读一次电池温度与充电状态，决定 `/proc/shell-temp` 写什么；每 30 tick 复核一次温度墙、每 5 tick 复核一次冷却设备。
4. **护栏与看门狗**：护栏压在所有诱骗之上（电池 ≥52.0℃ 时诱骗一律停）；看门狗每 15 秒看一次心跳文件 `.hb`，150 秒不动就杀掉重启。

节拍是自适应的：正在诱骗时 0.2 秒一轮，充电时 0.5 秒，其余 2 秒。这么改是因为诱骗要跟得上框架的读节奏，而空闲时 5Hz 空转白耗电。

```
电池温度 / 充电状态 ──> 护栏判定(52.0/47.0) ──> 写 /proc/shell-temp
                                    └──> cool_down 看门狗 ──> 写 cool_down
                    ──> 采样子系统 ──> logs/telemetry-*.log、charging.log、standby.log
```

## 目录结构

```
ThermalGenie-ColorOS16\
├── README.md              本文件
├── build.ps1              从 src\ 打包到 dist\，版本号取自 module.prop
├── src\                   模块源码，打包后内容直接作为 zip 根
│   ├── module.prop        模块信息（id / name / version 唯一来源）
│   ├── customize.sh       安装：两个音量键选项 + 设权限 + 保留旧 config 与 logs
│   ├── post-fs-data.sh    开机早期：生成并挂载帧率补丁
│   ├── service.sh         开机后：校验补挂补丁、应用温度墙、拉起并监护守护进程
│   ├── action.sh          管理器「动作」按钮：只读状态
│   ├── uninstall.sh       卸载：停进程、解除 bind mount、清锁
│   ├── config.conf        全部可调参数
│   ├── desc.base          管理器卡片的基础文案（状态由 bin/desc.sh 拼上去）
│   └── bin\
│       ├── genie.sh       守护进程：诱骗 / 护栏 / 采集 / 温度墙复核 / 冷却直控
│       └── desc.sh        按 config.conf 的实际值重写 module.prop 的 description
├── test\                  离线验证（把 sysfs 路径重定向到临时目录）
└── dist\                  构建产物，不入库
```

## 构建

```powershell
pwsh -File .\build.ps1
```

输出 `dist\Thermal-Genie-<version>.zip`，并打印条目、大小与 SHA256。版本号只有 `src\module.prop` 一个来源。

打包后脚本会自检，不过就直接报错、不留坏包：**条目必须用 `/` 分隔**（Windows 的 `[ZipFile]::CreateFromDirectory` 会写 `\`，Android 上反斜杠会变成文件名的一部分，安装器解出来是 `bin\genie.sh` 这个文件，于是报「缺少 bin/genie.sh」），并且 8 个必需条目齐全。`powershell -File` 与 `pwsh -File` 都能跑。

## 安装

1. 把 `dist\Thermal-Genie-*.zip` 传到手机
2. KernelSU / Magisk 管理器 → 模块 → 从本地安装
3. 安装时会先后问两个问题，都是音量键；**10 秒内不按 = 保持当前设置**（新装就是包里的默认值）：

   | 问题 | 音量+ | 音量− |
   |---|---|---|
   | 是否解锁游戏帧率？ | 档位表 fps → 144 + 解除刷新率锁定 | 完全不碰这两个系统文件 |
   | 是否启用温度墙解锁 + 冷却设备直控？ | trip 抬到 97℃ + 禁止 cpu-cluster 降频（芯片会真跑到 ~96℃） | 保留内核原始降频 |

   第二个问题默认不动：新装是关，升级则沿用你原来的值——不按键就不会被默认值改写。

4. 重启

升级安装会保留手机上的 `config.conf`（温度墙、冷却直控、护栏阈值这些手改值不会被打回默认）和 `logs/*.log`（换模块目录会把整个目录换掉，不带上就全没了）；重复的键会被收敛成一行。

管理器卡片底部那句话是**按当前状态生成**的（「当前：帧率解锁 …；温度墙解锁 …；冷却直控 …」）：装机时按你刚才的选择写一次，之后每次开机再按 `config.conf` 刷新一次——手改配置再重启，卡片会跟着变。

## 配置

`config.conf` 里每个参数都有注释，改完 10 秒内自动重读，不用重启。

| 键 | 默认 | 作用 |
|---|---|---|
| `SHELL_SPOOF` / `SHELL_MODE` / `SHELL_TRIGGER` / `SHELL_TEMP` | `1` / `trigger` / `350` / `37000` | 壳温诱骗：电池 ≥35.0℃ 时上报 37.0℃；`always` 档不设触发温度 |
| `CHARGE_SPOOF` / `CHARGE_TRIGGER` | `1` / `300` | 充电且电池 ≥30.0℃ 时保持 `cool_down=0` |
| `CHARGE_AB` | `0` | 每次充电交替「保持 cool_down=0」与「不干预」，`charging.log` 里标 `ab=on/off` |
| `FPS_UNLOCK` / `RATE_UNLOCK` / `FPS_MAX` | `1` / `1` / `144` | 帧率与刷新率补丁，**下次开机生效** |
| `GUARD_TRIGGER` / `GUARD_RELEASE` | `520` / `470` | 充电时的护栏（单位 0.1℃） |
| `GUARD_TRIGGER_GAME` / `GUARD_RELEASE_GAME` | `520` / `470` | 非充电时的护栏 |
| `GUARD_VALUE_MIN` / `GUARD_OFFSET` | `50000` / `8000` | 护栏上报值 `max(50.0℃, 电池+8.0℃)`，上限 60.0℃ |
| `ADAPTIVE` / `STANDBY` / `TELEMETRY` / `TICK` / `CHARGE_SAMPLE` | `1` / `1` / `1` / `0.2` / `5` | 节拍、待机统计、遥测开关与采样密度 |
| `SB_GAP_MIN` | `90` | 设备挂起超过这么多秒、醒来又没看到「熄屏」那一刻时，按电量差补记一条待机；`0` 关闭补账 |
| `THERMAL_UNLOCK` / `THERMAL_DELTA` / `THERMAL_CAP` | `0` / `5000` / `98000` | 温度墙解锁；安装时可选用音量+ 打开 |
| `CDEV_UNLOCK` / `CDEV_GUARD` | `0` / `520` | 冷却设备直控；安装时与温度墙一起选，也可事后改 |

温度墙与冷却直控是两道绕过内核保护的开关，装好之后默认是关的；要用就在 `config.conf` 里显式打开，代价见「安全边界」。

## 运行行为

| 条件 | 动作 |
|---|---|
| 电池 ≥35.0℃ 且未触护栏 | 壳温上报 37.0℃，以 0.2 秒一轮维持 |
| 充电 且 电池 ≥30.0℃ 且未触护栏 | 持续把 `cool_down` 写成 0 |
| 电池 ≥52.0℃ | 停诱骗，上报 `max(50.0℃, 电池+8.0℃)`（上限 60.0℃），内核按真实温度接管 |
| 降到 ≤47.0℃ | 恢复诱骗，并补写一次温度墙 |
| `THERMAL_UNLOCK=1` | `cpu-*` / `sys-therm-*` 里 85.0~92.0℃ 的 trip 抬 +5.0℃（上限 98.0℃），每 30 tick 复核补写 |
| `CDEV_UNLOCK=1` | 电池 <52.0℃ 且结温 <96.0℃ 时把 `cpu-cluster*` 的 `cur_state` 钉 0，越界立即放手 |

护栏的两档现在同阈值（52.0/47.0）：早期版本充电档是 48.0/43.0，实测两天最高只到 46℃、从未触发，索性统一。

## 日志

都在 `/data/adb/modules/thermal_genie/logs/`。

| 文件 | 内容 |
|---|---|
| `genie.log` | 启动横幅（含数据源自检 `CAPS`）、状态切换、护栏触发、心跳异常、充电起止、温度墙补写、冷却直控动作 |
| `telemetry-YYYYMMDD.log` | 按天：`TEL` 状态行约 5 秒一条，`CHG` 充电功率点约 1 秒一个，`CAL` 每次充电开始记原始读数用于校准单位，`THR` 频率上限一变就记一条 |
| `charging.log` | 每次充电一条汇总：时长 / 起止电量 / 峰值 / 均值 / 最大电流 / 最高温 / 护栏是否触发 |
| `standby.log` | **每次待机一条汇总**：`dur` 时长、`cap` 起止电量、`samples` 采样数、`sph` 每小时采样数（判断深睡比例）、`avg` 醒着时的平均电流、`rate` 每小时掉电（仅 ≥30 分钟才计算）、`cpu` 本段模块自耗。行尾 `src=gap` = 这段是醒来后按挂起时长补记的（进程没赶上「熄屏」那一刻，所以 `samples`/`avg`/`cpu` 记 0）；行尾 `resume=1` = 这段跨过一次守护进程重启，`dur` 含重启前后两段 |
| `standby-YYYYMMDD.log` | 每次待机结束一行 `WAKE`，记录当次唤醒源计数（按持锁时长排序的 top5，`name:count`）；读不到 debugfs 时写 `unavailable` |
| `post-fs.log` | 开机挂载帧率补丁的结果（`OK` / `BIND-SHADOWED` / `VALIDATE-FAIL` / `STAGED`）。每行带 `up=秒数`：开机早期系统时钟可能还没校准，时间戳不可信时用 `up=` 排先后 |

一次性看当前状态：

```sh
su -c 'M=/data/adb/modules/thermal_genie; tail -5 $M/logs/charging.log; grep -E "GUARD|CHARGE|TICK" $M/logs/genie.log | tail -8'
```

管理器里的「动作」按钮跑的是 `action.sh`，只读：模块版本、数据源自检、壳温上报值、电池温度/功率/充电状态、`cool_down`、进程 pid、A/B 档位、两处补丁是否生效、最近 3 次待机与充电、模块自身 CPU 开销、最近事件。

## 关键常量（实测得出，不要凭猜改）

- `/sys/class/power_supply/battery/current_now` 单位是 **mA**，**负值表示充电**
- `/sys/class/power_supply/battery/voltage_now` 单位是 **µV**
- 功率 = `|current_now| × voltage_now / 1e6` → **mW**
- `/sys/class/power_supply/battery/temp` 单位是 **0.1℃**
- `/proc/shell-temp` 写入格式是 `通道 值`，取 **毫摄氏度**，四个通道（0~3）都要写
- `power_now` 的读数与 `cur×v` 相差 1000 倍，**不可信，已弃用**（模块只在 `CAL` 行里留原始值做对照）

## 充电功率的读数口径（2026-11-08 实测，很重要）

驱动按**单芯**上报电流/电压，整包是双芯：**真实功率 ≈ 记录值 × 2**。

判据：12%→100% 充入约 20.8Wh（6100mAh × 3.87V × 88%）；日志积分只有 8.6Wh。若记录值是整包功率，48 分钟平均 12.2W 只能送出 9.8Wh——差一倍，不可能；按 ×2 算是 17.2Wh，与 48 分钟所需的约 26W 平均功率吻合（残余 17% 在 SOC 跳变与充电效率误差内）。

所以 `charging.log` 里的 `peak` / `avg` 是**单芯视在功率**：峰值 39.3W 对应整包 ≈78.6W，均值 12.2W 对应整包 ≈24.4W。系统应用（如 Scene）显示的「40W」是同一个口径，不是真的只有 40W。

## 实测结论（一加 Ace 5 Pro / PKR110 / ColorOS 16，2026-11）

降频是三层叠加的，只拆一层没用：

| 层次 | 阈值 | 证据 |
|---|---|---|
| 内核 thermal trip | CPU 核 92℃ | `cpu-0-2-0` 等 10 个 zone 的 trip0，`THERMAL_UNLOCK` 抬到 97℃ |
| Cooling device | `cpu-cluster0/1` | 88~92℃ 时 state 升到 11~12，直接压 `scaling_max_freq` |
| Perf HAL | 未定位 | 抬 trip + 直控 cooling 后，仍会在 90~93℃ 压到 2.24 GHz |
| 电池温度 | 52℃（护栏） | 实测两天最高 46℃，从未触发 |

效果对照（90~93℃ 时的大核频率下限）：

| 配置 | 大核频率下限 |
|---|---|
| 原始 | 1.69 GHz |
| 仅抬 trip | 1.69 GHz（一半 trip 被系统改回，无效） |
| 抬 trip + 直控 cooling | **2.24 GHz** |

## 已知限制 / 坑

- **不要读 `/sys/power/wakeup_count`**：`pm_get_wakeup_count()` 会拿挂起锁，熄屏瞬间读它会进入不可打断的 D 状态，`timeout` 和 `kill -9` 都救不了，整个守护进程就此卡死（2026-11-10 真机实测，两次）。模块只用 `suspend_stats` 与 `wakeup_sources`。
- 熄屏深睡时进程会被挂起，`samples` 远小于时长属正常；判断真实耗电要看 `rate`（≥30 分钟才算）。
- `/vendor/etc` 被 `mountify` 用 overlay 覆盖，`post-fs-data` 阶段挂的帧率补丁会被盖住；靠 `service.sh` 开机后补挂才生效（日志里看 `verify OK ... (try 1)`）。
- 帧率补丁开机约 10 秒后才真正生效；若显示服务在更早的时候已读取该表，本次开机内可能不生效（未在真机上复现）。
- 部分 `trip_point_*_temp` 会被系统周期性改回默认值，靠守护进程复核补写（日志里的 `THERMAL-FIX`）。
- 熄屏时 `scaling_max_freq` 被压到 57~61% 是**省电策略**，不是温控，不能当降频证据。
- 旧模块（murongruyan）的 `frozen`/`unfrozen` cgroup 墓碑方案在 ColorOS 16 上已空转，本模块未采用。
- 充电表改写（`CHARGE_TEMP_SHIFT`）在 v0.4 被移除，当前版本不含此功能。

## 安全边界

- **冷却直控是绕过内核温控**：`CDEV_UNLOCK=1` 时内核在 88~92℃ 的降频被钉住，芯片会真的跑到 96℃ 左右，之后只剩两道闸——电池护栏 52.0℃、结温保险 96.0℃。高温下长期使用会加速电池老化。
- 温度墙解锁只动 `cpu-*` / `sys-therm-*` 两类 zone，且 `THERMAL_CAP`（默认 98.0℃）封顶，不碰 hot trip。
- 所有写入都是 sysfs 或运行时挂载，不改固件文件；重启后模块在开机时重新写入，卸载即恢复原状，没有不可逆操作。

## 离线验证

`test\` 里是把 `genie.sh` 的 sysfs 路径用 `sed` 重定向到临时目录的回归脚本，不需要手机：

| 脚本 | 验什么 |
|---|---|
| `run6` | 充电会话开始 → 采样 → 汇总 |
| `run7` | 功率换算（mA×µV→mW）、放电样本不计入 |
| `run8` | 写回校验（`SPOOF-FAIL`）与 `TICK` 非法值回落 |
| `run9` / `run11` | 待机会话汇总与字段完整性 |
| `run12` | 待机会话状态落盘：进程中途退出后重启应写 `resume=1`；没赶上熄屏时应补一条 `src=gap`；跨重启的会话必须丢弃；电量不降反升时 `rate` 必须是 `n/a` |
| `run13` | 升级安装：旧 `config.conf` 与 `logs/*.log` 都要被带过来，音量键选择仍然生效 |
| `run10` | 自适应节拍（slow ↔ fast） |
| `run.sh` / `run4.sh` | v0.2 / v0.4 时代的状态机回归 |

```powershell
# Windows 上用 Git Bash
cd test
bash run8.sh
```

注意：`run6` / `run7` / `run9` 用真实时间窗驱动（采样脚本每 0.4 秒改一次夹具值），而 Windows 上每次 fork 约 50 ms、`sleep 0.02` 实测约 77 ms，时序类用例会错过时间窗、读出一堆 0。这三条要在 Linux 上跑（WSL 或真机 `adb shell`）。

## 版本历史

| 版本 | 变更 |
|---|---|
| v0.3 | 纯脚本壳温诱骗 + `cool_down` 看门狗 + 护栏 |
| v0.4 | 加音量键选择、游戏帧率解锁（fps 144 + 刷新率解锁）、双档护栏 |
| v0.5 | 修复 mountify overlay 遮挡：注入 lowerdir + 开机后校验补挂 |
| v0.6 | 自动充电采集、会话汇总、按天遥测、可选自动 A/B |
| v0.6.1 | 修复功率单位/符号/缩放三个 bug；`power_now` 弃用，改 cur×v 现算 |
| v0.6.2 | 日志版本号改为从 `module.prop` 读取（此前写死 v0.6，无法区分 0.6 与 0.6.1） |
| v0.6.3 | 健壮性：`TICK` 非法值回落 0.2（防忙循环）、每 5 秒校验写入是否真生效（`SPOOF-FAIL` / `CD-FAIL` / `sp=fake-fail`）、安装时缺 `timeout`/`getevent` 不再阻塞 |
| v0.7.0 | 待机耗电测量：熄屏会话汇总（`standby.log`）+ 唤醒源明细（`standby-YYYYMMDD.log`）+ 自适应节拍（0.2 / 0.5 / 2 秒三档） |
| v0.7.1 | 版本号只保留 `module.prop` 一个来源：安装横幅与动作按钮改为运行时读取，其余文件删掉写死的版本注释 |
| v0.7.2 | 待机汇总口径修正：`rate` 仅 ≥30 分钟计算（短会话写 `n/a`）、去掉误导性的 `int`、新增 `sph` 采样密度、唤醒源读不到时写 `unavailable` 并尝试挂 debugfs |
| v0.8.4 | 移除 `/sys/power/wakeup_count` 读取（内核 `pm_get_wakeup_count` 会持锁阻塞，熄屏瞬间必然卡死）；待机汇总去掉 `wc`，保留 `ss` / `lf` |
| v1.0.0 | 温度墙解锁（trip +5.0℃ → 97℃）+ 冷却设备直控、统一 52.0/47.0 护栏、降频遥测（`TEL` / `THR`）；模块更名 Thermal Genie for ColorOS 16 |
| v1.0.1 | 待机会话不再丢账：状态每轮落盘到 `.sbstate`，守护进程被看门狗重启后接着算（`resume=1`）；设备先挂起、进程没赶上「熄屏」那一刻时，醒来按挂起时长补记一条（`src=gap`，`SB_GAP_MIN`） |
| v1.0.2 | 升级安装把旧 `logs/*.log` 一起带过来（此前换模块目录会把几天几周的待机与遥测记录删干净）；跨重启的待机会话不再续算（日志记 `STANDBY-DROP pre-boot`）；电量不降反升时 `rate` 写 `n/a`（此前会写出 `-4.-99%/h` 这种坏值）；`post-fs.log` 每行加 `up=秒数` |
| v1.0.3 | 安装时多问一句「温度墙解锁 + 冷却设备直控」：音量+ 打开、音量− 关闭、不按保持当前设置（升级不会被默认值改写）；音量键选择不再覆盖用户手改的值；`config.conf` 末行补了换行，重复键收敛成一行 |
| v1.0.4 | 管理器卡片的描述改成按实际状态生成（装机时按选择写一次、每次开机按 `config.conf` 刷新），不再写死「默认关闭」；新增 `desc.base` 与 `bin/desc.sh` |
