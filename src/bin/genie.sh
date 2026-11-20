#!/system/bin/sh
# Thermal Genie - 守护进程
#   1) 壳温诱骗
#   2) 充电降温解锁（含可选自动 A/B：每次充电交替开关，日志里标记 ab=on/off）
#   3) 安全护栏（充电与非充电统一 52.0℃ 停写 / 47.0℃ 恢复）
#   4) 自动采集：充电时每秒一个功率样本，每次充电结束写一条汇总
MD=$(cd "$(dirname "$0")/.." && pwd)
CF="$MD/config.conf"
LD="$MD/logs"
mkdir -p "$LD"
LOG="$LD/genie.log"
SUM="$LD/charging.log"

# 版本号从 module.prop 读，避免日志里写死导致版本对不上
VER=$(sed -n 's/^version=//p' "$MD/module.prop" 2>/dev/null | head -n1)
[ -z "$VER" ] && VER="unknown"

# ---- 默认值 ----
SHELL_SPOOF=1
SHELL_MODE=trigger
SHELL_TRIGGER=350
SHELL_TEMP=37000
CHARGE_SPOOF=1
CHARGE_TRIGGER=300
CHARGE_AB=0
CHARGE_SAMPLE=1
GUARD_TRIGGER=480
GUARD_RELEASE=430
GUARD_TRIGGER_GAME=520
GUARD_RELEASE_GAME=470
GUARD_VALUE_MIN=50000
GUARD_OFFSET=8000
TICK=0.2
TELEMETRY=1
ADAPTIVE=1
STANDBY=1
# 设备挂起超过这么久，醒来后就把这段按「补账」记成一次熄屏（0=关闭补账）
SB_GAP_MIN=90
[ -f "$CF" ] && . "$CF"

san() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
SHELL_TRIGGER=$(san "$SHELL_TRIGGER" 350)
CHARGE_TRIGGER=$(san "$CHARGE_TRIGGER" 300)
CHARGE_SAMPLE=$(san "$CHARGE_SAMPLE" 1)
[ "$CHARGE_SAMPLE" -lt 1 ] && CHARGE_SAMPLE=1
SHELL_TEMP=$(san "$SHELL_TEMP" 37000)
GUARD_TRIGGER=$(san "$GUARD_TRIGGER" 480)
GUARD_RELEASE=$(san "$GUARD_RELEASE" 430)
GUARD_TRIGGER_GAME=$(san "$GUARD_TRIGGER_GAME" 520)
GUARD_RELEASE_GAME=$(san "$GUARD_RELEASE_GAME" 470)
GUARD_VALUE_MIN=$(san "$GUARD_VALUE_MIN" 50000)
GUARD_OFFSET=$(san "$GUARD_OFFSET" 8000)
SB_GAP_MIN=$(san "$SB_GAP_MIN" 90)
[ "$GUARD_RELEASE" -ge "$GUARD_TRIGGER" ] && GUARD_RELEASE=$((GUARD_TRIGGER - 50))
[ "$GUARD_RELEASE_GAME" -ge "$GUARD_TRIGGER_GAME" ] && GUARD_RELEASE_GAME=$((GUARD_TRIGGER_GAME - 50))

# TICK 校验：只允许正数秒；非法值回落 0.2，否则 sleep 会被跳过导致忙循环
fix_tick() {
  case "$TICK" in
    ''|*[!0-9.]*|.*|*.|*..*|0|0.0|0.00) TICK=0.2 ;;
  esac
  sleep "$TICK" 2>/dev/null || TICK=0.2
}
fix_tick

# ---- 自适应节拍：诱骗/充电 5Hz，空闲 1Hz（ADAPTIVE/STANDBY 的默认值在上面 config 之前）----
SAMPLE_MOD=5
TELE_MOD=25
set_mode() {
  case "$1" in
    fast) TICK=0.2; SAMPLE_MOD=${CHARGE_SAMPLE:-5}; TELE_MOD=25 ;;
    mid)  TICK=0.5; SAMPLE_MOD=2; TELE_MOD=10 ;;
    *)    TICK=2;   SAMPLE_MOD=1; TELE_MOD=3  ;;
  esac
}

