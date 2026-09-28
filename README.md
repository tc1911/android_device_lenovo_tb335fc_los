# Lenovo TB335FC (sycamore · MT6835) — LineageOS 20 device tree

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**中文** | [English](#english)

联想 TB335FC（联发科 MT6835，代号 `sycamore`）的 **LineageOS 20（Android 13）设备树 +
启动补丁集**。本仓库记录了把 **LineageOS 20（A13 system）× 原厂 ZUXOS 1.5.10.233 的
vendor/odm（A13 厂商层）× 原厂 GKI 5.15.185 内核** 拼成一台**真能开机、能日常用**的平板的
全过程 —— 包含所有踩过的坑与修法（见 [`docs/BOOT_HACKS.md`](docs/BOOT_HACKS.md)）。

> 为什么值得看：这台机器的厂商层是从一份「system 是 A16、vendor 却是 A13」的原厂 ROM 里
> 抠出来的；MTK 的 blob 硬编码了 `/system/vendor/...` 这种 A10 之前的旧分区布局，A13 的
> init 又不解析厂商 `hw/` 子目录里的 rc……这类坑在别处很难查，仓库里都写了判据与修法。

## 当前状态（A13 阶段，已冻结）

| | 项目 |
|---|---|
| ✅ | **首次开机成功**（`sys.boot_completed=1`） |
| ✅ | WiFi（三个缺口全部修好：`modules.load` 补 `wlan_drv_gen4m_6835.ko`、编出缺失的 `android.hardware.wifi.supplicant-V1-ndk.so`、自己 `mkdir /data/vendor/wifi/wpa`） |
| ✅ | 显示 / 背光（`tb335_display` init 服务：灭屏背光归零、持禁挂起锁、唤醒失败 3 秒自愈） |
| ✅ | 无线调试（`adb connect`） |
| ⚠️ | 音频 HAL 每几分钟 SIGSEGV —— 根因已定案（厂商 blob 找 `/system/vendor/etc/aurisys_config.xml` 失败 → 空指针），修法已验证（给 `/system` 套 rw overlay 后建 `symlink /vendor /system/vendor`，见 `docs/BOOT_HACKS.md` §2.14/§6） |
| ❌ | USB `adb`（A16 原厂的 USB gadget 与 A13 framework 的 `UsbHandlerLegacy` 不匹配）、已加密 `/data` 的 recovery 解密 |

A13 阶段的开发**已冻结**（用户决定），后续在 **Android 16 / LineageOS 23** 上重做。

## 仓库内容

| 路径 | 说明 |
|---|---|
| （根目录） | 设备树本体 —— clone 到 `device/lenovo/sycamore` 即可用（含 `lineage_sycamore` 与 `twrp_sycamore` 两个产品定义） |
| `patches/framework-hacks.diff` | **必需的 AOSP 侧补丁**：10 个文件，跨 `frameworks/base`(7) + `frameworks/native`(1) + `lineage-sdk`(2)，按 repo 用 `git apply --include=...` 分开打（步骤见 [`patches/README.md`](patches/README.md)） |
| `patches/initboot-dbg.diff` | 调试用 `init_boot`：开机 N 秒后写 BCB 自动重启进 fastboot（无人值守刷测用）；配套脚本见该文件头部注释 |
| `docs/BOOT_HACKS.md` | **全部非常规改动登记册**：文件位置 / 内容 / 动机 / 影响面 / 还原方法（MTK 坑、厂商 rc import 链、旧布局路径、PackageWatchdog 回滚陷阱……） |
| `docs/BUILD.md` | 构建参考手册（环境、命令、刷机、日志读取） |
| `modules_dlkm/*.ko` | 原厂 vendor_dlkm 内核模块（⚠️ 专有二进制，见 [NOTICE](NOTICE)） |
| `recovery/root/` | TWRP 版 recovery ramdisk（`twrp_sycamore` 产品用） |
| `prebuilt/Image` `prebuilt/dtbo.img` `prebuilt/dtb*` | GKI 5.15.185 内核镜像 / dtbo / dtb |
| `prebuilt/led_daemon.sh` | 显示与背光守护 + `/system/vendor` 兼容 symlink（编入 `/system/bin/`） |
| `proprietary-files.txt` `extract-files.sh` `setup-makefiles.sh` | 标准 LOS 抽取流程：**vendor/odm blobs 请从你自己的原厂 ROM 抽取，本仓库不附带** |

## 快速开始

```bash
# 1) 放进 lineage-20.0 源码树
git clone https://github.com/tc1911/android_device_lenovo_tb335fc_los \
    device/lenovo/sycamore

# 2) 抽取 vendor/odm blobs（需要原厂 ROM 或设备本身；仓库不含这些专有文件）
./device/lenovo/sycamore/extract-files.sh          # 或 setup-makefiles.sh

# 3) 打 AOSP 侧补丁（必需；不打起不来 —— 详见 patches/README.md）
cd $TOP/frameworks/base    && git apply --include='services/usb/*' \
    --include='services/core/*' --include='core/java/*' device/lenovo/sycamore/patches/framework-hacks.diff
# 其余 repo 同理（frameworks/native、lineage-sdk）

# 4) 编译
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
lunch lineage_sycamore-userdebug
mka bacon -j8
```

**中文输入法**：LineageOS 自带的 LatinIME 只有英文。若需要中文，自行下载
[Xime（曦码，GPL-3.0，单 arm64 APK）](https://github.com/ximeiorg/Xime/releases) 放到
`prebuilt/xime/Xime.apk`，把 `prebuilt/xime/Android.bp.disabled` 改回 `Android.bp`，
并在 `device.mk` 里取消 `PRODUCT_PACKAGES += Xime` 的注释（本仓库不附带该 APK）。

## 刷机与验证

见 [`docs/BUILD.md`](docs/BUILD.md)（分区布局、`fastboot` 组合、DBG `init_boot` 自动回
fastboot、从 `/metadata` 读内核日志等）。要点：**没有独立 recovery 分区**（recovery 在
`vendor_boot`）；**正常系统与 recovery 必须用各自的 `vendor_boot`**（LK 正常启动也读
`vendor_boot` 的 ramdisk）。

## 许可与致谢

- 设备树、脚本、补丁、文档：**Apache-2.0**（见 [LICENSE](LICENSE)）
- 厂商二进制（`modules_dlkm/*.ko`、`prebuilt/Image`、`prebuilt/dtbo.img`、`prebuilt/dtb*`、
  `recovery/root/lib/modules/*.ko`）：版权归 Lenovo / MediaTek / Google，**不适用**本仓库的
  Apache-2.0 许可，见 [NOTICE](NOTICE)
- 建立在 [LineageOS](https://lineageos.org/) / AOSP 的成果之上；TWRP、OrangeFox 的设备树见本项目另外两个仓库
  （[twrp](https://github.com/tc1911/android_device_lenovo_tb335fc_twrp) / [fox](https://github.com/tc1911/android_device_lenovo_tb335fc_fox)）

---

## English

LineageOS 20 (Android 13) **device tree + bring-up patches** for the Lenovo TB335FC
(MediaTek MT6835, codename `sycamore`).

It documents how a working A13 system was built on top of the stock ZUXOS 1.5.10.233
firmware's **vendor/odm (which itself is Android 13)** and the stock GKI 5.15.185 kernel —
including every non-trivial hack, its rationale and revert recipe
([`docs/BOOT_HACKS.md`](docs/BOOT_HACKS.md)).

**Works:** first boot (`sys.boot_completed=1`), WiFi, display/backlight (with a `tb335_display`
init service), wireless ADB.
**Broken on purpose / not fixed:** audio HAL crashes (root cause known: vendor blobs hardcode
the pre-A10 path `/system/vendor/...`; fix verified — rw overlay + `symlink /vendor /system/vendor`),
USB ADB, encrypted-`/data` recovery decryption.

`git clone` into `device/lenovo/sycamore`; extract vendor blobs with `extract-files.sh` from
*your own* stock ROM (none are bundled); apply `patches/framework-hacks.diff` per repo
(see [`patches/README.md`](patches/README.md)); then
`lunch lineage_sycamore-userdebug && mka bacon -j8`.

Device tree / patches / docs: **Apache-2.0**. Proprietary blobs and kernel images keep their
own licenses — see [NOTICE](NOTICE).
