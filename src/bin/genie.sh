#!/system/bin/sh
# Thermal Genie - 守护进程
#   1) 壳温诱骗
#   2) 充电降温解锁（含可选自动 A/B：每次充电交替开关，日志里标记 ab=on/off）
#   3) 双档安全护栏（充电 48C / 游戏 52C）
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
  for tz in /sys/class/thermal/thermal_zone*; do
    tty=$(cat "$tz/type" 2>/dev/null)
    case "$tty" in cpu-*|sys-therm-*) ;; *) continue ;; esac
    ti=0
    while [ "$ti" -lt 8 ]; do
      tf="$tz/trip_point_${ti}_temp"
      tv=$(cat "$tf" 2>/dev/null)
      ti=$((ti + 1))
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
  # 芯片级保险：结温到 96℃ 就交回系统，避免撞到 100℃ 的 hot trip（紧急关机）
  zt1=$(cat "$ZCPU" 2>/dev/null)
  zt2=$(cat "$ZCPUSS" 2>/dev/null)
  case "$zt1" in ''|*[!0-9]*) zt1=0 ;; esac
  case "$zt2" in ''|*[!0-9]*) zt2=0 ;; esac
  if [ "$zt1" -ge 96000 ] || [ "$zt2" -ge 96000 ]; then
    if [ "$cd_pinned" = 1 ]; then
      log "CDEV-RELEASE 结温高 z2=$zt1 z22=$zt2，交回系统"
      cd_pinned=0
    fi
    return 0
  fi
  if [ "$1" -ge "${CDEV_GUARD:-520}" ]; then
    if [ "$cd_pinned" = 1 ]; then
      log "CDEV-RELEASE tb=$1 >= guard=${CDEV_GUARD:-520}，交回系统"
      cd_pinned=0
    fi
    return 0
  fi
  for cd in "$CDIR"/cooling_device*; do
    cty=$(cat "$cd/type" 2>/dev/null)
    case "$cty" in cpu-cluster*) ;; *) continue ;; esac
    cs=$(cat "$cd/cur_state" 2>/dev/null)
    [ "$cs" = "0" ] && continue
    echo 0 > "$cd/cur_state" 2>/dev/null
    cn=$(cat "$cd/cur_state" 2>/dev/null)
    if [ "$cn" = "0" ]; then
      if [ "$cd_pinned" != 1 ]; then
        log "CDEV-PIN $cty $cs -> 0 (tb=$1)"
        cd_pinned=1
      fi
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
i=0
while :; do
  i=$((i + 1))
  echo "$(date +%s)" > "$MD/.hb.tmp" 2>/dev/null && mv -f "$MD/.hb.tmp" "$MD/.hb" 2>/dev/null

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

  tb=$(cat "$NTB" 2>/dev/null)
  case "$tb" in ''|*[!0-9]*) tb=0 ;; esac
  st=$(cat "$NST" 2>/dev/null)

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
    [ "$(wc -c < "$TEL" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$TEL" "$TEL.1"

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
            sbdur=$(( $(date +%s) - sb_start ))
            sbcap1=$(cat "$NCAP" 2>/dev/null)
            case "$sbcap1" in ''|*[!0-9]*) sbcap1=$sb_cap0 ;; esac
            sbavg=0
            [ "$sb_n" -gt 0 ] && sbavg=$((sb_sum / sb_n))
            sbsph=0
            [ "$sbdur" -gt 0 ] && sbsph=$(( sb_n * 3600 / sbdur ))
            # 时长短于 30 分钟时，电量只有 1% 一格，算出来的速率是噪声
            sbrate="n/a"
            if [ "$sbdur" -ge 1800 ] && [ "$sb_chg" = 0 ]; then
              sbr=$(( (sb_cap0 - sbcap1) * 360000 / sbdur ))
              sbrate="$((sbr / 100)).$((sbr % 100))%/h"
            fi
            u=$(awk '{print $14+$15+$16+$17}' "/proc/$$/stat" 2>/dev/null)
            case "$u" in ''|*[!0-9]*) u=0 ;; esac
            sbcpu=$((u - sb_cpu0))
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
            echo "[$(date '+%F %T')] standby dur=${sbdur}s cap=${sb_cap0}->${sbcap1} samples=$sb_n sph=${sbsph} avg=${sbavg}mA rate=${sbrate} cpu=${sbcpu}ticks ss=${sbss} lf=${sblf} chg=${sb_chg} ${idle}" >> "$SBF"
            # 唤醒源按「持锁时间增量」排序，次数多不代表耗电（event5 22.9 万次只持有 22 秒）
            wsrc=""
            to awk 'NR>1{print $1, $7}' "$PWS" > "$MD/.ws1" 2>/dev/null
            if [ -f "$MD/.ws0" ] && [ -s "$MD/.ws1" ]; then
              wsrc=$(to awk 'FNR==NR{a[$1]+=$2; next} {b[$1]+=$2} END{for(n in b){d=b[n]-a[n]; if (d>0) printf "%d %s\n", d, n}}' "$MD/.ws0" "$MD/.ws1" 2>/dev/null | sort -nr | head -5 | awk '{printf "%s:%d ", $2, $1}' | cut -c1-260)
            fi
            [ -z "$wsrc" ] && wsrc="n/a"
            echo "WAKE $(date '+%F %T') $idle top=$wsrc ss=${sbss} lf=${sblf}" >> "$SBD"
            log "STANDBY-END dur=${sbdur}s rate=${sbrate} avg=${sbavg}mA cpu=${sbcpu}ticks ${idle}"
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
          fi
          ;;
      esac
    fi
  fi

  sleep "$TICK"
done
