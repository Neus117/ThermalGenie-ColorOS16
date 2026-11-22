#!/system/bin/sh
# Thermal Genie - 开机守护
#   1) 等 boot 完成，校验两处帧率补丁是否真的被读到，没有就补挂
#   2) 拉起 genie.sh；进程退出或心跳停止都会自动重启（防卡死）
MD=${0%/*}
mkdir -p "$MD/logs"
L="$MD/logs/genie.log"
HB="$MD/.hb"

n=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ $n -lt 90 ]; do
  n=$((n + 1))
  sleep 2
done
sleep 5

fix() {
  out="$1"; dst="$2"; i=0
  [ -f "$out" ] || return 0
  [ -f "$dst" ] || return 0
  while [ $i -lt 5 ]; do
    if cmp -s "$out" "$dst" 2>/dev/null; then
      echo "[$(date '+%m-%d %H:%M:%S')] verify OK $dst (try $i)" >> "$L"
      return 0
    fi
    mount -o bind "$out" "$dst" 2>/dev/null
    sleep 2
    i=$((i + 1))
  done
  if cmp -s "$out" "$dst" 2>/dev/null; then
    echo "[$(date '+%m-%d %H:%M:%S')] verify OK $dst (after $i tries)" >> "$L"
  else
    echo "[$(date '+%m-%d %H:%M:%S')] PATCH-FAIL $dst 已尝试 $i 次，读取仍不是补丁版" >> "$L"
  fi
}

fix "$MD/work/thermallevel_to_fps.xml" /vendor/etc/display/thermallevel_to_fps.xml
fix "$MD/work/refresh_rate_config.xml" /my_product/etc/refresh_rate_config.xml
# ---- 温度墙解锁（可选，默认关闭；sysfs 写入重启即恢复）----
THERMAL_UNLOCK=0
THERMAL_DELTA=5000
THERMAL_CAP=97000
[ -f "$MD/config.conf" ] && . "$MD/config.conf"

unlock_thermal() {
  [ "$THERMAL_UNLOCK" = 1 ] || return 0
  n=0
  for z in /sys/class/thermal/thermal_zone*; do
    ty=$(cat "$z/type" 2>/dev/null)
    case "$ty" in
      cpu-*|sys-therm-*) ;;
      *) continue ;;
    esac
    i=0
    while [ "$i" -lt 8 ]; do
      f="$z/trip_point_${i}_temp"
      v=$(cat "$f" 2>/dev/null)
      idx=$i
      i=$((i + 1))
      case "$v" in ''|*[!0-9]*) continue ;; esac
      # 只处理原始区间 85.0~92.0℃，改过的 93+ 不会重复抬高（幂等）
      if [ "$v" -lt 85000 ] || [ "$v" -gt 96000 ]; then continue; fi
      nv=$((v + THERMAL_DELTA))
      [ "$nv" -gt "$THERMAL_CAP" ] && nv=$THERMAL_CAP
      echo "$nv" > "$f" 2>/dev/null
      nb=$(cat "$f" 2>/dev/null)
      if [ "$nb" = "$nv" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')] THERMAL $ty trip$idx $v -> $nv" >> "$L"
        n=$((n + 1))
      else
        echo "[$(date '+%m-%d %H:%M:%S')] THERMAL-FAIL $ty trip$idx want=$nv got=$nb" >> "$L"
      fi
    done
  done
  echo "[$(date '+%m-%d %H:%M:%S')] THERMAL-UNLOCK 完成，成功修改 $n 处（delta=+${THERMAL_DELTA}mC cap=${THERMAL_CAP}mC）" >> "$L"
}
unlock_thermal
# 让管理器卡片反映当前的实际开关（module.prop 的 description 是静态的，这里按 config 重写）
sh "$MD/bin/desc.sh" 2>/dev/null
# 系统可能在开机后重写 trip 点，隔一段时间复核并按需补写
(
  sleep 30; unlock_thermal
  sleep 60; unlock_thermal
) &

# 监管循环：进程活着但心跳停了（卡死）也要杀掉重启
(
  fail=0
  while :; do
    t0=$(date +%s)
    sh "$MD/bin/genie.sh" &
    dpid=$!
    echo "[$(date '+%m-%d %H:%M:%S')] genie start pid=$dpid" >> "$L"
    while :; do
      sleep 15
      if ! kill -0 "$dpid" 2>/dev/null; then
        echo "[$(date '+%m-%d %H:%M:%S')] genie 退出" >> "$L"
        break
      fi
      now=$(date +%s)
      hb=$(cat "$HB" 2>/dev/null)
      case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
      stale=0
      if [ "$hb" -gt 0 ]; then
        [ $((now - hb)) -gt 150 ] && stale=1
      else
        # 心跳文件为空/缺失：只在进程处于 D/T/Z 等异常状态时才判定卡死，
        # 避免"写心跳瞬间被读"或"深睡刚醒"被误杀
        ps_=$(awk '{print $3}' "/proc/$dpid/stat" 2>/dev/null)
        case "$ps_" in
          D*|T*|Z*) [ $((now - t0)) -gt 120 ] && stale=1 ;;
        esac
      fi
      if [ "$stale" = 1 ]; then
        # 复检：深睡时守护进程和本进程一起被冻结，刚醒时心跳看起来是旧的
        sleep 5
        hb2=$(cat "$HB" 2>/dev/null)
        case "$hb2" in ''|*[!0-9]*) hb2=0 ;; esac
        if [ "$hb2" -gt 0 ] && [ $(( $(date +%s) - hb2 )) -le 60 ]; then
          continue
        fi
        echo "[$(date '+%m-%d %H:%M:%S')] WATCHDOG 心跳停了 $((now - hb))s，强杀重启" >> "$L"
        pkill -9 -P "$dpid" 2>/dev/null
        kill -CONT "$dpid" 2>/dev/null
        kill -9 "$dpid" 2>/dev/null
        sleep 3
        break
      fi
    done
    # 频繁秒退时退避，避免刷屏
    if [ $(( $(date +%s) - t0 )) -lt 10 ]; then
      fail=$((fail + 1))
    else
      fail=0
    fi
    if [ "$fail" -gt 5 ]; then
      echo "[$(date '+%m-%d %H:%M:%S')] 连续快速失败 $fail 次，等待 60s" >> "$L"
      sleep 60
      fail=0
    else
      sleep 5
    fi
  done
) &
