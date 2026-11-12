#!/bin/bash
# v0.6.3 验证：TICK 校验 + 写回校验（SPOOF-FAIL）
# 注意：不能替换 loop 里的 sleep，否则测不出 TICK 是否生效
SRC="/d/Coding/workspace/ThermalGenie/src/bin/genie.sh"
T=/tmp/tg9
setup() {
  rm -rf $T; mkdir -p $T/bin $T/logs
  sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
      -e "s#^NCD=.*#NCD=$T/cd#" \
      -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
      -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
      -e "s#^LK=.*#LK=$T/lock#" \
      -e 's#^while :; do#while [ "$i" -lt 30 ]; do#' \
      "$SRC" > $T/bin/genie.sh
  echo 360 > $T/tb
  echo 5 > $T/cd
  echo 30000 > $T/ps
  echo -4000 > $T/cur
  echo 4400000 > $T/vol
  echo 40 > $T/cap
  echo Discharging > $T/st
  : > $T/none
}

echo "===== A. 写回校验：可写（期望 vbad=0 sp=fake，无 SPOOF-FAIL）====="
setup
printf 'TICK=0\nTELEMETRY=1\nADAPTIVE=0\nSTANDBY=1\n' > $T/config.conf
rm -rf $T/lock
sh $T/bin/genie.sh 2>/dev/null
echo "日志里的 SPOOF 行数: $(grep -c SPOOF $T/logs/genie.log 2>/dev/null)"
grep "^TEL" $T/logs/telemetry-*.log | tail -1 | grep -oE "vbad=[0-9]+|sp=[a-z-]+" | tr '\n' ' '
echo

echo "===== B. 写回校验：目标只读（期望 SPOOF-FAIL + sp=fake-fail）====="
setup
printf 'TICK=0\nTELEMETRY=1\nADAPTIVE=0\nSTANDBY=1\n' > $T/config.conf
chmod 400 $T/ps
rm -rf $T/lock
sh $T/bin/genie.sh 2>/dev/null
grep "SPOOF-FAIL" $T/logs/genie.log | head -1
grep "^TEL" $T/logs/telemetry-*.log | tail -1 | grep -oE "vbad=[0-9]+|sp=[a-z-]+" | tr '\n' ' '
echo

echo "===== C. TICK=abc 应回落 0.2（真 sleep，不替换 loop）====="
setup
printf 'TICK=abc\nTELEMETRY=0\nADAPTIVE=0\nSTANDBY=0\n' > $T/config.conf
chmod 644 $T/ps
rm -rf $T/lock
S=$(date +%s%N); sh $T/bin/genie.sh 2>/dev/null; E=$(date +%s%N)
echo "30 次迭代耗时 $(( (E-S)/1000000 )) ms"
grep -m1 "tick=" $T/logs/genie.log
