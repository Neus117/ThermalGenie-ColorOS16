#!/system/bin/sh
# Thermal Genie - 安装脚本（Magisk / KernelSU 通用）
# 版本号从 module.prop 读，不在本文件写死
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
MP="${MODPATH:-${0%/*}}"
VER=$(sed -n 's/^version=//p' "$MP/module.prop" 2>/dev/null | head -n1)
[ -z "$VER" ] && VER="unknown"
CFG="$MP/config.conf"

[ -d "$MP" ]              || { ui_print "- 找不到模块目录，安装中止"; exit 1; }
[ -f "$MP/bin/genie.sh" ] || { ui_print "- 缺少 bin/genie.sh，安装中止"; exit 1; }
[ -f "$CFG" ]             || { ui_print "- 缺少 config.conf，安装中止"; exit 1; }

# 升级时先把用户已有的 config.conf 覆盖进来（保住温度墙/冷却直控/护栏等手改值），
# 必须在下面写音量键选择之前做，否则 cp 会把刚写入的选择冲掉。
OLDCFG=/data/adb/modules/thermal_genie/config.conf
if [ -f "$OLDCFG" ] && [ "$CFG" != "$OLDCFG" ]; then
  cp -f "$OLDCFG" "$CFG"
  ui_print "- 已保留原有 config.conf（升级不覆盖配置）"
fi

