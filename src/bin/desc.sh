#!/system/bin/sh
# 用「基础文案 + 当前开关状态」重写 module.prop 的 description 行。
# 管理器卡片只认 module.prop，静态文案写出「默认关闭」会和用户装机时的选择打架，
# 所以这里按 config.conf 的实际值拼一句「当前：…」，安装后与每次开机各刷新一次。
MD=$(cd "$(dirname "$0")/.." && pwd)
PROP="$MD/module.prop"
BASE="$MD/desc.base"
CFG="$MD/config.conf"
[ -f "$PROP" ] || exit 0
[ -f "$BASE" ] || exit 0

val() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -n1; }
onoff() { [ "$1" = 1 ] && echo 开 || echo 关; }

base=$(tr '\n' ' ' < "$BASE" 2>/dev/null | sed 's/[[:space:]]*$//')
[ -z "$base" ] && exit 0
want="${base} 当前：帧率解锁 $(onoff "$(val FPS_UNLOCK)")；温度墙解锁 $(onoff "$(val THERMAL_UNLOCK)")；冷却直控 $(onoff "$(val CDEV_UNLOCK)")。"

cur=$(sed -n 's/^description=//p' "$PROP" 2>/dev/null | head -n1)
[ "$cur" = "$want" ] && exit 0

sed -i "/^description=/d" "$PROP" 2>/dev/null
# 末行没有换行时先补一个，否则新行会粘在上一行上
[ -n "$(tail -c 1 "$PROP" 2>/dev/null)" ] && printf '\n' >> "$PROP"
printf 'description=%s\n' "$want" >> "$PROP"
