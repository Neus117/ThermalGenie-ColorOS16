#!/bin/bash
# 验证 thermal 复核与冷却直控的「批量读取」版本：行为必须和逐个 cat 的版本一致
#   - cpu-* 与 sys-therm-* 的 85~92℃ trip 抬 +5000、封顶 98000
#   - 只处理 trip 0~7；trip_9 不许被碰
#   - 非 cpu-*/sys-therm-* 的 zone 不许被碰
#   - cpu-cluster* 的 cur_state 非 0 时写 0；其余冷却设备不许动
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg15
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin $T/th

mkzone() { # num type temp t0 t1 t2 t3 t9
  z=$T/th/thermal_zone$1; mkdir -p "$z"
  echo "$2" > "$z/type"; echo "$3" > "$z/temp"
  echo "$4" > "$z/trip_point_0_temp"; echo "$5" > "$z/trip_point_1_temp"
  echo "$6" > "$z/trip_point_2_temp"; echo "$7" > "$z/trip_point_3_temp"
  echo "$8" > "$z/trip_point_9_temp"
}
mkzone 9  cpu-0-2-0   28000 92000 105000 118000 125000 90000
mkzone 68 sys-therm-0 22000 125000 125000 88000  90000  90000
mkzone 69 sys-therm-1 22000 93000  95000  96000  99000  90000
mkzone 5  battery     30000 92000 92000 92000 92000 90000

mkcdev() { # num type cur max
  c=$T/th/cooling_device$1; mkdir -p "$c"
  echo "$2" > "$c/type"; echo "$3" > "$c/cur_state"; echo "$4" > "$c/max_state"
}
mkcdev 31 cpu-cluster0 12 15
mkcdev 32 cpu-cluster1 0 15
mkcdev 40 battery 7 10

echo 25000 > $T/z2; echo 25000 > $T/z22

sed -e "s#^CDIR=.*#CDIR=$T/th#" \
    -e "s#^ZCPU=.*#ZCPU=$T/z2#" \
    -e "s#^ZCPUSS=.*#ZCPUSS=$T/z22#" \
    -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
    -e "s#^UPTIME=.*#UPTIME=$T/uptime#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 12 ]; do#' \
    -e 's#^  sleep "\$TICK"#  sleep 0.02#' \
    "$SRC" > $T/bin/genie.sh

cat > $T/fakebin/dumpsys <<EOF
#!/bin/sh
echo "mWakefulness=Awake"
EOF
chmod +x $T/fakebin/dumpsys
printf 'TICK=0.2\nTELEMETRY=0\nADAPTIVE=0\nSTANDBY=0\nCHARGE_SAMPLE=1\nTHERMAL_UNLOCK=1\nTHERMAL_DELTA=5000\nTHERMAL_CAP=97000\nCDEV_UNLOCK=1\nCDEV_GUARD=520\n' > $T/config.conf
echo 330 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
echo Discharging > $T/st; echo 500 > $T/cur; echo 4000000 > $T/vol
echo 60 > $T/cap; : > $T/none; echo "3600.00 7200.00" > $T/uptime

PATH=$T/fakebin:$PATH sh $T/bin/genie.sh > $T/out.txt 2>&1
echo "--- genie.log ---"; cat $T/logs/genie.log

ck "cpu-0-2-0 trip0 92000→97000"    '[ "$(cat $T/th/thermal_zone9/trip_point_0_temp)" = 97000 ]'
ck "sys-therm-0 trip2 88000→93000"  '[ "$(cat $T/th/thermal_zone68/trip_point_2_temp)" = 93000 ]'
ck "sys-therm-0 trip3 90000→95000"  '[ "$(cat $T/th/thermal_zone68/trip_point_3_temp)" = 95000 ]'
ck "trip_9 不被修改（90000）"        '[ "$(cat $T/th/thermal_zone9/trip_point_9_temp)" = 90000 ]'
ck "93℃ trip 抬到封顶 97℃"          '[ "$(cat $T/th/thermal_zone69/trip_point_0_temp)" = 97000 ]'
ck "96℃ trip 也抬到封顶 97℃"        '[ "$(cat $T/th/thermal_zone69/trip_point_2_temp)" = 97000 ]'
ck "99℃ trip 超出范围不动"           '[ "$(cat $T/th/thermal_zone69/trip_point_3_temp)" = 99000 ]'
ck "battery zone 不被修改"           '[ "$(cat $T/th/thermal_zone5/trip_point_0_temp)" = 92000 ]'
ck "cpu-cluster0 12→0"               '[ "$(cat $T/th/cooling_device31/cur_state)" = 0 ]'
ck "cpu-cluster1 保持 0"             '[ "$(cat $T/th/cooling_device32/cur_state)" = 0 ]'
ck "battery 冷却设备不动（7）"        '[ "$(cat $T/th/cooling_device40/cur_state)" = 7 ]'
ck "日志里有 CDEV-PIN cpu-cluster0"  'grep -q "CDEV-PIN cpu-cluster0 12 -> 0" $T/logs/genie.log'
ck "日志里有 THERMAL-FIX"            'grep -q "THERMAL-FIX 补写" $T/logs/genie.log'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
