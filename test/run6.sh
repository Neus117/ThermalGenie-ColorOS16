#!/bin/bash
# v0.6 离线验证：充电会话开始/采样/汇总 + 护栏 + 状态机
SRC="D:/Coding/workspace/ThermalGenie/src/bin/genie.sh"
T=/tmp/tg6
rm -rf $T; mkdir -p $T/bin $T/logs

sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#" \
    -e "s#^NC7=.*#NC7=$T/none#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 400 ]; do#' \
    -e 's#^  sleep "\$TICK"#  sleep 0.02#' \
    "$SRC" > $T/bin/genie.sh

printf 'TICK=0\nTELEMETRY=0\nADAPTIVE=0\nSTANDBY=0\nCHARGE_SAMPLE=1\nCHARGE_AB=0\n' > $T/config.conf

echo 350 > $T/tb
echo 5 > $T/cd
echo 30000 > $T/ps
echo 30 > $T/cap
echo "" > $T/st
echo "" > $T/pw
echo "" > $T/none

# 场景：充电中功率从 30W 升到 40W 再回落，1.5 秒后拔掉
echo "Charging" > $T/st
( sleep 0.3; echo 30000000 > $T/pw; sleep 0.3; echo 40000000 > $T/pw; sleep 0.3; echo 35000000 > $T/pw; sleep 0.3; echo 45 > $T/cap; echo "Discharging" > $T/st ) &
sh $T/bin/genie.sh
wait

echo "===== charging.log 汇总 ====="
cat $T/logs/charging.log 2>/dev/null
echo "===== 遥测里的 CHG 样本（前 3 条 / 共 $(grep -c '^CHG' $T/logs/telemetry-*.log 2>/dev/null | tail -1) 条）====="
grep '^CHG' $T/logs/telemetry-*.log 2>/dev/null | head -3
echo "===== genie.log ====="
cat $T/logs/genie.log 2>/dev/null
