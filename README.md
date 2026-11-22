# Thermal Genie for ColorOS 16

把 ColorOS 16 提前介入的**降频、限充、帧率锁定**按回去，再用一道电池温度护栏兜底。

KernelSU / Magisk 模块，id `thermal_genie`。所有改动都是运行时写 sysfs 或挂载，不改固件文件；重启后模块在开机时重新应用，卸载即恢复原状。当前版本以 `src/module.prop` 为准。

> **只在一加 Ace 5 Pro（PKR110 / ColorOS 16）上验证过。** 换机型要重新量 thermal 节点与阈值，不是改个数字就能用。

## 它做什么

| 系统本来会怎样 | 模块的应对 |
|---|---|
| 框架按 `/proc/shell-temp` 判断壳温，电池一到 35℃ 就开始压性能 | 电池 ≥35.0℃ 时把壳温写成 37.0℃（四个通道都写） |
| 充电发热后用 `cool_down` 限制功率 | 充电中电池 ≥30.0℃ 时保持 `cool_down=0` |
| 温控档位表把游戏 fps 卡在 60/90 | 开机替换档位表：fps → 144，解开刷新率锁定 |
| 内核 trip 在 92℃ 降频，88~92℃ 由冷却设备直接压 `scaling_max_freq` | **可选**：trip 抬到 97℃，并按住 `cpu-cluster` 不让它降频 |
| —— | 电池 52.0℃ 停止改写、47.0℃ 恢复；结温 96.0℃ 把控制权交回内核 |

## 先说代价

- **最后一行那两个开关（温度墙 + 冷却直控）是拿电池寿命换帧率**：打开后芯片会真跑到 ~96℃，重载更费电、机身更热。**默认关闭**，装的时候按音量+ 才会开。
- 不开它们，前三项照样工作：壳温诱骗、充电解锁、帧率补丁。
- 打开时建议配散热背夹；边充边玩热量会叠加。
- 所有写入都是 sysfs 或运行时挂载，没有不可逆操作。

## 安装

1. 把 `dist\Thermal-Genie-*.zip` 传到手机
2. KernelSU / Magisk 管理器 → 模块 → 从本地安装
3. 先后问两道题，用音量键回答；**不按键 = 保持默认设置**，一次按键只回答一道题

   | 问题 | 音量+ | 音量− |
   |---|---|---|
   | 游戏帧率解锁（默认开） | 档位表 fps → 144，刷新率不锁 | 完全不碰这两个系统文件 |
   | 修改温度墙与冷却直控（默认关） | CPU 温度最高可达 96℃ | 保持内核原始降频 |

4. 重启（帧率补丁要开机才挂上）

升级安装会保留手机上的 `config.conf` 与 `logs/*.log`，重复的键会被收敛成一行。

## 配置

`config.conf` 每项都有注释，改完 10 秒内自动重读，不用重启、不用重装。

