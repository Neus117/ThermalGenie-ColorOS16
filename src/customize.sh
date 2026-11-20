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
ui_print "两个开关，各自独立；不按键 = 保持当前设置"
ui_print " "
ui_print "【1/2】游戏帧率解锁（默认 $(show_onoff "$(get_conf FPS_UNLOCK)")）"
ui_print "音量+ 开  |  音量- 关"
ui_print "开：解锁游戏 fps=144"
ui_print "关：保持默认限制"
sel=$(read_vol)
case "$sel" in
  up|down)
    [ "$sel" = up ] && FPSV=1 || FPSV=0
    set_conf FPS_UNLOCK "$FPSV"
    set_conf RATE_UNLOCK "$FPSV"
    ui_print "已选择：$(show_onoff "$FPSV")"
    ;;
  *)
    ui_print "已选择：保持（$(show_onoff "$(get_conf FPS_UNLOCK)")）"
    ;;
esac

ui_print " "
TUN=$(get_conf THERMAL_UNLOCK)
ui_print "【2/2】修改温度墙与冷却直控（默认 $(show_onoff "$TUN")）"
ui_print "音量+ 开  |  音量- 关"
ui_print "开：CPU 最高可跑到 96°C"
ui_print "关：保持默认限制"
sel=$(read_vol)
case "$sel" in
  up)
    set_conf THERMAL_UNLOCK 1
    set_conf CDEV_UNLOCK 1
    ui_print "已选择：开"
    ;;
  down)
    set_conf THERMAL_UNLOCK 0
    set_conf CDEV_UNLOCK 0
    ui_print "已选择：关"
    ;;
  *)
    ui_print "已选择：保持（$(show_onoff "$TUN")）"
    ;;
esac
sh "$MP/bin/desc.sh" 2>/dev/null

chmod 0755 "$MP/bin/genie.sh" "$MP/bin/desc.sh" "$MP/service.sh" "$MP/action.sh" "$MP/uninstall.sh" "$MP/customize.sh" "$MP/post-fs-data.sh" 2>/dev/null
chmod 0644 "$MP/module.prop" "$CFG" 2>/dev/null
mkdir -p "$MP/logs" "$MP/work" 2>/dev/null
chmod 0755 "$MP/logs" "$MP/work" 2>/dev/null
rm -rf /data/local/tmp/.thermal_genie.lock 2>/dev/null

ui_print " "
ui_print "模块工作时："
ui_print "电池 ≥35°C：把「手机壳温」上报成 37°C"
ui_print "（系统按壳温决定要不要降频，就不提前降）"
ui_print "充电中电池 ≥30°C：不再压低充电功率"
ui_print " "
ui_print "安全护栏："
ui_print "电池 52°C：停止上述改写，交回系统处理"
ui_print "降到 47°C：恢复上述改写"
ui_print " "
ui_print "日志：/data/adb/modules/thermal_genie/logs/"
ui_print "配置：同目录 config.conf，改完 10 秒后生效"
ui_print "刷入模块需重启生效（帧率补丁要开机才挂上）"
ui_print "卸载即恢复原状，干净无残留"
exit 0