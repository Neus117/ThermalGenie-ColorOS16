#!/system/bin/sh
# Thermal Genie - 安装脚本（Magisk / KernelSU 通用）
# 版本号从 module.prop 读，不在本文件写死
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
MP="${MODPATH:-${0%/*}}"
VER=$(sed -n 's/^version=//p' "$MP/module.prop" 2>/dev/null | head -n1)
[ -z "$VER" ] && VER="unknown"

[ -d "$MP" ]              || { ui_print "- 找不到模块目录，安装中止"; exit 1; }
[ -f "$MP/bin/genie.sh" ] || { ui_print "- 缺少 bin/genie.sh，安装中止"; exit 1; }
[ -f "$MP/config.conf" ]  || { ui_print "- 缺少 config.conf，安装中止"; exit 1; }

ui_print " "
ui_print "==================== Thermal Genie $VER ===================="
ui_print "是否解锁游戏帧率？"
ui_print "  [音量+]  开启：温控档 fps 统一 144 + 刷新率解除锁定"
ui_print "  [音量-]  不开启：完全不碰这两个系统文件"
ui_print "  （10 秒内不按，默认开启）"
ui_print "==========================================================="

read_vol() {
  # 没有 timeout 或 getevent 时直接放弃选择用默认值，避免 getevent 无超时把安装卡死
  if ! command -v timeout >/dev/null 2>&1 || ! command -v getevent >/dev/null 2>&1; then
    echo no-input
    return
  fi
  for i in 1 2 3 4 5; do
    ev=$(timeout 3 getevent -qlc 1 2>/dev/null | awk '/KEY_VOLUME/{print $3; exit}')
    case "$ev" in
      KEY_VOLUMEUP)   echo up;     return ;;
      KEY_VOLUMEDOWN) echo down;   return ;;
    esac
  done
  echo timeout
}

sel=$(read_vol)
[ "$sel" = no-input ] && ui_print "  （本机缺 timeout/getevent，跳过选择，按默认开启）"
[ "$sel" = timeout ]  && ui_print "  （10 秒内未按键，按默认开启）"
case "$sel" in
  down) FPSV=0 ;;
  up)   FPSV=1 ;;
  *)    FPSV=1 ;;
esac

if ! grep -q '^FPS_UNLOCK=' "$MP/config.conf" 2>/dev/null; then
  echo "FPS_UNLOCK=$FPSV" >> "$MP/config.conf"
else
  sed -i "s/^FPS_UNLOCK=.*/FPS_UNLOCK=$FPSV/" "$MP/config.conf" 2>/dev/null
fi
if ! grep -q '^RATE_UNLOCK=' "$MP/config.conf" 2>/dev/null; then
  echo "RATE_UNLOCK=$FPSV" >> "$MP/config.conf"
else
  sed -i "s/^RATE_UNLOCK=.*/RATE_UNLOCK=$FPSV/" "$MP/config.conf" 2>/dev/null
fi

chmod 0755 "$MP/bin/genie.sh" "$MP/service.sh" "$MP/action.sh" "$MP/uninstall.sh" "$MP/customize.sh" "$MP/post-fs-data.sh" 2>/dev/null
chmod 0644 "$MP/module.prop" "$MP/config.conf" 2>/dev/null
mkdir -p "$MP/logs" "$MP/work" 2>/dev/null
chmod 0755 "$MP/logs" "$MP/work" 2>/dev/null
rm -rf /data/local/tmp/.thermal_genie.lock 2>/dev/null

case "$FPSV" in
  1) ui_print "- 游戏帧率解锁：开启" ;;
  0) ui_print "- 游戏帧率解锁：关闭（可按音量- 重装修改）" ;;
esac
ui_print "- 壳温诱骗：电池 >=35.0C 时把壳温上报为 37.0C"
ui_print "- 充电解锁：充电且 >=30.0C 时保持 cool_down=0"
ui_print "- 安全护栏：统一 52.0C 触发 / 47.0C 恢复（充电与游戏同阈值）"
ui_print "- 触发时上报 max(50.0C, 电池+8.0C)，停写后由内核接管真实值"
ui_print "- 自动记录：充电时每秒采样功率，每次充电结束写一条汇总"
ui_print "  日志：/data/adb/modules/thermal_genie/logs/"
ui_print "  - charging.log  每次充电的时长/峰值/均值/最高温"
ui_print "  - telemetry-YYYYMMDD.log  按天的完整采样"
ui_print "- 配置：/data/adb/modules/thermal_genie/config.conf（改完 10 秒生效）"
ui_print "- 卸载即恢复：所有改动都是运行时挂载，不写坏固件文件"
ui_print "- 温度墙解锁：CPU 结温 92→97C、sys-therm 88/90→93/95C（config: THERMAL_UNLOCK）"
ui_print "- 冷却设备直控：电池<52C 时把 cpu-cluster 降频钉住（config: CDEV_UNLOCK）"
ui_print "- 温度墙与冷却直控均为 sysfs 运行时写入，重启恢复；默认关闭，本机已在 config 中开启"
ui_print "- 重启后生效"
exit 0
