#!/bin/bash
# v1.0.4+ 冷却直控扩展：
#   A 钉住 cpufreq-cpu0/cpufreq-cpu6/gpu/kgsl/display-fps，且不误伤 gpu-dump-skip-cdev / panel0-backlight / cpu-hotplug
#   B 把各 CPU 策略的 scaling_max_freq 补写到硬件上限，并记 FREQ-FLOOR
#   C 结温 ≥96℃ 时全部放手（cdev 不钉、频率不补），交回系统
#   D CDEV_EXTRA=0 时只钉 cpu-cluster*，其余不动
#   E 遥测里出现 CDS2 归因行，列出非零通道
SRC="$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh"
T=/tmp/tg17
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

setup() { # $1=CDEV_EXTRA  $2=循环轮数  $3=z2 温度
  rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin $T/th $T/cpufreq
  mkcdev() { c=$T/th/cooling_device$1; mkdir -p "$c"; echo "$2" > "$c/type"; echo "$3" > "$c/cur_state"; echo 15 > "$c/max_state"; }
  mkcdev 0  cpu-hotplug0        1
  mkcdev 8  cpufreq-cpu0        3
  mkcdev 9  cpufreq-cpu6        5
  mkcdev 28 ddr-cdev            1
  mkcdev 29 gpu-dump-skip-cdev  1
  mkcdev 30 display-fps         7
  mkcdev 31 cpu-cluster0        12
  mkcdev 32 cpu-cluster1        0
  mkcdev 34 kgsl                2
  mkcdev 35 panel0-backlight    100
  mkcdev 36 gpu                 4
  mkpol() { p=$T/cpufreq/policy$1; mkdir -p "$p"; echo "$2" > "$p/scaling_max_freq"; echo "$3" > "$p/cpuinfo_max_freq"; }
  mkpol 0 2400000 3532800
  mkpol 6 1689600 4320000
  mkpol 4 3532800 3532800     # 已经在硬件上限，不该被改也不该计数
  echo "$3" > $T/z2; echo 25000 > $T/z22
  sed -e "s#^CDIR=.*#CDIR=$T/th#" \
      -e "s#^CPUFREQ_DIR=.*#CPUFREQ_DIR=$T/cpufreq#" \
      -e "s#^ZCPU=.*#ZCPU=$T/z2#" \
      -e "s#^ZCPUSS=.*#ZCPUSS=$T/z22#" \
      -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
      -e "s#^NCD=.*#NCD=$T/cd#" \
      -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
      -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
      -e "s#^NM0=.*#NM0=$T/none#; s#^NM4=.*#NM4=$T/none#; s#^NM7=.*#NM7=$T/none#" \
      -e "s#^NGPU=.*#NGPU=$T/none#; s#^NGMAX=.*#NGMAX=$T/none#; s#^NGLOAD=.*#NGLOAD=$T/none#" \
      -e "s#^ZPMIC=.*#ZPMIC=$T/none#" \
      -e "s#^UPTIME=.*#UPTIME=$T/uptime#" \
      -e "s#^LK=.*#LK=$T/lock#" \
      -e "s#^while :; do#while [ \"\$i\" -lt $2 ]; do#" \
      -e 's#^  sleep "\$TICK"#  sleep 0.02#' \
      "$SRC" > $T/bin/genie.sh
  printf '#!/bin/sh\necho "mWakefulness=Awake"\n' > $T/fakebin/dumpsys
  chmod +x $T/fakebin/dumpsys
  printf 'TICK=0.2\nTELEMETRY=1\nADAPTIVE=0\nSTANDBY=0\nCHARGE_SAMPLE=1\nTHERMAL_UNLOCK=0\nCDEV_UNLOCK=1\nCDEV_GUARD=520\nCDEV_EXTRA=%s\nFREQ_FLOOR=1\n' "$1" > $T/config.conf
  echo 330 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
  echo Discharging > $T/st; echo 500 > $T/cur; echo 4000000 > $T/vol
  echo 60 > $T/cap; : > $T/none; echo "3600.00 7200.00" > $T/uptime
}

run() { PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null; }

echo "===== A/B/E 结温正常：钉 5 个扩展设备 + 频率补写 + 归因行 ====="
setup 1 40 45000
run
sed -n '1,12p' $T/logs/genie.log
grep -E '^TEL' "$T"/logs/telemetry-*.log 2>/dev/null | tail -2
ck "A cpufreq-cpu0 -> 0"      '[ "$(cat $T/th/cooling_device8/cur_state)" = 0 ]'
ck "A cpufreq-cpu6 -> 0"      '[ "$(cat $T/th/cooling_device9/cur_state)" = 0 ]'
ck "A gpu -> 0"               '[ "$(cat $T/th/cooling_device36/cur_state)" = 0 ]'
ck "A kgsl -> 0"              '[ "$(cat $T/th/cooling_device34/cur_state)" = 0 ]'
ck "A display-fps -> 0"       '[ "$(cat $T/th/cooling_device30/cur_state)" = 0 ]'
ck "A cpu-cluster0 -> 0"      '[ "$(cat $T/th/cooling_device31/cur_state)" = 0 ]'
ck "A 不误伤 gpu-dump-skip"    '[ "$(cat $T/th/cooling_device29/cur_state)" = 1 ]'
ck "A 不误伤 backlight"        '[ "$(cat $T/th/cooling_device35/cur_state)" = 100 ]'
ck "A 不误伤 cpu-hotplug"      '[ "$(cat $T/th/cooling_device0/cur_state)" = 1 ]'
ck "B policy0 补到硬件上限"     '[ "$(cat $T/cpufreq/policy0/scaling_max_freq)" = 3532800 ]'
ck "B policy6 补到硬件上限"     '[ "$(cat $T/cpufreq/policy6/scaling_max_freq)" = 4320000 ]'
ck "B 记了 FREQ-FLOOR"          'grep -q "FREQ-FLOOR 补写 2 个策略上限" $T/logs/genie.log'
ck "B 记了 CDSMAP 对照表"       'grep -q "CDSMAP pinned:.*cpufreq-cpu0" $T/logs/genie.log'
ck "E 遥测有 CDS2 归因行"       'grep -q "cds2=" $T/logs/telemetry-*.log'
ck "E 归因行只列非零（cd0=1）"  'grep -q "cds2=cd0=1" $T/logs/telemetry-*.log'

echo
echo "===== C 结温 97℃：全部放手 ====="
setup 1 20 97000
run
grep -E "CDEV-|FREQ" $T/logs/genie.log | head -3
ck "C cdev 没被钉（cpufreq-cpu0=3）" '[ "$(cat $T/th/cooling_device8/cur_state)" = 3 ]'
ck "C cluster 也没被钉（=12）"       '[ "$(cat $T/th/cooling_device31/cur_state)" = 12 ]'
ck "C 频率没被补写（=2400000）"      '[ "$(cat $T/cpufreq/policy0/scaling_max_freq)" = 2400000 ]'
ck "C 记了 CDEV-HOLD"                'grep -q "CDEV-HOLD" $T/logs/genie.log'

echo
echo "===== D CDEV_EXTRA=0：只钉 cluster ====="
setup 0 20 45000
run
ck "D cpufreq-cpu0 保持 3"   '[ "$(cat $T/th/cooling_device8/cur_state)" = 3 ]'
ck "D gpu 保持 4"            '[ "$(cat $T/th/cooling_device36/cur_state)" = 4 ]'
ck "D cluster 仍被钉 0"      '[ "$(cat $T/th/cooling_device31/cur_state)" = 0 ]'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