# 升级时把旧日志一并带过来：换模块目录会删掉 logs/，几天几周的待机与遥测记录说没就没
OLDLOGS=/data/adb/modules/thermal_genie/logs
if [ -d "$OLDLOGS" ] && [ "$OLDLOGS" != "$MP/logs" ]; then
  mkdir -p "$MP/logs" 2>/dev/null
  cp -f "$OLDLOGS"/*.log "$MP/logs"/ 2>/dev/null
  ui_print "- 已保留原有日志（logs/*.log）"
fi

# ---- 安装选项 ----
# 只认音量键；不按键就保持现有配置（新装即包里的默认值），不强行改写用户的选择
get_conf() { sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -n1; }
set_conf() {
  sed -i "/^$1=/d" "$CFG" 2>/dev/null
  # 手改过的 config 末行可能没有换行，直接 append 会粘在上一行上
  [ -n "$(tail -c 1 "$CFG" 2>/dev/null)" ] && printf '\n' >> "$CFG"
  printf '%s=%s\n' "$1" "$2" >> "$CFG"
}
show_onoff() { [ "$1" = 1 ] && echo 开 || echo 关; }

read_vol() {
  # 没有 timeout 或 getevent 时直接放弃选择（保持现有配置），避免 getevent 无超时把安装卡死
  if ! command -v timeout >/dev/null 2>&1 || ! command -v getevent >/dev/null 2>&1; then
    echo no-input
    return
  fi
  for i in 1 2 3 4 5; do
    # 只认「按下」那一下（$4 == DOWN）。一次按键会同时产生 DOWN 和 UP 两条事件，
    # 以前只匹配键名，结果同一个按压能连答两个问题——第二个问题跟着第一个走。
    ev=$(timeout 3 getevent -qlc 1 2>/dev/null | awk '/KEY_VOLUME/ && $4=="DOWN" {print $3; exit}')
    case "$ev" in
      KEY_VOLUMEUP)   drain_vol; echo up;     return ;;
      KEY_VOLUMEDOWN) drain_vol; echo down;   return ;;
    esac
  done
  echo timeout
}

# 把这次按压剩下的 UP/重复事件读掉，避免下一个问题把它当成新的按键
drain_vol() {
  command -v timeout >/dev/null 2>&1 || return 0
  timeout 1 getevent -qlc 20 >/dev/null 2>&1
  return 0
}

ui_print " "
ui_print "==========================================================="
ui_print "  KSU-NEUS117 · Thermal Genie $VER"
ui_print "==========================================================="
ui_print "【1/2】是否解锁游戏帧率？（当前：$(show_onoff "$(get_conf FPS_UNLOCK)")）"
ui_print "  [音量+]  开启：温控档 fps 统一 144，刷新率不再锁 60/90"
ui_print "  [音量-]  关闭：完全不碰这两个系统文件"
ui_print "  （10 秒内不按 = 保持当前设置）"
ui_print "==========================================================="
sel=$(read_vol)
case "$sel" in
  up|down)
    [ "$sel" = up ] && FPSV=1 || FPSV=0
    set_conf FPS_UNLOCK "$FPSV"
    set_conf RATE_UNLOCK "$FPSV"
    ui_print "- 游戏帧率解锁：$(show_onoff "$FPSV")"
    ;;
  *)
    ui_print "- 游戏帧率解锁：保持当前设置（$(show_onoff "$(get_conf FPS_UNLOCK)")）"
    ;;
esac

ui_print " "
TUN=$(get_conf THERMAL_UNLOCK)
ui_print "【2/2】是否启用温度墙解锁 + 冷却设备直控？（当前：$(show_onoff "$TUN")）"
ui_print "  [音量+]  开启：10 个 CPU 核 trip 抬到 97℃，并禁止 cpu-cluster 降频"
ui_print "           代价：芯片会真跑到 96℃ 左右，长期用加速电池老化"
ui_print "  [音量-]  关闭：保留内核原始降频行为"
ui_print "  （10 秒内不按 = 保持当前设置）"
ui_print "==========================================================="
sel=$(read_vol)
case "$sel" in
  up)
    set_conf THERMAL_UNLOCK 1
    set_conf CDEV_UNLOCK 1
    ui_print "- 温度墙/冷却直控：开启（电池 52.0℃ 或结温 96℃ 自动交回内核）"
    ;;
  down)
    set_conf THERMAL_UNLOCK 0
    set_conf CDEV_UNLOCK 0
    ui_print "- 温度墙/冷却直控：关闭"
    ;;
  *)
    ui_print "- 温度墙/冷却直控：保持当前设置（$(show_onoff "$TUN")）"
    ;;
esac

# 管理器卡片只认 module.prop 的 description，那里是静态文案；
# 按刚才的选择（以及保留下来的旧配置）重写一句「当前：…」，别让卡片和实际状态打架
sh "$MP/bin/desc.sh" 2>/dev/null

chmod 0755 "$MP/bin/genie.sh" "$MP/bin/desc.sh" "$MP/service.sh" "$MP/action.sh" "$MP/uninstall.sh" "$MP/customize.sh" "$MP/post-fs-data.sh" 2>/dev/null
chmod 0644 "$MP/module.prop" "$CFG" 2>/dev/null
mkdir -p "$MP/logs" "$MP/work" 2>/dev/null
chmod 0755 "$MP/logs" "$MP/work" 2>/dev/null
rm -rf /data/local/tmp/.thermal_genie.lock 2>/dev/null

ui_print " "
ui_print "- 壳温诱骗：电池 ≥35.0℃ 时把壳温上报为 37.0℃"
ui_print "- 充电解锁：充电且 ≥30.0℃ 时保持 cool_down=0（不限功率）"
ui_print "- 安全护栏：电池 52.0℃ 停写 / 47.0℃ 恢复（充电与非充电同阈值）"
ui_print "- 触发时上报 max(50.0℃, 电池+8.0℃)，交回内核按真实温度接管"
ui_print "- 自动记录：充电功率（每秒）、每次充电汇总、每次待机汇总、降频事件"
ui_print "  日志：/data/adb/modules/thermal_genie/logs/"
ui_print "  - charging.log  每次充电的时长/峰值/均值/最高温"
ui_print "  - standby.log   每次待机的时长/掉电速率/唤醒源"
ui_print "  - telemetry-YYYYMMDD.log  按天的完整采样"
ui_print "- 配置：/data/adb/modules/thermal_genie/config.conf（改完 10 秒生效）"
ui_print "- 温度墙解锁：CPU 结温 92→97℃、sys-therm 88/90→93/95℃（config.conf 的 THERMAL_UNLOCK）"
ui_print "- 冷却设备直控：电池 <52℃ 时禁止 cpu-cluster 降频（config.conf 的 CDEV_UNLOCK）"
ui_print "- 这两项重启后会被内核复位，模块在开机时重新写入"
ui_print "- 以上开关都可以装完之后改 config.conf，不用重装"
ui_print "- 卸载即恢复原状：只写 sysfs 或做运行时挂载，不改写固件文件"
ui_print "- 重启后生效"
exit 0
