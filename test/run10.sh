#!/bin/bash
# v0.7.0 验证：自适应节拍（冷 -> slow 1s，热 -> fast 0.2s）
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg11
rm -rf $T; mkdir -p $T/bin $T/logs
sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 40 ]; do#' \
    "$SRC" > $T/bin/genie.sh
echo 300 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
echo 500 > $T/cur; echo 4000000 > $T/vol; echo 80 > $T/cap
echo Discharging > $T/st; : > $T/none
printf 'TELEMETRY=0\nADAPTIVE=1\nSTANDBY=0\n' > $T/config.conf
( sleep 4; echo 370 > $T/tb ) &
sh $T/bin/genie.sh 2>/dev/null
wait
echo "=== 节拍切换日志 ==="
grep "TICK" $T/logs/genie.log