PS=/proc/shell-temp
NCD=/sys/class/oplus_chg/battery/cool_down
NB=/sys/class/power_supply/battery
NTB=$NB/temp
NCUR=$NB/current_now
NVOL=$NB/voltage_now
NPW=$NB/power_now
NCAP=$NB/capacity
NST=$NB/status
NC4=/sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq
NC7=/sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq
PWC=/sys/power/wakeup_count
PSS=/sys/power/suspend_stats/success
PSF=/sys/power/suspend_stats/fail
PLF=/sys/power/suspend_stats/last_failed_dev
NM0=/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
NM4=/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq
NM7=/sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq
NGPU=/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq
NGMAX=/sys/class/kgsl/kgsl-3d0/devfreq/max_freq
NGLOAD=/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage
ZCPU=/sys/class/thermal/thermal_zone2/temp
ZCPUSS=/sys/class/thermal/thermal_zone22/temp
ZPMIC=/sys/class/thermal/thermal_zone75/temp
CDIR=/sys/class/thermal
PWS=/sys/kernel/debug/wakeup_sources
PDBG=/sys/kernel/debug
UPTIME=/proc/uptime

# ---- 运行期不变的节点列表：启动时扫一次，之后不再每轮遍历全部 zone / 冷却设备 ----
TZONES=""
for z in "$CDIR"/thermal_zone*; do
  case $(cat "$z/type" 2>/dev/null) in
    cpu-*|sys-therm-*) TZONES="$TZONES $z" ;;
  esac
done
CDEVS=""
CDEVPATHS=""
for c in "$CDIR"/cooling_device*; do
  t=$(cat "$c/type" 2>/dev/null)
  case "$t" in *cluster*) CDEVS="$CDEVS $c|$t"; CDEVPATHS="$CDEVPATHS $c/cur_state" ;; esac
done

