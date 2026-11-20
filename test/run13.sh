#!/bin/bash
# v1.0.2 验证：升级安装时保留旧 config 与 logs（KSU 换模块目录会删掉 logs/）
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
T=/tmp/tg14
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

rm -rf $T; mkdir -p $T/new $T/old/logs $T/fakebin
cp -r "$SRC"/. $T/new/
printf 'SHELL_SPOOF=1\nTHERMAL_UNLOCK=1\nCDEV_UNLOCK=1\nGUARD_TRIGGER=520\nSB_GAP_MIN=90\n' > $T/old/config.conf
printf '[2026-11-19 20:23:40] standby dur=79s cap=43->43 samples=9 sph=410 avg=165mA rate=n/a cpu=83ticks ss=7/2 lf=alarmtimer.0.auto chg=0 mState=ACTIVE\n' > $T/old/logs/standby.log
printf '[2026-11-19 20:00:00] start v1.0.1 pid=1 tick=0.2\n' > $T/old/logs/genie.log

# 把「旧模块目录」与锁文件重定向到临时目录，避免碰到真机路径
sed -i "s#^OLDCFG=.*#OLDCFG=$T/old/config.conf#; s#^OLDLOGS=.*#OLDLOGS=$T/old/logs#; s#/data/local/tmp/.thermal_genie.lock#$T/lock#" $T/new/customize.sh

# 假输入：按音量- （不开启帧率解锁）；假 timeout 直接跑命令
cat > $T/fakebin/getevent <<'EOF'
#!/bin/sh
echo "2 1 KEY_VOLUMEDOWN"
EOF
cat > $T/fakebin/timeout <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
chmod +x $T/fakebin/getevent $T/fakebin/timeout

PATH=$T/fakebin:$PATH MODPATH=$T/new sh $T/new/customize.sh > $T/out.txt 2>&1
cat $T/out.txt

ck "旧 config 的 THERMAL_UNLOCK=1 保住了" 'grep -q "^THERMAL_UNLOCK=1$" $T/new/config.conf'
ck "旧 config 的 CDEV_UNLOCK=1 保住了" 'grep -q "^CDEV_UNLOCK=1$" $T/new/config.conf'
ck "音量键选择生效（FPS_UNLOCK=0）" 'grep -q "^FPS_UNLOCK=0$" $T/new/config.conf'
ck "旧 standby.log 被带过来" 'grep -q "dur=79s cap=43->43" $T/new/logs/standby.log'
ck "旧 genie.log 被带过来" 'grep -q "start v1.0.1" $T/new/logs/genie.log'
ck "安装脚本明确提示保留日志" 'grep -q "已保留原有日志" $T/out.txt'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
