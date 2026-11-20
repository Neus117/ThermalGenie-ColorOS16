#!/bin/bash
# v1.0.4 验证：冷却直控的 5℃ 回差
#   A 结温一直 96℃ 以上：不接管（cur_state 保持原值），只记 CDEV-HOLD
#   B 结温 97 → 92 → 90：92 时不接管；降到 90 才 CDEV-RESUME 并重新钉住
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg16
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

setup() { # $1 = 循环轮数
  rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin $T/th
  mkzone() {
    z=$T/th/thermal_zone$1; mkdir -p "$z"
    echo "$2" > "$z/type"; echo "25000" > "$z/temp"
    echo "105000" > "$z/trip_point_0_temp"   # 不在 85~92 区间，不该被改
  }
  mkzone 9 cpu-0-2-0
  mkcdev() { c=$T/th/cooling_device$1; mkdir -p "$c"; echo "$2" > "$c/type"; echo "$3" > "$c/cur_state"; echo 15 > "$c/max_state"; }
  mkcdev 31 cpu-cluster0 12
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
      -e "s#^while :; do#while [ \"\$i\" -lt $1 ]; do#" \
      -e 's#^  sleep "\$TICK"#  sleep 0.02#' \
      "$SRC" > $T/bin/genie.sh
  printf '#!/bin/sh\necho "mWakefulness=Awake"\n' > $T/fakebin/dumpsys
  chmod +x $T/fakebin/dumpsys
  printf 'TICK=0.2\nTELEMETRY=0\nADAPTIVE=0\nSTANDBY=0\nCHARGE_SAMPLE=1\nTHERMAL_UNLOCK=0\nCDEV_UNLOCK=1\nCDEV_GUARD=520\n' > $T/config.conf
  echo 330 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
  echo Discharging > $T/st; echo 500 > $T/cur; echo 4000000 > $T/vol
  echo 60 > $T/cap; : > $T/none; echo "3600.00 7200.00" > $T/uptime
}

echo "===== A 结温一直 97000（<96℃ 才接管，这里该一直放手）====="
setup 20
echo 97000 > $T/z2
PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
grep -E "CDEV-" $T/logs/genie.log || echo "(无 CDEV 日志)"
ck "A 记了 CDEV-HOLD"            'grep -q "CDEV-HOLD" $T/logs/genie.log'
ck "A 没有接管（没有 CDEV-PIN）" '! grep -q "CDEV-PIN" $T/logs/genie.log'
ck "A cur_state 保持原值 12"      '[ "$(cat $T/th/cooling_device31/cur_state)" = 12 ]'

echo
echo "===== B 结温 97000 → 92000 → 90000，回差生效 ====="
setup 90
echo 97000 > $T/z2
( sleep 2; echo 92000 > $T/z2; sleep 2; echo 90000 > $T/z2 ) &
PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
wait
grep -E "CDEV-" $T/logs/genie.log
ck "B 记了 CDEV-HOLD"        'grep -q "CDEV-HOLD" $T/logs/genie.log'
ck "B 记了 CDEV-RESUME"      'grep -q "CDEV-RESUME" $T/logs/genie.log'
ck "B 重新接管后又钉住（cur=0）" '[ "$(cat $T/th/cooling_device31/cur_state)" = 0 ]'
pin=$(grep -n "CDEV-PIN" $T/logs/genie.log | head -1 | cut -d: -f1)
res=$(grep -n "CDEV-RESUME" $T/logs/genie.log | head -1 | cut -d: -f1)
ck "B PIN 发生在 RESUME 之后（92℃ 时没接管）" "[ -n \"$pin\" ] && [ -n \"$res\" ] && [ \"$pin\" -gt \"$res\" ]"

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
