#!/system/bin/sh
# v91: TB335FC 显示/背光守护 + 内核日志常驻
#
# 现场问题（2026-09-27/28 实测）：A13 SurfaceFlinger × A16 HWC 在**挂起 2 分钟后**
# 开屏序列会卡死 —— 表现是屏黑（或黑屏常亮背光）、framework 假醒（Awake/Display State=ON）、
# 物理电源键/注入按键都无效，只能长按电源 10s。已定性的三件事：
#   1) 熄屏时 A13 的亮度调用会被 A16 HWC 丢掉 → 面板黑了、背光灯还亮着（LED 停在用户亮度）
#   2) 唤醒失败的根因在显示栈（SF mScreenAcquired 一直是 0），**重启 composer 必能拉回**
#   3) 深度挂起是触发条件 → 持住禁挂起锁可以绕开这条路径
#
# 本 daemon 只做三件事（事件驱动，无轮询）：
#   A. 熄屏/开屏事件 → 直接写背光 LED（绕开被丢掉的亮度调用）
#   B. 启动时拿住 tb335_nosleep 禁挂起锁
#   C. 开屏后 3 秒仍没拿回显示 → 自动 setprop ctl.restart vendor.hwcomposer-3-1（连带 SF）
# 顺带把内核日志常驻到 /data/local/tmp/dbg-kernel.log（启动全量 + 之后实时追加）：
# 这条是 WiFi 驱动 insmod / 挂起唤醒 / 充电状态三个悬案唯一的现场证据来源。
#
# 由 init 服务 tb335_display 在 sys.boot_completed=1 时启动（见 init.tb335.display.rc）。

# ===== 2026-09-28: 厂商 blob 硬编码旧布局路径 /system/vendor/... 的兼容层 =====
# 音频 HAL 读 /system/vendor/etc/aurisys_config_rv.xml（不存在 → 空配置 → 空指针 → 3min 崩 30 次）。
# /(system) 是 erofs ro（system-as-root），root 也写不了 → 必须先给 /system 套一层 rw overlay
# （厂商自己也是这么干的）再建 symlink。init 的 symlink 在 post-fs-data 撞 RO
# （实测 "symlink() failed: Read-only file system"）→ 由这里补。
if [ ! -e /system/vendor ]; then
    mkdir -p /data/local/tmp/ovl/upper /data/local/tmp/ovl/work 2>/dev/null
    mount -t overlay ovl -o lowerdir=/system,upperdir=/data/local/tmp/ovl/upper,workdir=/data/local/tmp/ovl/work /system 2>/dev/null
    i=0
    while [ $i -lt 8 ] && [ ! -e /system/vendor ]; do
        ln -sfn /vendor /system/vendor 2>/dev/null
        [ -e /system/vendor ] && break
        i=$((i+1)); sleep 2
    done
    if [ -e /system/vendor ]; then
        log -t tb335_display "led_daemon: /system/vendor -> /vendor OK (overlay)"
    else
        log -t tb335_display "led_daemon: /system/vendor 建立失败，音频 HAL 仍会崩"
    fi
fi

LED=/sys/class/leds/lcd-backlight/brightness
LOCK=tb335_nosleep
LOG=/data/local/tmp/dbg-kernel.log
RESCUE=/data/local/tmp/led_daemon.rescue

# 按 framework 的 mBrightnessState(0..1) 折算 0..255 写进 LED
apply_on() {
    v=$(dumpsys display 2>/dev/null | sed -n 's/.*mBrightnessState=\(-\?[0-9.]*\).*/\1/p' | head -1)
    case "$v" in ''|-1.0|-1) v=0.4 ;; esac
    n=$(awk -v x="$v" 'BEGIN{printf "%d", (x<0?0:(x>1?255:x*255))}' 2>/dev/null)
    [ -z "$n" ] && n=102
    echo "$n" > $LED
}

# --- 内核日志常驻 ---
sz=$(stat -c%s $LOG 2>/dev/null || echo 0)
[ "$sz" -gt 4194304 ] && mv -f $LOG ${LOG}.old          # 4MB 轮转一份
dmesg > $LOG 2>/dev/null                                  # 开机至今的全量（含 WiFi 驱动 insmod）
echo "----- live /dev/kmsg from uptime $(cut -d. -f1 /proc/uptime)s -----" >> $LOG

echo $LOCK > /sys/power/wake_lock                         # B. 禁挂起
case "$(dumpsys display 2>/dev/null | grep -m1 'Display State=')" in
    *ON*) apply_on ;;
    *)    echo 0 > $LED ;;
esac

while true; do
    cat /dev/kmsg 2>/dev/null | while read -r line; do
        echo "$line" >> $LOG
        case "$line" in
            *"lcm_panel_init start"*)                     # 面板正在 resume
                apply_on
                ( sleep 3                                 # C. 自愈看门狗（20s 限流）
                  if ! dumpsys SurfaceFlinger 2>/dev/null | grep -q 'mScreenAcquired=1'; then
                      now=$(cut -d. -f1 /proc/uptime)
                      last=$(cat $RESCUE 2>/dev/null || echo 0)
                      if [ $((now - last)) -gt 20 ]; then
                          echo $now > $RESCUE
                          setprop ctl.restart vendor.hwcomposer-3-1
                      fi
                  fi ) &
                ;;
            *"panel_notifier_callback:848] suspend"*)      # 面板挂起
                echo 0 > $LED ;;
        esac
    done
    sleep 5                                               # /dev/kmsg 断了就重开
done