| 键 | 默认 | 作用 |
|---|---|---|
| `SHELL_SPOOF` / `SHELL_MODE` / `SHELL_TRIGGER` / `SHELL_TEMP` | `1` / `trigger` / `350` / `37000` | 壳温诱骗：电池 ≥35.0℃ 时上报 37.0℃，`always` 档不设触发温度 |
| `CHARGE_SPOOF` / `CHARGE_TRIGGER` | `1` / `300` | 充电中电池 ≥30.0℃ 时保持 `cool_down=0` |
| `CHARGE_AB` | `0` | 每次充电交替「保持 cool_down=0」与「不干预」，日志标 `ab=on/off` |
| `FPS_UNLOCK` / `RATE_UNLOCK` / `FPS_MAX` | `1` / `1` / `144` | 帧率与刷新率补丁，**下次开机生效** |
| `GUARD_TRIGGER` / `GUARD_RELEASE` | `520` / `470` | 充电时的护栏（单位 0.1℃） |
| `GUARD_TRIGGER_GAME` / `GUARD_RELEASE_GAME` | `520` / `470` | 非充电时的护栏 |
| `GUARD_VALUE_MIN` / `GUARD_OFFSET` | `50000` / `8000` | 护栏上报值 `max(50.0℃, 电池+8.0℃)`，封顶 60.0℃ |
| `THERMAL_UNLOCK` / `THERMAL_DELTA` / `THERMAL_CAP` | `0` / `5000` / `97000` | 温度墙解锁，安装时可选 |
| `CDEV_UNLOCK` / `CDEV_GUARD` | `0` / `520` | 冷却设备直控，与上一条同一个安装选项 |
| `CDEV_EXTRA` | `1` | 除 `cpu-cluster*` 外，是否也钉住 `cpufreq-cpu0`/`cpufreq-cpu6`/`gpu`/`kgsl`/`display-fps` |
| `FREQ_FLOOR` | `0` | 把各 CPU 策略的 `scaling_max_freq` 补写到硬件上限。**本机型实测无效**（用户态写不进该文件，见「已知限制」），默认关闭 |
| `ADAPTIVE` / `STANDBY` / `TELEMETRY` / `TICK` / `CHARGE_SAMPLE` | `1` / `1` / `1` / `0.2` / `5` | 节拍、待机统计、遥测开关与采样密度 |
| `SB_GAP_MIN` | `90` | 设备挂起超过这么久、醒来又没看到「熄屏」时，按电量差补记一条待机；`0` 关闭 |

## 运行行为

| 条件 | 动作 |
|---|---|
| 电池 ≥35.0℃ 且未触护栏 | 壳温上报 37.0℃，0.2 秒一轮维持 |
| 充电中电池 ≥30.0℃ 且未触护栏 | 持续把 `cool_down` 写成 0 |
| 电池 ≥52.0℃ | 停止诱骗，上报 `max(50.0℃, 电池+8.0℃)`（封顶 60.0℃），交回内核 |
| 降到 ≤47.0℃ | 恢复诱骗，并补写一次温度墙 |
| `THERMAL_UNLOCK=1` | `cpu-*` / `sys-therm-*` 里 **85.0~96.0℃** 的 trip 抬 +5.0℃（封顶 97.0℃），每 30 tick 复核补写。范围必须覆盖到 96℃，否则 `sys-therm` 的 93/95℃ 会先于 CPU 的 97℃ 触发，冷却设备照样压频 |
| `CDEV_UNLOCK=1` | 电池 <52.0℃ 且结温 <96.0℃ 时把 `cpu-cluster*` 及（`CDEV_EXTRA=1` 时）`cpufreq-cpu0`/`cpufreq-cpu6`/`gpu`/`kgsl`/`display-fps` 的 `cur_state` 钉 0；结温到 96.0℃ 立刻放手，回落到 91.0℃ 才重新接管（5℃ 回差） |
| `FREQ_FLOOR=1` | 同上条件下，把每个 CPU 策略的 `scaling_max_freq` 写回硬件上限——厂商 daemon 会绕过冷却设备直接写这个文件，只钉 cdev 堵不住；日志记 `FREQ-FLOOR` |

## 日志

都在 `/data/adb/modules/thermal_genie/logs/`。

