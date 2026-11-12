#!/system/bin/sh
# Thermal Genie - 开机早期：生成并挂载「游戏帧率解锁」补丁
# 注意：/vendor/etc 被 mountify 用 overlay 覆盖，单靠 bind 会被遮住，
#       所以额外把补丁文件放进 mountify 的 lowerdir，并由 service.sh 事后校验补挂
MD=${0%/*}
CF="$MD/config.conf"
[ -f "$CF" ] && . "$CF"
FPS_UNLOCK=${FPS_UNLOCK:-1}
RATE_UNLOCK=${RATE_UNLOCK:-1}
FPS_MAX=${FPS_MAX:-144}
W="$MD/work"
mkdir -p "$W" "$MD/logs"
L="$MD/logs/post-fs.log"
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$L"; }
case "$FPS_MAX" in ''|*[!0-9]*) FPS_MAX=144 ;; esac

validate() {
  [ -s "$2" ] || return 1
  os=$(wc -c < "$1" 2>/dev/null || echo 0)
  ns=$(wc -c < "$2" 2>/dev/null || echo 0)
  [ "$os" -gt 0 ] || return 1
  [ "$ns" -ge $((os * 8 / 10)) ] || return 1
  lo=$(tr -cd '<' < "$1" | wc -c)
  ln=$(tr -cd '<' < "$2" | wc -c)
  [ "$lo" -eq "$ln" ] || return 1
  return 0
}

bind_it() {
  src="$1"; out="$2"
  ctx=$(ls -Zd "$src" 2>/dev/null | awk '{print $1}')
  [ -n "$ctx" ] && chcon "$ctx" "$out" 2>/dev/null
  mount -o bind "$out" "$src" 2>/dev/null
  if cmp -s "$out" "$src" 2>/dev/null; then
    log "OK $src ctx=$ctx"
  else
    log "BIND-SHADOWED $src（挂载已建立但读取仍是原文件，交给 service.sh 重试）"
  fi
}

patch_fps() {
  src=/vendor/etc/display/thermallevel_to_fps.xml
  if [ ! -f "$src" ]; then log "MISS $src"; return; fi
  out="$W/thermallevel_to_fps.xml"
  sed "s/fps=\"[0-9]*\"/fps=\"$FPS_MAX\"/g" "$src" > "$out" 2>/dev/null
  if ! grep -q "fps=\"$FPS_MAX\"" "$out" 2>/dev/null; then log "NOMATCH fps"; return; fi
  if ! validate "$src" "$out"; then log "VALIDATE-FAIL fps"; return; fi
  bind_it "$src" "$out"
  # 放进 mountify overlay 的 lowerdir，让它从建立起就是补丁版
  st=/mnt/vendor/mountify/vendor/etc
  if [ -d "$st" ]; then
    if mkdir -p "$st/display" 2>/dev/null && cp "$out" "$st/display/thermallevel_to_fps.xml" 2>/dev/null; then
      chcon u:object_r:vendor_configs_file:s0 "$st/display/thermallevel_to_fps.xml" 2>/dev/null
      log "STAGED $st/display/thermallevel_to_fps.xml"
    else
      log "STAGE-FAIL $st"
    fi
  else
    log "NO-STAGING $st 不存在"
  fi
}

patch_rate() {
  src=/my_product/etc/refresh_rate_config.xml
  if [ ! -f "$src" ]; then log "MISS $src"; return; fi
  out="$W/refresh_rate_config.xml"
  sed 's/2-2-2-2/0-0-0-0/g' "$src" > "$out" 2>/dev/null
  if cmp -s "$src" "$out"; then log "SKIP rate（无 2-2-2-2）"; return; fi
  if ! validate "$src" "$out"; then log "VALIDATE-FAIL rate"; return; fi
  bind_it "$src" "$out"
}

[ "$FPS_UNLOCK" = 1 ] && patch_fps
[ "$RATE_UNLOCK" = 1 ] && patch_rate
log "done fps_unlock=$FPS_UNLOCK rate_unlock=$RATE_UNLOCK fps_max=$FPS_MAX"
