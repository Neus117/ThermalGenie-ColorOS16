#!/bin/bash
# v0.7.0 验证：待机会话（熄屏计时 → 亮屏汇总）
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg10
rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin

sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
    -e "s#^NCD=.*#NCD=$T/cd#" \
    -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
    -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
    -e "s#^LK=.*#LK=$T/lock#" \
    -e 's#^while :; do#while [ "$i" -lt 120 ]; do#' \
    "$SRC" > $T/bin/genie.sh

# 假 dumpsys：从文件读屏幕状态
cat > $T/fakebin/dumpsys <<EOF
#!/bin/sh
echo "mWakefulness=\$(cat $T/wake 2>/dev/null || echo Awake)"
EOF
chmod +x $T/fakebin/dumpsys

echo Dozing > $T/wake
echo 350 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
echo 500 > $T/cur; echo 4000000 > $T/vol; echo 80 > $T/cap
echo Discharging > $T/st; : > $T/none
printf 'TICK=0\nTELEMETRY=1\nADAPTIVE=0\nSTANDBY=1\nCHARGE_SAMPLE=1\n' > $T/config.conf

# 前半段熄屏，约 6 秒后亮屏
( sleep 15; echo 78 > $T/cap; echo Awake > $T/wake ) &
PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
wait

echo "=== genie.log 里的待机会话 ==="
grep -E "STANDBY" $T/logs/genie.log
echo "=== standby.log（短会话应 rate=n/a，含 sph）==="
cat $T/logs/standby.log 2>/dev/null
echo "=== standby-当天明细（唤醒源，本机无 wakeup_sources 时应为空行）==="
cat $T/logs/standby-*.log 2>/dev/null