| 文件 | 内容 |
|---|---|
| `genie.log` | 启动自检 `CAPS`、状态切换、护栏、心跳异常、充电起止、温度墙补写（`THERMAL-FIX`）、冷却直控（`CDEV-PIN` / `CDEV-HOLD` / `CDEV-RELEASE` / `CDEV-RESUME`） |
| `telemetry-YYYYMMDD.log` | 按天：`TEL` 状态行约 5 秒一条，`CHG` 充电功率点约 1 秒一个，`CAL` 每次充电开始记原始读数，`THR` 频率上限一变就记，CDS2 行记下这一轮到底哪几个冷却设备非零（形如 cd8=3，编号对照见 genie.log 的 CDSMAP 行） |
| `charging.log` | 每次充电一条汇总：时长 / 起止电量 / 峰值 / 均值 / 最大电流 / 最高温 / 护栏是否触发 |
| `standby.log` | 每次待机一条汇总：`dur` 时长、`cap` 起止电量、`samples`、`sph`（每小时采样数，看深睡比例）、`avg`、`rate`（≥30 分钟才算）、`cpu`。行尾 `src=gap` 表示这条是按挂起时长补记的，`resume=1` 表示跨过一次守护进程重启 |
| `standby-YYYYMMDD.log` | 每次待机结束一行 `WAKE`：按持锁时长排序的唤醒源 top5 |
| `post-fs.log` | 开机挂载帧率补丁的结果。每行带 `up=秒数`——开机早期系统时钟可能还没校准，用它在时间戳不可信时排先后 |

管理器里的「执行」按钮是只读状态页：版本、数据源自检、壳温、电池温度/功率、进程、补丁是否生效、最近待机与充电、模块自耗。

## 实测（一加 Ace 5 Pro / PKR110 / ColorOS 16，2026-11）

降频是三层叠出来的，只拆一层没用：

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

## 已知限制

- **不要读 `/sys/power/wakeup_count`**：`pm_get_wakeup_count()` 会拿挂起锁，熄屏瞬间读它会进不可打断的 D 状态，`timeout` 和 `kill -9` 都救不了（真机两次）。
- 熄屏深睡时进程会被挂起，`samples` 远小于时长属正常；判断耗电看 `rate`。
- `/vendor/etc` 被 `mountify` 用 overlay 覆盖，`post-fs-data` 挂的补丁会被盖住，靠 `service.sh` 开机后 `cmp` 校验补挂。
- 帧率补丁开机约 10 秒后才生效；显示服务若在更早时候读了该表，本次开机可能不生效（未复现）。
- 部分 `trip_point_*_temp` 会被系统周期性改回，靠守护进程复核补写。
- **CPU 上限不是软件层能改的**（2026-11 在 PKR110 上实测三重证据）：
  1. kprobe `store_scaling_max_freq` 采集 25 秒 **零命中** —— 用户态（含 root）写这个文件根本到不了 store，VFS 层就被拒；
  2. 同一窗口 `cpufreq_set_policy` 的调用者全是 `kworker`（`process_scheduled_works` → `worker_thread`），没有用户态帧；
  3. 上游是 `16430000.qcom,cpucp` —— 高通 **CPuCP（CPU Control Processor）固件**，走 SCMI 下发限制，内核只是把结果反映到 `scaling_max_freq`。

  停用前的读数：结温 43~47℃、所有冷却设备为 0 时，`cpu7` 仍被压在 1.69GHz、`cpu0~5` 压在 2.4GHz。`FREQ_FLOOR` 这条补写在本机型无效，**默认关闭**。
- **游戏内上限单独一套，也改不动**：把 `/my_product/etc/extension/sys_game_manager_config.json` 的 `adp.cpu_level` 8 档全换成满血（`3532800,4320000,3532800`）、`gpu_level` 全换 1100000000，bind-mount 生效后确认文件已替换：**非游戏场景上限回到 3.53/4.32GHz，但一进游戏立刻被压回 1.55~2.84GHz**（这些值不在改后的表里）。那张表本身最高档也只有 2.47GHz。
- **GPU 是例外**：`kgsl/devfreq/max_freq` 可写且能保持（实测写 1100000000 后 6 秒不掉），`GPU_MAX` 补的就是这条；`thermal_pwrlevel` 写入会被拒。
- `display-fps` 被钉住时系统无法用降刷新率来散热，`CDEV_GUARD`/96℃ 两道闸之外不再有别的散热手段，叠加热风险要自己判断。
- 熄屏时 `scaling_max_freq` 被压到 57~61% 是**省电策略**，不是温控。
- 旧模块（murongruyan）的 `frozen`/`unfrozen` cgroup 方案在 ColorOS 16 上已空转，未采用。
- 充电表改写（`CHARGE_TEMP_SHIFT`）在 v0.4 移除，当前版本不含。

