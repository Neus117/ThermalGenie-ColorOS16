#!/system/bin/sh
# Thermal Genie - 管理器「动作」按钮：只读状态（不做任何修改）
MD=/data/adb/modules/thermal_genie
VER=$(sed -n 's/^version=//p' "$MD/module.prop" 2>/dev/null | head -n1)
[ -z "$VER" ] && VER="?"
W="$MD/work"
NB=/sys/class/power_supply/battery

echo "===== Thermal Genie $VER ====="
CAPS=$(grep "CAPS" "$MD/logs/genie.log" 2>/dev/null | tail -1)
if [ -n "$CAPS" ]; then
  ck() { v=$(printf '%s' "$CAPS" | sed -n "s/.*$1=\([01]\).*/\1/p"); [ "$v" = 1 ] && echo "✓" || echo "✗"; }
  echo "数据源自检 : 唤醒源$(ck wakeup_sources) 挂起统计$(ck suspend_stats) 超时命令$(ck timeout)（不读 wakeup_count）"
else
  echo "数据源自检 : 还没有自检记录"
fi
# /proc/shell-temp 是毫摄氏度；电池温度节点是 0.1℃
ST=$(cat /proc/shell-temp 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | tail -1)
case "$ST" in ''|*[!0-9]*) echo "壳温上报   : 读不到" ;; *) echo "壳温上报   : $((ST / 1000)).$((ST % 1000 / 100))℃" ;; esac
BT=$(cat $NB/temp 2>/dev/null)
case "$BT" in ''|*[!0-9]*) echo "电池温度   : 读不到" ;; *) echo "电池温度   : $((BT / 10)).$((BT % 10))℃" ;; esac
# 功率现算：驱动按单芯上报，power_now 与 cur×v 差 1000 倍，弃用
CUR=$(cat $NB/current_now 2>/dev/null)
VOL=$(cat $NB/voltage_now 2>/dev/null)
MAC=${CUR#-}
PW="?"
if [ -n "$MAC" ] && [ -n "$VOL" ]; then PW=$((MAC * VOL / 1000000))mW; fi
echo "电池功率   : ${PW}（单芯视在，整包约 ×2）"
echo "充电状态   : $(cat $NB/status 2>/dev/null)"
echo "降温档位   : $(cat /sys/class/oplus_chg/battery/cool_down 2>/dev/null)（0 = 不降功率）"
P=$(pgrep -f 'thermal_genie/bin/[g]enie.sh' | tr '\n' ' ')
[ -z "$P" ] && P="未运行"
echo "守护进程   : $P"
P=$(pgrep -f 'thermal_genie/[s]ervice.sh' | tr '\n' ' ')
[ -z "$P" ] && P="未运行"
echo "监管进程   : $P"
AB=$(cat "$MD/.ab_state" 2>/dev/null)
[ "$AB" = on ] && AB="开" || AB="关"
echo "自动 A/B   : ${AB}（每次充电交替开与不干预）"

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

echo "===== 最近 3 次待机 ====="
tail -3 "$MD/logs/standby.log" 2>/dev/null
[ -s "$MD/logs/standby.log" ] || echo "（还没有完成的待机会话）"

echo "===== 模块自身开销 ====="
P=$(pgrep -f 'thermal_genie/bin/[g]enie.sh' | head -1)
if [ -n "$P" ]; then
  awk '{printf "累计 CPU：%d 秒（自上次启动守护进程起）\n", ($14+$15+$16+$17)/100}' "/proc/$P/stat" 2>/dev/null
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
