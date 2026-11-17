#!/bin/bash
# v0.8.x 健壮性：模拟真机电源数据源，验证待机会话字段完整
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg12

setup() {
  rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin
  sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
      -e "s#^NCD=.*#NCD=$T/cd#" \
      -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
      -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
      -e "s#^PWC=.*#PWC=$T/pwc#" -e "s#^PSS=.*#PSS=$T/pss#" -e "s#^PSF=.*#PSF=$T/psf#" \
      -e "s#^PLF=.*#PLF=$T/plf#" -e "s#^PWS=.*#PWS=$T/pws#" -e "s#^PDBG=.*#PDBG=$T/pdbg#" \
      -e "s#^LK=.*#LK=$T/lock#" \
      -e 's#^while :; do#while [ "$i" -lt 120 ]; do#' \
      "$SRC" > $T/bin/genie.sh
  cat > $T/fakebin/dumpsys <<EOF
#!/bin/sh
echo "mWakefulness=\$(cat $T/wake 2>/dev/null || echo Awake)"
EOF
  chmod +x $T/fakebin/dumpsys
  printf 'name\tactive_count\tevent_count\nwlan_wake\t120\t300\nalarmtimer\t40\t80\n' > $T/pws
  echo 100 > $T/pwc; echo 500 > $T/pss; echo 1 > $T/psf; echo wlan > $T/plf
  printf 'TICK=0\nTELEMETRY=1\nADAPTIVE=0\nSTANDBY=1\nCHARGE_SAMPLE=1\n' > $T/config.conf
}

run() {  # $1=名称 $2=充电状态 $3=结束时应写入的计数器文件内容
  setup
  echo Dozing > $T/wake
  echo 87 > $T/cap
  echo "$2" > $T/st
  echo 500 > $T/cur; echo 4000000 > $T/vol; echo 5 > $T/cd; echo 30000 > $T/ps
  ( sleep 15; echo 86 > $T/cap; echo 108 > $T/pwc; echo 512 > $T/pss; echo Awake > $T/wake ) &
  PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
  wait
  echo "--- $1 ---"
  grep "^CAPS" $T/logs/genie.log
  cat $T/logs/standby.log 2>/dev/null
  cat $T/logs/standby-*.log 2>/dev/null
}

run "A 正常待机（熄屏→亮屏）" "Discharging" ""
run "B 充电中的待机（应 rate=n/a, chg=1）" "Charging" ""
