#!/bin/bash
# v1.0.3 验证：安装时的两个音量键选项
#   A 全新安装 + 两次音量+：帧率开、温度墙/冷却开
#   B 升级安装 + 两次音量-：帧率关、温度墙/冷却关，旧日志仍保留，重复键收敛成一行
#   C 升级安装 + 不按键：保持旧配置（含用户手改的 1/1），不被默认值改写
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
T=/tmp/tg14
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

setup() {
  rm -rf $T; mkdir -p $T/new $T/old/logs $T/fakebin
  cp -r "$SRC"/. $T/new/
  # 假输入：按 $T/keys 里的第 n 行决定第 n 次 read_vol 的结果
  cat > $T/fakebin/getevent <<EOF
#!/bin/sh
n=\$(cat $T/gcount 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > $T/gcount
k=\$(sed -n "\${n}p" $T/keys)
case "\$k" in
  up)   echo "2 1 KEY_VOLUMEUP" ;;
  down) echo "2 1 KEY_VOLUMEDOWN" ;;
  *)    exit 0 ;;
esac
EOF
  cat > $T/fakebin/timeout <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
  chmod +x $T/fakebin/getevent $T/fakebin/timeout
  sed -i "s#^OLDCFG=.*#OLDCFG=$T/old/config.conf#; s#^OLDLOGS=.*#OLDLOGS=$T/old/logs#; s#/data/local/tmp/.thermal_genie.lock#$T/lock#" $T/new/customize.sh
}

run() { PATH=$T/fakebin:$PATH MODPATH=$T/new sh $T/new/customize.sh > $T/out.txt 2>&1; }

echo "===== A 全新安装（没有旧配置），两次音量+ ===="
setup
rm -f $T/old/config.conf  # 全新安装：旧配置不存在
printf 'up\nup\n' > $T/keys
run
sed -n '/1\/2/,/重启后生效/p' $T/out.txt | head -20
ck "A 帧率解锁写成 1" 'grep -q "^FPS_UNLOCK=1$" $T/new/config.conf'
ck "A 刷新率解锁写成 1" 'grep -q "^RATE_UNLOCK=1$" $T/new/config.conf'
ck "A 温度墙写成 1" 'grep -q "^THERMAL_UNLOCK=1$" $T/new/config.conf'
ck "A 冷却直控写成 1" 'grep -q "^CDEV_UNLOCK=1$" $T/new/config.conf'

echo
echo "===== B 升级安装（旧配置 0/1/1，且 THERMAL_UNLOCK 重复两行），两次音量- ===="
setup
printf 'SHELL_SPOOF=1\nFPS_UNLOCK=0\nRATE_UNLOCK=0\nTHERMAL_UNLOCK=1\nTHERMAL_UNLOCK=1\nCDEV_UNLOCK=1\nGUARD_TRIGGER=520\n' > $T/old/config.conf
printf '[2026-11-19 20:23:40] standby dur=79s cap=43->43 samples=9 rate=n/a\n' > $T/old/logs/standby.log
printf 'down\ndown\n' > $T/keys
run
ck "B 帧率解锁写成 0" 'grep -q "^FPS_UNLOCK=0$" $T/new/config.conf'
ck "B 温度墙写成 0" 'grep -q "^THERMAL_UNLOCK=0$" $T/new/config.conf'
ck "B 冷却直控写成 0" 'grep -q "^CDEV_UNLOCK=0$" $T/new/config.conf'
ck "B 重复的 THERMAL_UNLOCK 收敛成一行" '[ "$(grep -c "^THERMAL_UNLOCK=" $T/new/config.conf)" = 1 ]'
ck "B 旧日志被带过来" 'grep -q "dur=79s" $T/new/logs/standby.log'

echo
echo "===== C 升级安装（旧配置 FPS=0 / 温度墙=1），不按键 ===="
setup
printf 'SHELL_SPOOF=1\nFPS_UNLOCK=0\nRATE_UNLOCK=0\nTHERMAL_UNLOCK=1\nCDEV_UNLOCK=1\n' > $T/old/config.conf
printf 'none\nnone\n' > $T/keys
run
sed -n '/1\/2/,/重启后生效/p' $T/out.txt | head -18
ck "C 不按键 → 帧率保持 0" 'grep -q "^FPS_UNLOCK=0$" $T/new/config.conf'
ck "C 不按键 → 温度墙保持 1" 'grep -q "^THERMAL_UNLOCK=1$" $T/new/config.conf'
ck "C 不按键 → 冷却直控保持 1" 'grep -q "^CDEV_UNLOCK=1$" $T/new/config.conf'
ck "C 提示写的是「保持当前设置」" 'grep -q "保持当前设置" $T/out.txt'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
