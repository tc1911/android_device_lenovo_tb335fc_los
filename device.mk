PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/recovery.fstab:$(TARGET_COPY_OUT_RECOVERY_ROOT)/system/etc/recovery.fstab
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/init.recovery.mt6835.rc:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/init.recovery.mt6835.rc


# MTK 内核模块



include $(DEVICE_PATH)/modules_copy.mk


# USB configfs + adb 开放
ADDITIONAL_DEFAULT_PROPERTIES += \
    sys.usb.configfs=1 \
    sys.usb.controller=11201000.usb0 \
    ro.secure=0 \
    ro.adb.secure=0 \
    persist.sys.usb.config=adb

# v52c: 变体属性（stock 同值）→ hw_get_module 拼 hwcomposer.mt6835.so
PRODUCT_SYSTEM_PROPERTIES += \
    ro.board.platform=mt6835 \
    ro.hardware=mt8755

PRODUCT_COPY_FILES += $(DEVICE_PATH)/init.recovery.usb_fix.rc:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/init.recovery.usb_fix.rc


PRODUCT_COPY_FILES += $(DEVICE_PATH)/init.recovery.usb.configfs.rc:$(TARGET_COPY_OUT_RECOVERY_ROOT)/init.recovery.usb.configfs.rc
include $(DEVICE_PATH)/fw_copy.mk

# ===== LineageOS system config =====
PRODUCT_PACKAGES += android.hardware.security.keymint-service
PRODUCT_PACKAGES += android.hardware.power-service.example
PRODUCT_PACKAGES += android.hardware.lights-service.example
PRODUCT_PACKAGES += android.hardware.sensors-service.example
PRODUCT_PACKAGES += android.hardware.gnss-service.example

# System fstab (from stock, with avb)
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/fstab.mt6835:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.mt8755

# Kernel modules (vendor_dlkm)
include $(DEVICE_PATH)/modules_copy.mk

# Vendor blobs
include vendor/lenovo/sycamore/vendor-blobs.mk

# pmsg 调试标记（init 第二阶段 rootfs=/system，放 system 根）
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/init.dbg.rc:system/init.mt8755.rc \
    $(DEVICE_PATH)/init.gpu.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.gpu.rc



# v64: 首启减负（dex2oat verify 不 speed，加快首次 boot）
PRODUCT_SYSTEM_PROPERTIES += \
    pm.dexopt.first-boot=verify \
    pm.dexopt.boot=verify \
    pm.dexopt.install=verify

# v75: system 分区根挂载点目录（/system/product 等，供根链接 realpath + first_stage_mount 挂载）
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/keep/product/.keep:$(TARGET_COPY_OUT_SYSTEM)/product/.keep \
    $(DEVICE_PATH)/keep/system_ext/.keep:$(TARGET_COPY_OUT_SYSTEM)/system_ext/.keep

# ===== v91: 预装 Xime 输入法 + 显示/背光守护 + 内核日志常驻 =====
# Xime（曦码，GPL-3.0，Rime 引擎，arm64 单 APK，com.kingzcheung.xime）—— 中文输入法。
#   LOS 自带的 LatinIME 只有英文；预装 = 首次开机就有中文输入，不依赖网络/adb/文件管理器。
# led_daemon.sh + init.tb335.display.rc —— 现场救回来的显示栈补丁（A13 SF × A16 HWC 挂起后
#   开屏卡死 / 背光与面板不同步），顺带把内核日志常驻到 /data/local/tmp/dbg-kernel.log。
#   详见 BOOT_HACKS.md §6 附 2 + AGENTS.md 坑 19。
# APK 不能用 PRODUCT_COPY_FILES（AOSP Makefile:72 报错）→ 走 android_app_import（prebuilt/xime/Android.bp）
# ⚠️ 本仓库不附带 Xime.apk（第三方 APK，32 MB）。要用中文输入法：
#   ① 从 https://github.com/ximeiorg/Xime/releases 下载 arm64 单 APK（GPL-3.0）
#   ② 放到 prebuilt/xime/Xime.apk，并把 prebuilt/xime/Android.bp.disabled 改回 Android.bp
#   ③ 取消下面这行注释
# PRODUCT_PACKAGES += Xime
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/prebuilt/led_daemon.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/led_daemon.sh \
    $(DEVICE_PATH)/init.tb335.display.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/tb335_display.rc

