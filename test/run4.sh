#!/bin/bash
# v0.4 离线逻辑验证：双档护栏（充电 48/43、游戏 52/47）+ 诱骗 + cool_down
SRC="D:/Coding/workspace/ThermalGenie/src/bin/genie.sh"
T=/tmp/tg4
rm -rf $T; mkdir -p $T/bin $T/logs

sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NTB=.*#NTB=$T/tb#" \
    -e "s#^NCUR=.*#NCUR=$T/none#" \
    -e "s#^NVOL=.*#NVOL=$T/none#" \
    -e "s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#" \
    -e "s#^NC7=.*#NC7=$T/none#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 30 ]; do#' \
    -e 's#^  sleep "\$TICK"#  sleep 0#' \
    "$SRC" > $T/bin/genie.sh

printf 'TICK=0\nTELEMETRY=0\n' > $T/config.conf

run() { # $1=status $2=battery(0.1C) $3=label
  echo "$1" > $T/st
  echo 5 > $T/cd
  echo 30000 > $T/ps
  echo $2 > $T/tb
  sh $T/bin/genie.sh
  echo "[$3] st=$1 tb=$2 -> ps=[$(tr '\n' ' ' < $T/ps)] cd=[$(cat $T/cd)]"
  grep -E "GUARD|state" $T/logs/genie.log | tail -2 | sed 's/^/        /'
  : > $T/logs/genie.log
  rm -rf $T/lock
}

echo "=== 1. 充电 49.0C：充电档 48C 触发 ==="
run Charging 490 "充电-过热"
echo
echo "=== 2. 充电 47.0C：未到 48C，正常诱骗 ==="
run Charging 470 "充电-未触发"
echo
echo "=== 3. 游戏(未充电) 50.0C：游戏档 52C，不触发 ==="
run Discharging 500 "游戏-50度"
echo
echo "=== 4. 游戏(未充电) 53.0C：游戏档触发，上报钳制 60C ==="
run Discharging 530 "游戏-53度"
echo
echo "=== 5. 迟滞：充电 49C 触发，降到 44C 仍守住，降到 42C 才释放 ==="
rm -rf $T/lock; : > $T/logs/genie.log
echo "Charging" > $T/st; echo 5 > $T/cd; echo 30000 > $T/ps; echo 490 > $T/tb
sed -i 's#^  sleep 0$#  sleep 0.05#' $T/bin/genie.sh
sh $T/bin/genie.sh & PID=$!
sleep 0.5; echo 440 > $T/tb
sleep 0.5; echo 420 > $T/tb
wait $PID
grep -E "GUARD|state" $T/logs/genie.log | sed 's/^/        /'