## 关键常量（实测得出，别凭猜改）

- `current_now` 单位 **mA**，**负值表示充电**；`voltage_now` 单位 **µV**
- 功率 = `|current_now| × voltage_now / 1e6` → **mW**；驱动按**单芯**上报，整包约为记录值 **×2**
- `/sys/class/power_supply/battery/temp` 单位 **0.1℃**
- `/proc/shell-temp` 写入格式是 `通道 值`，取**毫摄氏度**，四个通道（0~3）都要写
- `power_now` 与 `cur×v` 相差 1000 倍，**已弃用**（只在 `CAL` 行留原始值对照）

## 开发

```powershell
pwsh -File .\build.ps1     # 或 powershell -File .\build.ps1
```

输出 `dist\Thermal-Genie-<version>.zip`，打印条目、大小与 SHA256。打包后自检：**条目必须用 `/` 分隔**（Windows 的 `CreateFromDirectory` 会写 `\`，Android 上会变成文件名的一部分，安装器就找不到 `bin/genie.sh`），8 个必需条目齐全，不过就报错。

离线回归（把 sysfs 路径重定向到临时文件，不需要手机）：

| 脚本 | 验什么 |
|---|---|
| `run12` | 待机会话落盘：重启续算（`resume=1`）、挂起补账（`src=gap`）、跨重启丢弃、负速率写 `n/a` |
| `run13` | 安装两道题：一次按键只答一题、不按键保持默认、旧 config 与日志保留、卡片描述跟随状态 |
| `run14` | 温度墙与冷却直控的批量读取版：trip 0~7 生效、trip_9 与非目标 zone 不动、只有 `cpu-cluster*` 被写 0 |
| `run15` | 冷却直控的 5℃ 回差：97℃ 不接管、92℃ 仍不接管、90℃ 才重新钉住 |
| `run6` / `run7` / `run9` / `run10` / `run11` | 充电汇总、功率换算、待机会话、自适应节拍、字段完整性 |
| `check-readme.sh` | README 与源码一致性（配置键、节点路径、日志字段、阈值、语法） |

```powershell
# Windows 上用 Git Bash
cd test
bash run13.sh
```

注意：`run6` / `run7` / `run9` 用真实时间窗驱动，Windows 上 fork 约 50ms、`sleep 0.02` 实测约 77ms，会错过时间窗——这三条请在 Linux 上跑。

## 版本历史

| 版本 | 变更 |
|---|---|
| v1.0.4 | 安装说明重写；卡片描述按实际状态生成；守护进程热路径提速（插电态 CPU 21%→2.5%）；冷却直控加 5℃ 回差 |
| v1.0.3 | 安装时可选温度墙/冷却直控；不按键不再改写用户设置 |
| v1.0.2 | 升级保留日志；跨重启不再算错待机；`rate` 不再出坏值 |
| v1.0.1 | 待机会话落盘：重启续算（`resume=1`）、挂起补账（`src=gap`） |
| v1.0.0 | 温度墙 + 冷却直控、统一 52.0/47.0 护栏、降频遥测；更名 Thermal Genie for ColorOS 16 |
| v0.8.4 | 移除 `wakeup_count` 读取（会卡死） |
| v0.7.x | 待机会话汇总、唤醒源明细、自适应节拍、汇总口径修正 |
| v0.6.x | 充电采集与会话汇总、按天遥测、功率单位与写入校验修正 |
| v0.5 | 修复 mountify overlay 遮挡：注入 lowerdir + 开机后校验补挂 |
| v0.4 | 音量键选择、帧率解锁、双档护栏 |
| v0.3 | 初版：壳温诱骗 + `cool_down` 看门狗 + 护栏 |
