#!/system/bin/sh
# Thermal Genie - 管理器「动作」按钮：只读状态（不做任何修改）
MD=/data/adb/modules/thermal_genie
VER=$(sed -n 's/^version=//p' "$MD/module.prop" 2>/dev/null | head -n1)
[ -z "$VER" ] && VER="?"
W="$MD/work"
NB=/sys/class/power_supply/battery

echo "===== Thermal Genie $VER ====="
CAPS=$(grep "CAPS" "$MD/logs/genie.log" 2>/dev/null | tail -1)
[ -z "$CAPS" ] && CAPS="（还没有自检记录）"
echo "数据源     : ${CAPS#*] }"
echo "壳温上报   : $(cat /proc/shell-temp 2>/dev/null)"
echo "电池温度   : $(cat $NB/temp 2>/dev/null)"
# 功率现算：驱动按单芯上报，power_now 与 cur×v 差 1000 倍，弃用
CUR=$(cat $NB/current_now 2>/dev/null)
VOL=$(cat $NB/voltage_now 2>/dev/null)
MAC=${CUR#-}
PW="?"
if [ -n "$MAC" ] && [ -n "$VOL" ]; then PW=$((MAC * VOL / 1000000))mW; fi
echo "电池功率   : ${PW}（单芯视在，整包约 ×2）"
echo "充电状态   : $(cat $NB/status 2>/dev/null)"
echo "cool_down  : $(cat /sys/class/oplus_chg/battery/cool_down 2>/dev/null)"
echo "守护进程   : $(pgrep -f 'thermal_genie/bin/[g]enie.sh' | tr '\n' ' ')"
echo "监管进程   : $(pgrep -f 'thermal_genie/[s]ervice.sh' | tr '\n' ' ')"
echo "A/B 档位   : $(cat $MD/.ab_state 2>/dev/null)"

if [ -f "$W/thermallevel_to_fps.xml" ]; then
  if cmp -s "$W/thermallevel_to_fps.xml" /vendor/etc/display/thermallevel_to_fps.xml 2>/dev/null; then
    echo "帧率解锁   : 已生效（$(grep -c 'fps="144"' /vendor/etc/display/thermallevel_to_fps.xml 2>/dev/null) 处 fps=144）"
  else
    echo "帧率解锁   : 未生效（读到的仍是原文件）"
  fi
else
  echo "帧率解锁   : 已关闭"
fi

if [ -f "$W/refresh_rate_config.xml" ]; then
  cmp -s "$W/refresh_rate_config.xml" /my_product/etc/refresh_rate_config.xml 2>/dev/null \
    && echo "刷新率解锁 : 已生效" || echo "刷新率解锁 : 未生效"
else
  echo "刷新率解锁 : 已关闭"
fi

[ -f "$MD/DISABLED" ] && echo "模块状态   : 已停用（DISABLED 存在）"

echo "===== 最近 3 次待机 ====="
tail -3 "$MD/logs/standby.log" 2>/dev/null
[ -s "$MD/logs/standby.log" ] || echo "（还没有完成的待机会话）"

echo "===== 模块自身开销 ====="
P=$(pgrep -f 'thermal_genie/bin/[g]enie.sh' | head -1)
if [ -n "$P" ]; then
  awk '{printf "累计 CPU: %.2f 秒（含义：100 ticks = 1 秒）\n", ($14+$15+$16+$17)/100}' "/proc/$P/stat" 2>/dev/null
else
  echo "守护进程未运行"
fi

echo "===== 最近 3 次充电 ====="
tail -3 "$MD/logs/charging.log" 2>/dev/null
[ -s "$MD/logs/charging.log" ] || echo "（还没有完成的充电记录）"

echo "===== 今日遥测文件 ====="
ls -lh "$MD"/logs/telemetry-*.log 2>/dev/null | tail -3

echo "===== 最近事件 ====="
tail -5 "$MD/logs/genie.log" 2>/dev/null
