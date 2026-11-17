#!/bin/bash
# v0.6.1 验证：功率换算（cur mA × v µV）、放电样本不计入、汇总格式
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg7
rm -rf $T; mkdir -p $T/bin $T/logs

sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#" \
    -e "s#^NC7=.*#NC7=$T/none#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 120 ]; do#' \
    -e 's#^  sleep "\$TICK"#  sleep 0.02#' \
    "$SRC" > $T/bin/genie.sh

printf 'TICK=0\nTELEMETRY=0\nADAPTIVE=0\nSTANDBY=0\nCHARGE_SAMPLE=1\nCHARGE_AB=0\n' > $T/config.conf

echo 350 > $T/tb
echo 5 > $T/cd
echo 30000 > $T/ps
echo 30 > $T/cap
echo "-4000" > $T/cur
echo "4400000" > $T/vol
echo "" > $T/st
echo "" > $T/none

echo "Charging" > $T/st
(
  sleep 0.4; echo "-6000" > $T/cur          # 6A × 4.4V = 26.4W
  sleep 0.4; echo "2000"  > $T/cur          # 放电样本，应计 0
  sleep 0.4; echo "-3000" > $T/cur          # 3A × 4.4V = 13.2W
  sleep 0.4; echo "42"    > $T/cap; echo "Discharging" > $T/st
) &
sh $T/bin/genie.sh
wait

echo "===== charging.log ====="
cat $T/logs/charging.log 2>/dev/null
echo "===== CHG 样本 ====="
grep '^CHG' $T/logs/telemetry-*.log 2>/dev/null | head -8
echo "===== CAL 行 ====="
grep '^CAL' $T/logs/telemetry-*.log 2>/dev/null
echo "===== 校验：期望 peak≈26400mW avg≈19800mW maxCur=6000mA ====="
