#!/bin/bash
# 验证安装时的两个音量键选项 + 卡片描述跟随实际状态
#   A 全新安装 + 按一次音量+：只回答第一个问题（第二个问题不许被同一次按压带走）
#   B 升级安装 + 按两次音量-：两个问题都关；旧日志保留、重复键收敛、卡片写关/关/关
#   C 升级安装 + 一次都不按：保持旧配置（FPS=0、温度墙=1、冷却=1），卡片写关/开/开
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
T=/tmp/tg14
fail=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

# $1 = 按压序列，例如 "up" / "down down" / ""（不按）
setup() {
  rm -rf $T; mkdir -p $T/new $T/old/logs $T/fakebin
  cp -r "$SRC"/. $T/new/
  : > $T/events
  for k in $1; do
    case "$k" in
      up)   printf 'KEY_VOLUMEUP DOWN\nKEY_VOLUMEUP UP\n' >> $T/events ;;
      down) printf 'KEY_VOLUMEDOWN DOWN\nKEY_VOLUMEDOWN UP\n' >> $T/events ;;
    esac
  done
  # 假 getevent：像真机一样每条事件一行，带 EV_KEY 前缀
  cat > $T/fakebin/getevent <<EOF
#!/bin/sh
n=\$(cat $T/gcount 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > $T/gcount
line=\$(sed -n "\${n}p" $T/events)
[ -n "\$line" ] && echo "/dev/input/event1: EV_KEY \$line"
exit 0
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

echo "===== A 全新安装，只按一次音量+ ====="
setup "up"
rm -f $T/old/config.conf
run
sed -n '/【1\/2】/,/重启后生效/p' $T/out.txt | head -20
ck "A 第一个问题 = 开"              'grep -q "^FPS_UNLOCK=1$" $T/new/config.conf'
ck "A 第二个问题没被同一次按压带走" '[ "$(grep "^THERMAL_UNLOCK=" $T/new/config.conf)" = "THERMAL_UNLOCK=0" ]'
ck "A 冷却直控也没被带走"           '[ "$(grep "^CDEV_UNLOCK=" $T/new/config.conf)" = "CDEV_UNLOCK=0" ]'
ck "A 第二个问题提示保持当前设置"    'grep -q "温度墙/冷却直控：保持当前设置（关）" $T/out.txt'
ck "A 卡片描述=开/关/关"            'grep -q "当前：帧率解锁 开；温度墙解锁 关；冷却直控 关。" $T/new/module.prop'

echo
echo "===== B 升级安装（旧 0/1/1，THERMAL 重复两行），按两次音量- ====="
setup "down down"
printf 'SHELL_SPOOF=1\nFPS_UNLOCK=0\nRATE_UNLOCK=0\nTHERMAL_UNLOCK=1\nTHERMAL_UNLOCK=1\nCDEV_UNLOCK=1\nGUARD_TRIGGER=520\n' > $T/old/config.conf
printf '[2026-11-19 20:23:40] standby dur=79s cap=43->43 samples=9 rate=n/a\n' > $T/old/logs/standby.log
run
ck "B 帧率解锁 0"           'grep -q "^FPS_UNLOCK=0$" $T/new/config.conf'
ck "B 温度墙 0"             'grep -q "^THERMAL_UNLOCK=0$" $T/new/config.conf'
ck "B 冷却直控 0"           'grep -q "^CDEV_UNLOCK=0$" $T/new/config.conf'
ck "B 重复键收敛成一行"     '[ "$(grep -c "^THERMAL_UNLOCK=" $T/new/config.conf)" = 1 ]'
ck "B 旧日志保留"           'grep -q "dur=79s" $T/new/logs/standby.log'
ck "B 卡片描述=关/关/关"    'grep -q "当前：帧率解锁 关；温度墙解锁 关；冷却直控 关。" $T/new/module.prop'

echo
echo "===== C 升级安装（旧 FPS=0 / 温度墙=1 / 冷却=1），一次都不按 ====="
setup ""
printf 'SHELL_SPOOF=1\nFPS_UNLOCK=0\nRATE_UNLOCK=0\nTHERMAL_UNLOCK=1\nCDEV_UNLOCK=1\n' > $T/old/config.conf
run
ck "C 帧率保持 0"           'grep -q "^FPS_UNLOCK=0$" $T/new/config.conf'
ck "C 温度墙保持 1"         'grep -q "^THERMAL_UNLOCK=1$" $T/new/config.conf'
ck "C 冷却保持 1"           'grep -q "^CDEV_UNLOCK=1$" $T/new/config.conf'
ck "C 卡片描述=关/开/开"    'grep -q "当前：帧率解锁 关；温度墙解锁 开；冷却直控 开。" $T/new/module.prop'

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "HAS FAILURES"
exit $fail
