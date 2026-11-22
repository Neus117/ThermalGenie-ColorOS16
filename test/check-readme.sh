#!/bin/bash
# README 与源码的一致性门禁：文档里承诺的键/节点/日志字段必须真的在源码里。
# 用法：bash test/check-readme.sh    （任意 bash；Windows 用 Git Bash）
cd "$(dirname "$0")/.." || exit 1
fail=0
ck() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi; }

# 1) README 里反引号包起来的配置键，必须都在 config.conf 里（日志 token 除外）
keys=$(grep -oE '`[A-Z][A-Z0-9_]+`' README.md | tr -d '`' | sort -u)
miss=""
for k in $keys; do
  case "$k" in CAL|CAPS|CHG|OK|STAGED|TEL|THR|WAKE|CHARGE_TEMP_SHIFT) continue ;; esac
  grep -qE "^$k=" src/config.conf || miss="$miss $k"
done
[ -z "$miss" ]; ck $? "README 提到的配置键都在 config.conf:$miss"

# 2) README 写的 sysfs/proc 节点，必须出现在源码里
for p in /proc/shell-temp /sys/class/oplus_chg/battery/cool_down /sys/power/wakeup_count \
         /vendor/etc/display/thermallevel_to_fps.xml /my_product/etc/refresh_rate_config.xml \
         /mnt/vendor/mountify/vendor/etc; do
  grep -qF "$p" src/*.sh src/bin/genie.sh; ck $? "src 里出现 $p"
done
grep -q 'NB=/sys/class/power_supply/battery' src/bin/genie.sh; ck $? '电池节点前缀 NB'
grep -q 'NCUR=$NB/current_now' src/bin/genie.sh; ck $? 'current_now 节点'
grep -q 'NVOL=$NB/voltage_now' src/bin/genie.sh; ck $? 'voltage_now 节点'
grep -q 'NTB=$NB/temp' src/bin/genie.sh; ck $? 'battery temp 节点'

# 3) README 记录的日志字段/事件，必须真的被写出来
for t in CAPS TEL CHG CAL THR GUARD CHARGE-START CHARGE-END TICK THERMAL-FIX \
         STANDBY-START STANDBY-END STANDBY-GAP STANDBY-RESUME; do
  grep -qF "$t" src/bin/genie.sh; ck $? "genie.sh 会写 $t"
done
grep -qF 'src=gap' src/bin/genie.sh; ck $? '补账行带 src=gap'
grep -qF 'resume=1' src/bin/genie.sh; ck $? '续算行带 resume=1'
grep -qF 'WAKE ' src/bin/genie.sh; ck $? 'genie.sh 会写 WAKE'
for t in BIND-SHADOWED VALIDATE-FAIL STAGED "verify OK"; do
  grep -qF "$t" src/post-fs-data.sh src/service.sh; ck $? "开机脚本会写 $t"
done

# 4) README/安装横幅里的数字，必须和 config.conf 一致
for kv in GUARD_TRIGGER=520 GUARD_RELEASE=470 SHELL_TRIGGER=350 SHELL_TEMP=37000 \
          CHARGE_TRIGGER=300 THERMAL_DELTA=5000 THERMAL_CAP=97000 THERMAL_UNLOCK=0 \
          CDEV_UNLOCK=0 GUARD_VALUE_MIN=50000 SB_GAP_MIN=90; do
  grep -q "^$kv$" src/config.conf; ck $? "config.conf 有 $kv"
done
grep -q '96000' src/bin/genie.sh; ck $? '结温保险 96.0C'
grep -q 'v=60000' src/bin/genie.sh; ck $? '护栏上报封顶 60.0C'
grep -q 'now - hb)) -gt 150' src/service.sh; ck $? '看门狗 150 秒'
grep -q 'i % 30' src/bin/genie.sh; ck $? '每 30 tick 复核温度墙'
grep -q 'i % 5' src/bin/genie.sh; ck $? '每 5 tick 复核冷却设备'

# 5) 自适应节拍
grep -q 'fast) TICK=0.2' src/bin/genie.sh; ck $? 'fast 0.2s'
grep -q 'mid)  TICK=0.5' src/bin/genie.sh; ck $? 'mid 0.5s'
grep -qE '\)    TICK=2;' src/bin/genie.sh; ck $? 'slow 2s'

# 6) 不许留旧版本号/旧阈值/旧目录
if grep -qE 'Thermal-Genie-v0\.6\.1\.zip|48\.0℃（充电中）|43\.0℃|archive\\' README.md; then
  ck 1 "README 没有旧版本号/旧阈值"
else
  ck 0 "README 没有旧版本号/旧阈值"
fi

# 7) 版本号只有一个来源：README 不写死版本，module.prop 才是权威
if grep -qE 'version=v[0-9]' README.md; then ck 1 "README 未写死版本号"; else ck 0 "README 未写死版本号"; fi

# 8) 目录结构里列出的文件必须存在
for p in build.ps1 src/module.prop src/customize.sh src/post-fs-data.sh src/service.sh \
         src/action.sh src/uninstall.sh src/config.conf src/bin/genie.sh test; do
  [ -e "$p" ]; ck $? "存在 $p"
done

# 9) 脚本语法
for f in src/*.sh src/bin/genie.sh; do sh -n "$f" 2>/dev/null; ck $? "语法 $f"; done

exit $fail
