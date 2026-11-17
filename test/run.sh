#!/bin/bash
# 离线逻辑验证：把 genie.sh 的 sysfs 路径改到临时目录，跑护栏状态机
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg
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

run() {
  echo "Charging" > $T/st
  echo 5 > $T/cd
  echo 30000 > $T/ps
  echo $1 > $T/tb
  sh $T/bin/genie.sh
  echo "tb=$1  ->  ps=[$(tr '\n' ' ' < $T/ps)]  cd=[$(cat $T/cd)]"
  grep -E "GUARD|state" $T/logs/genie.log | tail -3 | sed 's/^/        /'
  : > $T/logs/genie.log
  rm -rf $T/lock
}

echo "=== 场景1：电池 49.0C，充电中（应触发护栏，上报 57.0C，不动 cd）==="
run 490
echo
echo "=== 场景2：电池 42.0C，充电中（应恢复诱骗 37.0C，并写 cd=0）==="
run 420
echo
echo "=== 场景3：电池 30.0C（低于诱骗阈值，应不写 ps，但仍写 cd=0）==="
run 300
echo
echo "=== 场景4：电池 55.0C（应被钳制在 60.0C 上限）==="
run 550
echo
echo "=== 场景5：迟滞测试（起始 49.0C，中途降到 42.0C）==="
rm -rf $T/lock; : > $T/logs/genie.log
echo "Charging" > $T/st; echo 5 > $T/cd; echo 30000 > $T/ps; echo 490 > $T/tb
sed -i 's#^  sleep 0$#  sleep 0.05#' $T/bin/genie.sh
sh $T/bin/genie.sh &
PID=$!
sleep 0.6
echo 420 > $T/tb
wait $PID
grep -E "GUARD|state" $T/logs/genie.log | sed 's/^/        /'
echo "        最终 ps=[$(tr '\n' ' ' < $T/ps)]"
