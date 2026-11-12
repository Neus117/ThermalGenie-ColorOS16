# Thermal Genie

ColorOS 16（一加 Ace 5 Pro / PKR110）用的 KernelSU 模块：壳温诱骗、充电降温解锁、游戏帧率解锁、双档安全护栏。

所有改动都是**运行时写入/挂载**，不改写任何固件文件，卸载或重启即恢复。

## 目录结构

```
ThermalGenie\
├── README.md              本文件
├── build.ps1              从 src\ 打包到 dist\（版本号取自 module.prop）
├── src\                   模块源码，打包时内容直接作为 zip 根
│   ├── module.prop        模块信息（管理器里显示的说明）
│   ├── customize.sh       安装脚本：音量键选择 + 设权限 + 打印说明
│   ├── post-fs-data.sh    开机早期：生成并挂载帧率补丁
│   ├── service.sh         开机后：校验补丁是否被读到，接管后拉起守护
│   ├── action.sh          管理器「动作」按钮：只读状态
│   ├── uninstall.sh       卸载清理（含解除 bind mount）
│   ├── config.conf        全部可调参数
│   └── bin\genie.sh       守护进程：诱骗 / 护栏 / 充电采集
├── test\                  离线逻辑验证（把 sysfs 路径重定向到临时文件）
│   ├── run.sh             护栏状态机（v0.2 时代）
│   ├── run4.sh            双档护栏（充电/游戏）
│   ├── run6.sh            充电会话汇总
│   └── run7.sh            功率单位换算（mA×µV→mW）+ 放电样本排除
└── dist\
    ├── Thermal-Genie-v0.6.1.zip    当前版本
    └── archive\                    旧版本 v0.3 ~ v0.6（回滚用）
```

## 构建

```powershell
pwsh -File .\build.ps1
```

输出到 `dist\Thermal-Genie-<version>.zip`，并打印条目与 SHA256。

## 安装

1. 把 `dist\Thermal-Genie-*.zip` 传到手机
2. KernelSU 管理器 → 模块 → 从本地安装
3. 安装时按音量键：
   - **音量+**：开启游戏帧率解锁（温控档 fps → 144）
   - **音量−**：不动帧率相关文件
   - 10 秒不按：默认开启
4. 重启

## 运行行为

| 条件 | 动作 |
|---|---|
| 电池 ≥ 35.0℃ | 把壳温上报为 37.0℃（`/proc/shell-temp`） |
| 充电 且 ≥ 30.0℃ | 持续把 `cool_down` 保持为 0 |
| 电池 ≥ 48.0℃（充电中） | 停止诱骗，上报 max(50.0℃, 电池+8℃)，停写后内核接管 |
| 电池 ≥ 52.0℃（游戏中） | 同上（游戏档阈值更高） |
| 降到 43.0℃ / 47.0℃ | 分别恢复诱骗 |

## 日志（都在 `/data/adb/modules/thermal_genie/logs/`）

| 文件 | 内容 |
|---|---|
| `charging.log` | 每次充电一条汇总：时长/起止电量/峰值/均值/最大电流/最高温/护栏是否触发 |
| `standby.log` | **每次待机一条汇总**：`dur` 时长、`cap` 起止电量、`samples` 采样数、`sph` 每小时采样数（判断深睡比例）、`avg` 醒着时的平均电流、`rate` 每小时掉电（仅 ≥30 分钟才计算）、`cpu` 本段模块自耗 |
| `genie.log` 的 `CAPS` 行 | 启动时自检：`wakeup_sources` / `suspend_stats` / `wakeup_count` 是否可用（每次启动一行，动作按钮也会显示） |
| `standby-YYYYMMDD.log` | 每次待机结束时一行 `WAKE`，记录当次唤醒源计数（`name:count`）；读不到 debugfs 时写 `unavailable` |
| `telemetry-YYYYMMDD.log` | 按天：`TEL` 行 5 秒一次状态，`CHG` 行充电时 1 秒一个功率点，`CAL` 行每次充电开始记录原始值用于校准单位 |
| `genie.log` | 状态切换、护栏触发、充电开始/结束 |
| `post-fs.log` | 开机挂载帧率补丁的结果 |

一次性查看：

```sh
su -c 'M=/data/adb/modules/thermal_genie; tail -5 $M/logs/charging.log; grep -E "GUARD|CHARGE" $M/logs/genie.log | tail -5'
```

## 关键常量（实测得出，不要凭猜改）

- `/sys/class/power_supply/battery/current_now` 单位是 **mA**，**负值表示充电**
- `/sys/class/power_supply/battery/voltage_now` 单位是 **µV**
- 功率 = `|current_now| × voltage_now / 1e6` → **mW**
- `/sys/class/oplus_chg/battery/battery/temp` 单位是 **0.1℃**；`/proc/shell-temp` 写入单位是 **毫摄氏度**
- `power_now` 的读数与 `cur×v` 相差 1000 倍，**不可信，已弃用**

## 充电功率的读数口径（2026-11-08 实测，很重要）

驱动按**单芯**上报电流/电压，整包是双芯：**真实功率 ≈ 记录值 × 2**。

判据：12%→100% 充入约 20.8Wh（6100mAh × 3.87V × 88%）；日志积分只有 8.6Wh。
若记录值是整包功率，48 分钟平均 12.2W 只能送出 9.8Wh——差一倍，不可能；
按 ×2 算是 17.2Wh，与 48 分钟所需的约 26W 平均功率吻合（残余 17% 在 SOC 跳变与充电效率误差内）。