# ---- 单实例锁 ----
LK=/data/local/tmp/.thermal_genie.lock
if ! mkdir "$LK" 2>/dev/null; then
  p=$(cat "$LK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    # 持有者活着但心跳超 90 秒不动 = 卡死，允许接管
    h=$(cat "$MD/.hb" 2>/dev/null)
    case "$h" in ''''|*[!0-9]*) h=0 ;; esac
    n=$(date +%s)
    if [ "$h" -gt 0 ] && [ $((n - h)) -le 90 ]; then exit 0; fi
    kill -CONT "$p" 2>/dev/null
    kill -9 "$p" 2>/dev/null
    sleep 1
  fi
  rm -rf "$LK"
  mkdir "$LK" 2>/dev/null || exit 1
fi
echo $$ > "$LK/pid"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }
# 外部命令一律带 5 秒超时：dumpsys / debugfs 卡住时不能把整个守护进程拖死
to() { if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi; }
wr() { for k in 0 1 2 3; do echo "$k $1" > "$PS" 2>/dev/null; done; }
today() { date +%Y%m%d; }
# 温度墙：周期性复核，被系统改写就补回（同一进程内幂等：只处理 85~92℃ 的原始值）
therm_fix() {
  [ "${THERMAL_UNLOCK:-0}" = 1 ] || return 0
  tn=0
  for tz in $TZONES; do
    # 一个 awk 读完这个 zone 的全部 trip（原来每个 trip 一次 cat = 8 次 fork）
    for pair in $(awk 'FNR==1{print FILENAME "=" $1}' "$tz"/trip_point_*_temp 2>/dev/null); do
      tf=${pair%%=*}
      tv=${pair#*=}
      case "$tf" in *trip_point_[0-7]_temp) ;; *) continue ;; esac
      case "$tv" in ''|*[!0-9]*) continue ;; esac
      if [ "$tv" -lt 85000 ] || [ "$tv" -gt 92000 ]; then continue; fi
      tnv=$((tv + ${THERMAL_DELTA:-5000}))
      [ "$tnv" -gt "${THERMAL_CAP:-98000}" ] && tnv=${THERMAL_CAP:-98000}
      echo "$tnv" > "$tf" 2>/dev/null
      tn=$((tn + 1))
    done
  done
  [ "$tn" -gt 0 ] && log "THERMAL-FIX 补写 $tn 处 trip"
  return 0
}
# 冷却设备直控：电池温度低于护栏时，把 cpu-cluster* 的 cur_state 钉在 0（不许降频）
# 注意：这是绕过内核温控的最后一步，只在 THERMAL_UNLOCK=1 且 CDEV_UNLOCK=1 时启用
cdev_pin() {
  [ "${CDEV_UNLOCK:-0}" = 1 ] || return 0
  # 先把电池温度参数存下来：下面的 set -- 会覆盖位置参数
  tbv=$1
  # 芯片级保险：结温到 96℃ 就交回系统，避免撞到 100℃ 的 hot trip（紧急关机）
  # 两个结温节点一次读完（原来两次 cat）
  set -- $(awk 'FNR==1{print $1}' "$ZCPU" "$ZCPUSS" 2>/dev/null)
  zt1=${1:-0}
  zt2=${2:-0}
  case "$zt1" in ''|*[!0-9]*) zt1=0 ;; esac
  case "$zt2" in ''|*[!0-9]*) zt2=0 ;; esac
  if [ "$zt1" -ge 96000 ] || [ "$zt2" -ge 96000 ]; then
    if [ "$cd_pinned" = 1 ]; then
      log "CDEV-RELEASE 结温高 z2=$zt1 z22=$zt2，交回系统"
      cd_pinned=0
    fi
    return 0
  fi
  if [ "$tbv" -ge "${CDEV_GUARD:-520}" ]; then
    if [ "$cd_pinned" = 1 ]; then
      log "CDEV-RELEASE tb=$tbv >= guard=${CDEV_GUARD:-520}，交回系统"
      cd_pinned=0
    fi
    return 0
  fi
  # 冷却设备状态一次读完（原来每个设备一次 cat，30 个设备就是 30 次 fork）
  for pair in $(awk 'FNR==1{print FILENAME "=" $1}' $CDEVPATHS 2>/dev/null); do
    csfile=${pair%%=*}
    cs=${pair#*=}
    [ "$cs" = "0" ] && continue
    cdir=${csfile%/cur_state}
    echo 0 > "$csfile" 2>/dev/null
    cn=$(cat "$csfile" 2>/dev/null)
    if [ "$cn" = "0" ] && [ "$cd_pinned" != 1 ]; then
      cty=""
      for ci in $CDEVS; do
        case "$ci" in "$cdir|"*) cty=${ci##*|}; break ;; esac
      done
      log "CDEV-PIN ${cty:-$cdir} $cs -> 0 (tb=$tbv)"
      cd_pinned=1
    fi
  done
}
own_ticks() { awk '{print $14+$15+$16+$17}' /proc/$$/stat 2>/dev/null || echo 0; }
numv() { case "$1" in ''|*[!0-9]*) echo "" ;; *) echo "$1" ;; esac; }
delta() {
  n=$(numv "$1"); o=$(numv "$2")
  if [ -n "$n" ] && [ -n "$o" ] && [ "$n" -ge "$o" ]; then echo $((n - o)); else echo "n/a"; fi
}

DAY=$(today)
TEL="$LD/telemetry-$DAY.log"
SBF="$LD/standby.log"
SBD="$LD/standby-$DAY.log"

sleep 0.1 2>/dev/null || TICK=1
fix_tick

ABF="$MD/.ab_state"
ab_mode=$(cat "$ABF" 2>/dev/null)
[ "$ab_mode" = "off" ] || ab_mode="on"

# ---- 数据源自检：一次说清能记什么，避免装完才发现缺数据 ----
WKSRC=0
[ -r "$PWS" ] && WKSRC=1
if [ "$WKSRC" = 0 ]; then
  to mount -t debugfs none "$PDBG" 2>/dev/null
  [ -r "$PWS" ] && WKSRC=1
fi
SSTATS=0
[ -r "$PSS" ] && SSTATS=1
WCOUNT=skip
TOOL=0
command -v timeout >/dev/null 2>&1 && TOOL=1
log "CAPS wakeup_sources=$WKSRC suspend_stats=$SSTATS timeout=$TOOL note=no_wakeup_count"

log "start $VER pid=$$ tick=$TICK shell=$SHELL_SPOOF/$SHELL_MODE/$SHELL_TRIGGER charge=$CHARGE_SPOOF/$CHARGE_TRIGGER ab=$CHARGE_AB/$ab_mode guard=$GUARD_TRIGGER/$GUARD_RELEASE game=$GUARD_TRIGGER_GAME/$GUARD_RELEASE_GAME"

therm_fix
guarded=0
guarded_mode=""
prev=""
last_st=""
s_start=0; s_cap=0; s_peak=0; s_sum=0; s_n=0; s_maxtb=0; s_guard=0; s_maxcur=0
vbad=0; cdbad=0
last_m7=""
cd_pinned=0
sb_chg=0
MODE=""
sb_active=0; sb_start=0; sb_cap0=0; sb_sum=0; sb_n=0; sb_cpu0=0

# ---- 待机会话状态落盘 ----
# 这些变量只在内存里时，进程被看门狗杀掉/重启，正在进行的那段熄屏就永远写不出来
# （11-19 一天被杀了 4 次）。每轮把状态写进 .sbstate，重启后接着算。
SBST="$MD/.sbstate"
sb_cap_last=""
sb_t_last=0
sb_resumed=0
sb_save() {
  {
    echo "sb_ver=1"
    echo "sb_active=$sb_active"
    echo "sb_start=$sb_start"
    echo "sb_cap0=$sb_cap0"
    echo "sb_sum=$sb_sum"
    echo "sb_n=$sb_n"
    echo "sb_cpu0=$sb_cpu0"
    echo "sb_ss0=$sb_ss0"
    echo "sb_sf0=$sb_sf0"
    echo "sb_chg=$sb_chg"
    echo "sb_cap_last=$sb_cap_last"
    echo "sb_t=$epoch"
  } > "$SBST.tmp" 2>/dev/null && mv -f "$SBST.tmp" "$SBST" 2>/dev/null
}
sb_load() {
  [ -f "$SBST" ] || return 0
  sb_ver=0
  . "$SBST" 2>/dev/null
  [ "${sb_ver:-0}" = "1" ] || return 0
  sb_active=$(san "$sb_active" 0)
  sb_start=$(san "$sb_start" 0)
  sb_cap0=$(san "$sb_cap0" 0)
  sb_sum=$(san "$sb_sum" 0)
  sb_n=$(san "$sb_n" 0)
  sb_cpu0=$(san "$sb_cpu0" 0)
  sb_ss0=$(san "$sb_ss0" 0)
  sb_sf0=$(san "$sb_sf0" 0)
  sb_chg=$(san "$sb_chg" 0)
  sb_cap_last=$(san "$sb_cap_last" "")
  sb_t_last=$(san "$sb_t" 0)
  tnow=$(date +%s)
  # 本次开机的起点：跨重启的会话不能续算（关机/重启那段不是待机，硬接上去会把时长算大）
  up=$(cut -d. -f1 "$UPTIME" 2>/dev/null)
  case "$up" in ''|*[!0-9]*) up="" ;; esac
  boot_epoch=0
  [ -n "$up" ] && boot_epoch=$((tnow - up))
  # 补账锚点同样不能跨重启
  if [ "$boot_epoch" -gt 0 ] && [ "$sb_t_last" -gt 0 ] && [ "$sb_t_last" -lt "$boot_epoch" ]; then
    sb_cap_last=""; sb_t_last=0
  fi
  # 只接受 36 小时内、且发生在本轮开机之后的会话
  if [ "$sb_active" = "1" ] && [ "$sb_start" -gt 0 ] && [ $((tnow - sb_start)) -le 129600 ]; then
    if [ "$boot_epoch" -gt 0 ] && [ "$sb_start" -lt "$boot_epoch" ]; then
      log "STANDBY-DROP pre-boot start=$sb_start boot=$boot_epoch"
      sb_active=0; sb_start=0; sb_cap0=0; sb_sum=0; sb_n=0; sb_cpu0=0
      sb_ss0=0; sb_sf0=0; sb_chg=0; sb_cap_last=""; sb_t_last=0
      return 0
    fi
    sb_resumed=1
    log "STANDBY-RESUME start=$sb_start elapsed=$((tnow - sb_start))s cap=$sb_cap0 samples=$sb_n"
    # CPU 计数是按进程算的：旧进程的基线跨进程无效，用当前进程重新取基线。
    # 于是 resume=1 那条线的 cpu= 只统计重启之后的部分（samples/n 才是整段）。
    u0=$(awk '{print $14+$15+$16+$17}' "/proc/$$/stat" 2>/dev/null)
    case "$u0" in ''|*[!0-9]*) u0=0 ;; esac
    sb_cpu0=$u0
  else
    sb_active=0
  fi
}
[ "$STANDBY" = "1" ] && sb_load
i=0
while :; do
  i=$((i + 1))
  epoch=$(date +%s)
  # 心跳每 5 轮写一次（慢档 2 秒节拍 = 10 秒一次；看门狗阈值 150 秒），省掉每轮的 mv
  if [ $((i % 5)) -eq 1 ]; then
    echo "$epoch" > "$MD/.hb.tmp" 2>/dev/null && mv -f "$MD/.hb.tmp" "$MD/.hb" 2>/dev/null
  fi

  if [ $((i % 50)) -eq 0 ] && [ -f "$CF" ]; then
    . "$CF"
    GUARD_TRIGGER=$(san "$GUARD_TRIGGER" 480)
    GUARD_RELEASE=$(san "$GUARD_RELEASE" 430)
    GUARD_TRIGGER_GAME=$(san "$GUARD_TRIGGER_GAME" 520)
    GUARD_RELEASE_GAME=$(san "$GUARD_RELEASE_GAME" 470)
    [ "$GUARD_RELEASE" -ge "$GUARD_TRIGGER" ] && GUARD_RELEASE=$((GUARD_TRIGGER - 50))
    [ "$GUARD_RELEASE_GAME" -ge "$GUARD_TRIGGER_GAME" ] && GUARD_RELEASE_GAME=$((GUARD_TRIGGER_GAME - 50))
    CHARGE_SAMPLE=$(san "$CHARGE_SAMPLE" 1)
    [ "$CHARGE_SAMPLE" -lt 1 ] && CHARGE_SAMPLE=1
    fix_tick
  fi

  d=$(today)
  if [ "$d" != "$DAY" ]; then
    DAY=$d
    TEL="$LD/telemetry-$DAY.log"
    SBD="$LD/standby-$DAY.log"
  fi

  # 一次 awk 读两个节点（原来两次 cat = 两次 fork）
  if [ -r "$NTB" ] && [ -r "$NST" ]; then
    set -- $(awk '{a[NR]=$1} END{print a[1], a[2]}' "$NTB" "$NST" 2>/dev/null)
    tb=${1:-}
    st=${2:-}
  else
    tb=$(cat "$NTB" 2>/dev/null)
    st=$(cat "$NST" 2>/dev/null)
  fi
  case "$tb" in ''|*[!0-9]*) tb=0 ;; esac

  # ---- 补账：熄屏后设备先 suspend，进程还没采样到「熄屏」就被冻结了 ----
  # 醒来时 now - 上次遥测 这段空档必然是挂起（屏幕灭着），按电量差补一条 src=gap。
  # 只在没有进行中的会话时补，避免和正常会话重复记账。
  if [ "$STANDBY" = "1" ] && [ "$sb_active" = "0" ] && [ -n "$sb_cap_last" ] && [ "$sb_t_last" -gt 0 ] && [ "$SB_GAP_MIN" -gt 0 ]; then
    gap=$((epoch - sb_t_last))
    if [ "$gap" -gt "$SB_GAP_MIN" ] && [ "$gap" -le 129600 ] && [ "$st" != Charging ]; then
      cnow=$(cat "$NCAP" 2>/dev/null)
      case "$cnow" in ''|*[!0-9]*) cnow="" ;; esac
      if [ -n "$cnow" ] && [ "$sb_cap_last" -gt "$cnow" ]; then
        if [ "$gap" -ge 1800 ]; then
          grt=$(( (sb_cap_last - cnow) * 360000 / gap ))
          grate="$((grt / 100)).$((grt % 100))%/h"
        else
          grate="n/a"
        fi
        echo "[$(date '+%F %T')] standby dur=${gap}s cap=${sb_cap_last}->${cnow} samples=0 sph=0 avg=0mA rate=${grate} cpu=0ticks ss=n/a lf=- chg=0 mState=n/a src=gap" >> "$SBF"
        log "STANDBY-GAP dur=${gap}s cap=${sb_cap_last}->${cnow} rate=$grate"
        sb_cap_last=$cnow
      fi
    fi
  fi

  if [ "$st" = Charging ]; then
    gt=$GUARD_TRIGGER; gr=$GUARD_RELEASE; gm=charge
  else
    gt=$GUARD_TRIGGER_GAME; gr=$GUARD_RELEASE_GAME; gm=game
  fi

  if [ "$guarded" -eq 0 ] && [ "$tb" -ge "$gt" ]; then
    guarded=1; guarded_mode=$gm; s_guard=1
    v=$((tb * 100 + GUARD_OFFSET))
    [ "$v" -lt "$GUARD_VALUE_MIN" ] && v=$GUARD_VALUE_MIN
    [ "$v" -gt 60000 ] && v=60000
    wr "$v"
    log "GUARD ON mode=$gm tb=$tb trigger=$gt report=$v"
  elif [ "$guarded" -eq 1 ] && [ "$tb" -le "$gr" ]; then
    therm_fix
guarded=0; guarded_mode=""
    log "GUARD OFF mode=$gm tb=$tb release=$gr"
  fi

  dis=0
  [ -f "$MD/DISABLED" ] && dis=1

  if [ "$dis" -eq 1 ]; then
    now=disabled
  elif [ "$guarded" -eq 1 ]; then
    now=guard
  elif [ "$SHELL_SPOOF" = 1 ] && { [ "$SHELL_MODE" = always ] || [ "$tb" -ge "$SHELL_TRIGGER" ]; }; then
    wr "$SHELL_TEMP"; now=fake
  else
    now=real
  fi

  # 每 5 秒校验一次「写了是否真的生效」——只记意图不记效果是最容易自欺的地方
  if [ $((i % TELE_MOD)) -eq 0 ]; then
    if [ "$now" = fake ]; then
      rb=$(cat "$PS" 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | tail -n1)
      if [ "$rb" = "$SHELL_TEMP" ]; then
        [ "$vbad" -eq 1 ] && log "SPOOF-OK 恢复 read=$rb"
        vbad=0
      else
        [ "$vbad" -eq 0 ] && log "SPOOF-FAIL want=$SHELL_TEMP read=${rb:-empty}"
        vbad=1
      fi
    else
      vbad=0
    fi
    if [ "$dis" -eq 0 ] && [ "$guarded" -eq 0 ] && [ "$CHARGE_SPOOF" = 1 ] && [ "$st" = Charging ] && [ "$tb" -ge "$CHARGE_TRIGGER" ]; then
      rcd=$(cat "$NCD" 2>/dev/null)
      if [ "$rcd" = "0" ]; then
        [ "$cdbad" -eq 1 ] && log "CD-OK 恢复"
        cdbad=0
      else
        [ "$cdbad" -eq 0 ] && log "CD-FAIL want=0 read=${rcd:-empty} tb=$tb"
        cdbad=1
      fi
    else
      cdbad=0
    fi
  fi
  if [ "$now" = fake ] && [ "$vbad" -eq 1 ]; then now=fake-fail; fi

  # 节拍：诱骗中或充电中保持 5Hz，其余降到 1Hz（自耗降 5 倍）
  if [ "$ADAPTIVE" = 1 ]; then
    if [ "$now" = fake ] || [ "$now" = fake-fail ]; then
      set_mode fast; m=fast
    elif [ "$st" = Charging ]; then
      set_mode mid; m=mid
    else
      set_mode slow; m=slow
    fi
    if [ "$m" != "$MODE" ]; then
      MODE=$m
      log "TICK $m (${TICK}s)"
    fi
  fi

  if [ "$now" != "$prev" ]; then log "state $prev -> $now tb=$tb"; prev=$now; fi

  if [ "$dis" -eq 0 ] && [ "$guarded" -eq 0 ] && [ "$CHARGE_SPOOF" = 1 ] && [ "$st" = Charging ] && [ "$tb" -ge "$CHARGE_TRIGGER" ]; then
    if [ "$CHARGE_AB" != 1 ] || [ "$ab_mode" = on ]; then
      echo 0 > "$NCD" 2>/dev/null
    fi
  fi

  if [ "$st" = Charging ] && [ "$last_st" != Charging ]; then
    s_start=$(date +%s)
    s_cap=$(cat "$NCAP" 2>/dev/null)
    case "$s_cap" in ''|*[!0-9]*) s_cap=0 ;; esac
    s_peak=0; s_sum=0; s_n=0; s_maxtb=0; s_guard=0; s_maxcur=0
    abtag=off
    [ "$CHARGE_AB" = 1 ] && abtag=$ab_mode
    log "CHARGE-START cap=$s_cap ab=$abtag"
    echo "CAL $(date +%T) st=$(cat "$NST" 2>/dev/null) cur_raw=$(cat "$NCUR" 2>/dev/null) v_raw=$(cat "$NVOL" 2>/dev/null) pw_raw=$(cat "$NPW" 2>/dev/null) cap=$s_cap" >> "$TEL"
  fi
  if [ "$st" != Charging ] && [ "$last_st" = Charging ]; then
    dur=$(( $(date +%s) - s_start ))
    avg=0
    [ "$s_n" -gt 0 ] && avg=$((s_sum / s_n))
    abtag=off
    [ "$CHARGE_AB" = 1 ] && abtag=$ab_mode
    echo "[$(date '+%F %T')] dur=${dur}s cap=${s_cap}->$(cat "$NCAP" 2>/dev/null) samples=$s_n peak=${s_peak}mW avg=${avg}mW maxCur=${s_maxcur}mA maxTb=${s_maxtb} guard=$s_guard ab=$abtag" >> "$SUM"
    log "CHARGE-END dur=${dur}s peak=${s_peak}mW avg=${avg}mW maxCur=${s_maxcur}mA"
    s_start=0
    if [ "$CHARGE_AB" = 1 ]; then
      if [ "$ab_mode" = on ]; then ab_mode=off; else ab_mode=on; fi
      echo "$ab_mode" > "$ABF"
      log "AB-TURN ab=$ab_mode"
    fi
  fi
  last_st=$st

  if [ $((i % SAMPLE_MOD)) -eq 0 ]; then
    c=$(cat "$NCUR" 2>/dev/null)
    case "$c" in ''|*[!0-9-]*) c=0 ;; esac
    if [ "$st" = Charging ]; then
      vv=$(cat "$NVOL" 2>/dev/null)
      case "$vv" in ''|*[!0-9]*) vv=0 ;; esac
      ac=$c
      [ "$c" -lt 0 ] && ac=$((0 - c))
      if [ "$c" -lt 0 ]; then
        pw=$((ac * vv / 1000000))
      else
        pw=0
      fi
      [ "$ac" -gt "$s_maxcur" ] && s_maxcur=$ac
      [ "$pw" -gt "$s_peak" ] && s_peak=$pw
      if [ "$pw" -gt 0 ]; then s_sum=$((s_sum + pw)); s_n=$((s_n + 1)); fi
      [ "$tb" -gt "$s_maxtb" ] && s_maxtb=$tb
      abtag=off
      [ "$CHARGE_AB" = 1 ] && abtag=$ab_mode
      [ "$sb_active" = 1 ] && sb_chg=1
      echo "CHG $(date +%T) pw=${pw}mW tb=$tb cur=${c}mA v=${vv}uV cd=$(cat "$NCD" 2>/dev/null) cap=$(cat "$NCAP" 2>/dev/null) ab=$abtag sp=$now" >> "$TEL"
    elif [ "$sb_active" = 1 ]; then
      ac=$c
      [ "$c" -lt 0 ] && ac=$((0 - c))
      if [ "$ac" -gt 0 ]; then sb_sum=$((sb_sum + ac)); sb_n=$((sb_n + 1)); fi
    fi
  fi

  if [ $((i % 30)) -eq 0 ]; then therm_fix; fi
  if [ $((i % 5)) -eq 0 ]; then cdev_pin "$tb"; fi

  if [ "$TELEMETRY" = 1 ] && [ $((i % TELE_MOD)) -eq 0 ]; then
    wake=$(to dumpsys power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*')
    m0=$(cat "$NM0" 2>/dev/null); m4=$(cat "$NM4" 2>/dev/null); m7=$(cat "$NM7" 2>/dev/null)
    gpu=$(cat "$NGPU" 2>/dev/null); gmax=$(cat "$NGMAX" 2>/dev/null); gl=$(cat "$NGLOAD" 2>/dev/null)
    z2=$(cat "$ZCPU" 2>/dev/null); z22=$(cat "$ZCPUSS" 2>/dev/null); z75=$(cat "$ZPMIC" 2>/dev/null)
    cdsum=$(awk '{s+=$1} END{print s+0}' "$CDIR"/cooling_device*/cur_state 2>/dev/null)
    echo "TEL $(date +%T) $wake st=$st cur=$(cat "$NCUR" 2>/dev/null) v=$(cat "$NVOL" 2>/dev/null) tb=$tb cd=$(cat "$NCD" 2>/dev/null) cdv=$cdbad sh=$(cat "$PS" 2>/dev/null) vbad=$vbad c4=$(cat "$NC4" 2>/dev/null) c7=$(cat "$NC7" 2>/dev/null) m0=$m0 m4=$m4 m7=$m7 gpu=$gpu gmax=$gmax gl=$gl cds=$cdsum z2=$z2 z22=$z22 z75=$z75 sp=$now g=$guarded_mode sb=$sb_active" >> "$TEL"
    # 频率上限一变就立刻记一条，不依赖 5 秒采样的运气
    if [ -n "$m7" ] && [ "$m7" != "$last_m7" ]; then
      echo "THR $(date +%T) m7=$m7 tb=$tb z2=$z2 z22=$z22 z75=$z75 gpu=$gpu gmax=$gmax cds=$cdsum sh=$(cat "$PS" 2>/dev/null) sp=$now" >> "$TEL"
      last_m7=$m7
    fi
    # 轮转检查不必每轮做：每 5 个遥测周期看一次大小就够
    if [ $((i % (TELE_MOD * 5))) -eq 0 ]; then
      [ "$(wc -c < "$TEL" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$TEL" "$TEL.1"
    fi

    if [ "$sb_active" = 1 ] && [ -z "$sb_idle" ]; then
      if [ $(( $(date +%s) - sb_start )) -ge 60 ]; then
        sb_idle=$(to dumpsys deviceidle 2>/dev/null | grep -m1 -o 'mState=[A-Z_]*')
      fi
    fi

    # ---- 待机会话：熄屏开始 -> 亮屏结束，写一条汇总 ----
    if [ "$STANDBY" = 1 ]; then
      case "$wake" in
        *Awake*)
          if [ "$sb_active" = 1 ]; then
            sb_active=0
            [ "$sb_resumed" = "1" ] && sb_resume_tag=" resume=1" || sb_resume_tag=""
            sb_resumed=0
            sbdur=$(( $(date +%s) - sb_start ))
            sbcap1=$(cat "$NCAP" 2>/dev/null)
            case "$sbcap1" in ''|*[!0-9]*) sbcap1=$sb_cap0 ;; esac
            sbavg=0
            [ "$sb_n" -gt 0 ] && sbavg=$((sb_sum / sb_n))
            sbsph=0
            [ "$sbdur" -gt 0 ] && sbsph=$(( sb_n * 3600 / sbdur ))
            # 时长短于 30 分钟、或电量不降反升（充电段没被识别出来）时，速率没有意义
            sbrate="n/a"
            if [ "$sbdur" -ge 1800 ] && [ "$sb_chg" = 0 ] && [ "$sb_cap0" -gt "$sbcap1" ]; then
              sbr=$(( (sb_cap0 - sbcap1) * 360000 / sbdur ))
              sbrate="$((sbr / 100)).$((sbr % 100))%/h"
            fi
            u=$(awk '{print $14+$15+$16+$17}' "/proc/$$/stat" 2>/dev/null)
            case "$u" in ''|*[!0-9]*) u=0 ;; esac
            sbcpu=$((u - sb_cpu0))
            [ "$sbcpu" -lt 0 ] && sbcpu=0
            sbwc="skip"
            ps1=$(cat "$PSS" 2>/dev/null)
            case "$ps1" in ''|*[!0-9]*) ps1=0 ;; esac
            pf1=$(cat "$PSF" 2>/dev/null)
            case "$pf1" in ''|*[!0-9]*) pf1=0 ;; esac
            if [ "$ps1" -ge "$sb_ss0" ]; then s1=$((ps1 - sb_ss0)); else s1="n/a"; fi
            if [ "$pf1" -ge "$sb_sf0" ]; then f1=$((pf1 - sb_sf0)); else f1="n/a"; fi
            sbss="$s1/$f1"
            sblf=$(cat "$PLF" 2>/dev/null)
            [ -z "$sblf" ] && sblf="-"
            idle="$sb_idle"
            [ -z "$idle" ] && idle=$(to dumpsys deviceidle 2>/dev/null | grep -m1 -o 'mState=[A-Z_]*')
            [ -z "$idle" ] && idle="mState=?"
            echo "[$(date '+%F %T')] standby dur=${sbdur}s cap=${sb_cap0}->${sbcap1} samples=$sb_n sph=${sbsph} avg=${sbavg}mA rate=${sbrate} cpu=${sbcpu}ticks ss=${sbss} lf=${sblf} chg=${sb_chg} ${idle}${sb_resume_tag}" >> "$SBF"
            # 唤醒源按「持锁时间增量」排序，次数多不代表耗电（event5 22.9 万次只持有 22 秒）
            wsrc=""
            to awk 'NR>1{print $1, $7}' "$PWS" > "$MD/.ws1" 2>/dev/null
            if [ -f "$MD/.ws0" ] && [ -s "$MD/.ws1" ]; then
              wsrc=$(to awk 'FNR==NR{a[$1]+=$2; next} {b[$1]+=$2} END{for(n in b){d=b[n]-a[n]; if (d>0) printf "%d %s\n", d, n}}' "$MD/.ws0" "$MD/.ws1" 2>/dev/null | sort -nr | head -5 | awk '{printf "%s:%d ", $2, $1}' | cut -c1-260)
            fi
            [ -z "$wsrc" ] && wsrc="n/a"
            echo "WAKE $(date '+%F %T') $idle top=$wsrc ss=${sbss} lf=${sblf}" >> "$SBD"
            log "STANDBY-END dur=${sbdur}s rate=${sbrate} avg=${sbavg}mA cpu=${sbcpu}ticks ${idle}"
            sb_save
          fi
          ;;
        *)
          if [ "$sb_active" = 0 ]; then
            sb_active=1
            sb_start=$(date +%s)
            sb_cap0=$(cat "$NCAP" 2>/dev/null)
            case "$sb_cap0" in ''|*[!0-9]*) sb_cap0=0 ;; esac
            sb_sum=0; sb_n=0
            u0=$(awk '{print $14+$15+$16+$17}' "/proc/$$/stat" 2>/dev/null)
            case "$u0" in ''|*[!0-9]*) u0=0 ;; esac
            sb_cpu0=$u0
            sb_ss0=$(cat "$PSS" 2>/dev/null)
            sb_sf0=$(cat "$PSF" 2>/dev/null)
            sb_chg=0
            sb_idle=""
            to awk 'NR>1{print $1, $7}' "$PWS" > "$MD/.ws0" 2>/dev/null
            log "STANDBY-START cap=$sb_cap0"
            sb_save
          fi
          ;;
      esac
    fi

    # 记下这一刻的电量与时间：进程被杀/设备冻结后，靠它给「补账」提供起点
    if [ "$STANDBY" = "1" ]; then
      capn=$(cat "$NCAP" 2>/dev/null)
      case "$capn" in ''|*[!0-9]*) ;; *) sb_cap_last=$capn ;; esac
      sb_t_last=$epoch
      sb_save
    fi
  fi

  sleep "$TICK"
done
