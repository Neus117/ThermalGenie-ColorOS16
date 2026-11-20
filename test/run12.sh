#!/bin/bash
# v1.0.1 验证：待机会话状态落盘（进程被杀后接着算）+ 挂起补账（src=gap）
# A 正常：熄屏 -> 亮屏，写一条普通行
# B 续算：会话进行中进程退出，重启后应写 resume=1 且 cpu 不为负
# C 补账：进程没看到熄屏就冻结，醒来应写 src=gap
SRC="${GENIE_SRC:-$(cd "$(dirname "$0")/.." && pwd)/src/bin/genie.sh}"
T=/tmp/tg13
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

setup() {
  rm -rf $T; mkdir -p $T/bin $T/logs $T/fakebin
  sed -e "s#^PS=/proc/shell-temp#PS=$T/ps#" \
      -e "s#^NCD=.*#NCD=$T/cd#" \
      -e "s#^NB=.*#NB=$T/b#; s#^NTB=.*#NTB=$T/tb#; s#^NCUR=.*#NCUR=$T/cur#; s#^NVOL=.*#NVOL=$T/vol#; s#^NPW=.*#NPW=$T/pw#; s#^NCAP=.*#NCAP=$T/cap#; s#^NST=.*#NST=$T/st#" \
      -e "s#^NC4=.*#NC4=$T/none#; s#^NC7=.*#NC7=$T/none#" \
      -e "s#^LK=.*#LK=$T/lock#" \
      -e 's#^while :; do#while [ "$i" -lt 60 ]; do#' \
      -e "s#^  sleep \"\$TICK\"#  sleep 0.02#" \
      "$SRC" > $T/bin/genie.sh
  # 假 dumpsys：按调用次数决定屏幕状态（确定性，不依赖墙钟）
  cat > $T/fakebin/dumpsys <<EOF
#!/bin/sh
n=\$(cat $T/dcount 2>/dev/null || echo 0)
n=\$((n + 1)); echo \$n > $T/dcount
case "\$*" in
  *deviceidle*) echo "mState=INACTIVE" ;;
  *) if [ \$n -le \${DCOUNT_SWITCH:-10} ]; then echo "mWakefulness=Dozing"; else echo "mWakefulness=Awake"; fi ;;
esac
EOF
  chmod +x $T/fakebin/dumpsys
  printf 'TICK=0.2\nTELEMETRY=1\nADAPTIVE=1\nSTANDBY=1\nCHARGE_SAMPLE=1\nSB_GAP_MIN=90\n' > $T/config.conf
  echo 330 > $T/tb; echo 5 > $T/cd; echo 30000 > $T/ps
  echo Discharging > $T/st; echo 500 > $T/cur; echo 4000000 > $T/vol
  echo 60 > $T/cap; : > $T/none
}

echo "===== A 正常会话（前 10 次采样 Dozing，之后 Awake）====="
setup
DCOUNT_SWITCH=10 PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
A=$(cat $T/logs/standby.log 2>/dev/null)
echo "$A"
ck "A 写了 1 条汇总" '[ $(printf "%s\n" "$A" | grep -c "^\[" ) -eq 1 ]'
ck "A 没有补账/续算标记" '! printf "%s\n" "$A" | grep -qE "src=gap|resume=1"'

echo
echo "===== B 续算（先跑一段熄屏后退出，再以 Awake 重启）====="
setup
DCOUNT_SWITCH=999 PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null   # 一直 Dozing：会话开始后进程结束
STATE1=$(cat $T/.sbstate 2>/dev/null)
ck "B 退出前 .sbstate 记下 active=1" 'printf "%s\n" "$STATE1" | grep -q "^sb_active=1$"'
rm -f $T/dcount
sleep 2
DCOUNT_SWITCH=0 PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null     # 一上来就是 Awake
B=$(cat $T/logs/standby.log 2>/dev/null)
echo "$B"
ck "B 写了 resume=1" 'printf "%s\n" "$B" | grep -q "resume=1"'
ck "B 的 cpu 不为负" '! printf "%s\n" "$B" | grep -q "cpu=-"'
ck "B 的 dur 覆盖重启前后（>=2s）" 'printf "%s\n" "$B" | grep -qE "dur=([2-9]|[0-9]{2,})s"'

echo
echo "===== C 补账（没有进行中的会话，上次采样在 10 分钟前，电量 50->48）====="
setup
now=$(date +%s)
cat > $T/.sbstate <<EOF
sb_ver=1
sb_active=0
sb_start=0
sb_cap0=0
sb_sum=0
sb_n=0
sb_cpu0=0
sb_ss0=0
sb_sf0=0
sb_chg=0
sb_cap_last=50
sb_t=$((now - 600))
EOF
echo 48 > $T/cap
DCOUNT_SWITCH=0 PATH=$T/fakebin:$PATH sh $T/bin/genie.sh 2>/dev/null
C=$(cat $T/logs/standby.log 2>/dev/null)
echo "$C"
ck "C 写了 src=gap" 'printf "%s\n" "$C" | grep -q "src=gap"'
ck "C 的 dur 覆盖空档（>=90s）" 'printf "%s\n" "$C" | grep -qE "dur=[0-9]{3,}s"'
ck "C 的电量差是 50->48" 'printf "%s\n" "$C" | grep -q "cap=50->48"'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