所以 `charging.log` 里的 `peak` / `avg` 是**单芯视在功率**：
峰值 39.3W 对应整包 ≈78.6W，均值 12.2W 对应整包 ≈24.4W。
系统应用（如 Scene）显示的"40W"是同一个口径，不是真的只有 40W。

## 已知限制 / 坑

- **不要读 `/sys/power/wakeup_count`**：`pm_get_wakeup_count()` 会拿挂起锁，熄屏瞬间读它会进入不可打断的 D 状态，`timeout` 和 `kill -9` 都救不了，整个守护进程就此卡死（2026-11-10 真机实测，两次）
- 熄屏深睡时进程会被挂起，`samples` 远小于时长属正常；判断真实耗电要看 `rate`（≥30 分钟才计算）

- `/vendor/etc` 被 `mountify` 用 overlay 覆盖，post-fs-data 阶段挂的帧率补丁会被盖住；靠 `service.sh` 开机后补挂才生效（日志里能看 `verify OK ... (try 1)`）
- 帧率补丁是开机约 10 秒后才真正生效；若显示服务在更早的时候已读取该表，本次开机内可能不生效（待真机验证）
- 旧模块（murongruyan）的 `frozen`/`unfrozen` cgroup 墓碑方案在 ColorOS 16 上已空转，本模块未采用
- 充电表改写（`CHARGE_TEMP_SHIFT`）在 v0.4 被移除，当前版本不含此功能

## 版本历史

| 版本 | 变更 |
|---|---|
| v0.3 | 纯脚本壳温诱骗 + `cool_down` 看门狗 + 护栏 |
| v0.4 | 加音量键选择、游戏帧率解锁（fps 144 + 刷新率解锁）、双档护栏 |
| v0.5 | 修复 mountify overlay 遮挡：注入 lowerdir + 开机后校验补挂 |
| v0.6 | 自动充电采集、会话汇总、按天遥测、可选自动 A/B |
| v0.6.1 | 修复功率单位/符号/缩放三个 bug；`power_now` 弃用，改 cur×v 现算 |
| v0.6.2 | 日志版本号改为从 `module.prop` 读取（此前写死 v0.6，导致无法区分 0.6 与 0.6.1） |
| v0.6.3 | 健壮性：TICK 非法值回落 0.2（防忙循环）、每 5 秒校验写入是否真生效（`SPOOF-FAIL` / `CD-FAIL` / `sp=fake-fail`）、安装时缺 `timeout`/`getevent` 不再阻塞 |
| v0.7.0 | 待机耗电测量：熄屏会话汇总（`standby.log`）+ 唤醒源 top 明细（`standby-YYYYMMDD.log`）+ 自适应节拍（诱骗/充电 5Hz，空闲 1Hz，自耗降 5 倍） |
| v1.0.0 | 温度墙解锁（10 核 trip 97℃ + 冷却设备直控）、统一 52/47 护栏、完整降频遥测；模块更名 Thermal Genie for ColorOS 16 |`n| v0.7.1 | 版本号只保留 `module.prop` 一个来源：安装横幅与动作按钮改为运行时读取，其余文件删掉写死的版本注释 |
| v0.7.2 | 待机汇总口径修正：`rate` 仅 ≥30 分钟计算（短会话写 n/a）、去掉误导性的 `int`、新增 `sph` 采样密度、唤醒源读不到时写 `unavailable` 并尝试挂 debugfs |
| v0.8.4 | 移除 `/sys/power/wakeup_count` 读取（内核 `pm_get_wakeup_count` 会持锁阻塞，熄屏瞬间必然卡死）；待机汇总去掉 `wc`，保留 `ss`/`lf` |
## 实测结论（一加 Ace 5 Pro / PKR110 / ColorOS 16，2026-11）

### 降频机制（实测数据得出）

| 层次 | 阈值 | 证据 |
|---|---|---|
| 内核 thermal trip | CPU 核 92℃ | `cpu-0-2-0` 等 10 个 zone 的 trip0，`THERMAL_FIX` 已抬到 97℃ |
| Cooling device | `cpu-cluster0/1` | 88~92℃ 时 state 升到 11~12，直接压 `scaling_max_freq` |
| Perf HAL | 未定位 | 抬 trip + 直控 cooling 后，仍会在 90~93℃ 压到 2.24 GHz |
| 电池温度 | 52℃（护栏） | 实测两天最高 46℃，从未触发 |

### 效果对照

| 配置 | 大核频率下限（90~93℃ 时） |
|---|---|
| 原始 | 1.69 GHz |
| 仅抬 trip | 1.69 GHz（一半 trip 被系统改回，无效） |
| 抬 trip + 直控 cooling | **2.24 GHz** |

### 关键教训

- `/sys/power/wakeup_count` **不可读**：`pm_get_wakeup_count()` 持锁，熄屏瞬间读取会进入 D 状态，`timeout`/`kill -9` 都无效
- 部分 `trip_point_*_temp` 会被系统周期性改回默认值，需要运行期复核补写
- 熄屏时 `scaling_max_freq` 被压到 57~61% 是**省电策略**，不是温控，不能当降频证据
- 深睡时进程被挂起，`samples` 远小于时长属正常；判断耗电看 `rate`（≥30 分钟才计算）