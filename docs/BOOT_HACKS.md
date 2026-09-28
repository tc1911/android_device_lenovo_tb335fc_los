# BOOT_HACKS.md — 为了启动所做的全部改动清单

> 目标：TB335FC 跑 LineageOS 20（A13 system × **A13 厂商层** —— vendor/odm 取自原厂 A16 ROM，但其 vendor 本身就是 Android 13）。
> 本文记录**为了开机/启动**的所有非常规改动：文件位置、内容、动机、影响面、还原方法。
> 所有改动在源码/产物中以 `vNN:` 注释标记，可用 `grep -rn "vNN:"` 定位。
> 最后更新：2026-09-28
> **§6 = 当前状态与下一步的唯一权威维护处**（工作区笔记只指向本文，避免两处各写一份）；历史排错过程见 《开发日志》（未随仓库发布）。
> **完整 framework diff 存档**：`patches/framework-hacks.diff`（截至 v88：frameworks/base 7 文件 + frameworks/native 1 文件 + lineage-sdk 2 文件）

---

## 0. 改动总览

| 类别 | 数量 | 风险 | 是否可还原 |
|---|---|---|---|
| framework 代码 hack | 6（2 冗余可删） | 低-中 | 可（git checkout） |
| framework 诊断日志 | 2（BOOTPHASE/FB 标记） | 极低 | 可（git checkout） |
| vendor blobs 配置 | 6+ | 低 | 可（改回 blobs.mk） |
| 设备树 device.mk | 4 | 低 | 可 |
| init（DBG） | 1 | 仅测试用 | 可（git checkout） |
| 内核模块加载 | 1 | 中（影响面全） | 可 |
| SELinux/permissive | 1 | 高（但仅测试） | 可 |

---

## 1. Framework 代码 hack

### 1.1 LineageSettings provider 未就绪返回 null（v67）★核心
- **文件**：`lineage-sdk/sdk/src/java/lineageos/providers/LineageSettings.java`
- **改动**：`NameValueCache.getStringForUser()` 中 `mProviderHolder.getProvider(cr)` 返回 null 时直接 `return null`（原代码 `cp.call()` NPE）
- **动机**：system_server 早期（WMS/DisplayPolicy/InputManager 构造，user 0 未解锁）读 LineageSettings → provider 不可用 → NPE 崩循环
- **影响面**：仅 user 未解锁期间设置读取返回 null（getIntForUser 等自动回退默认值）；解锁后无影响
- **覆盖的早期调用点**：DisplayPolicy(FORCE_SHOW_NAVBAR)、DeviceKeysConstants(PhoneWindowManager)、InputManagerService(volume keys) 等全部
- **还原**：git checkout 该文件
- **状态**：保留（根源修复）

### 1.2 libbinder 允许线程池 shrink（v71）★核心
- **文件**：`frameworks/native/libs/binder/ProcessState.cpp`
- **改动**：`setThreadPoolMaxThreadCount()` 的 `LOG_ALWAYS_FATAL_IF(mThreadPoolStarted && maxThreads < mMaxThreads)` → 放宽为 `ALOGW` 警告后照常执行 ioctl
- **动机**：A16 MTK audio HAL main() 调 `ABinderProcess_setThreadPoolMaxThreadCount`（15→1）→ A13 libbinder 断言 abort → SIGABRT 崩循环
- **影响面**：全系统共享库；行为变化仅"启动后 shrink 线程池"场景（不再 abort，多余线程不回收无害）
- **还原**：git checkout 该文件
- **状态**：保留（audio 依赖）

### 1.3 DisplayPolicy.updateSettings try-catch（v65）— 冗余
- **文件**：`frameworks/base/services/core/java/com/android/server/wm/DisplayPolicy.java`
- **改动**：读 FORCE_SHOW_NAVBAR 包 try-catch（异常时 mForceNavbar=0）
- **说明**：已被 1.1（v67）覆盖，不会再触发 → **可还原**
- **还原**：git checkout 该文件

### 1.4 DeviceKeysConstants.fromSettings try-catch（v66）— 冗余
- **文件**：`lineage-sdk/sdk/src/java/org/lineageos/internal/util/DeviceKeysConstants.java`
- **改动**：fromSettings 包 try-catch（异常返回 def）
- **说明**：已被 1.1（v67）覆盖 → **可还原**
- **还原**：git checkout 该文件

### 1.5 DefaultHalFactory soundtrigger 快速失败（v74）
- **文件**：`frameworks/base/services/core/java/com/android/server/soundtrigger_middleware/DefaultHalFactory.java`
- **改动**：`ISoundTriggerHw.getService(true)`（无限等）→ `getService(false)`（快速失败）；SoundTriggerMiddlewareImpl 捕获异常优雅降级（模块列表为空）
- **动机**：无 soundtrigger HAL（MTK 的 soundtrigger 由 A16 audio-hal 注册，未实现）→ 原代码死等卡 system_server
- **影响面**：soundtrigger 功能不可用（语音唤醒等）；不阻塞 boot
- **还原**：git checkout 该文件

### 1.6 UsbDeviceManager 构造 getService(true)→(false) ×2（v82/v84）★usb 三层坑之一
- **文件**：`frameworks/base/services/usb/java/com/android/server/usb/UsbDeviceManager.java`
- **改动**：
  - line 309（v82，UsbDeviceManager 构造）：`IUsbGadget.getService(true)` → `getService(false)`
  - line 2009（v84，UsbHandlerHal 构造）：同上（**同一构造链的第二处**，v82 只修了第一处）
- **动机**：MTK usb-gadget HIDL HAL（A16 二进制）在 A13 系统里不启动 → `getService(true)`（无限重试）永久卡 → system_server 卡在 UsbService 构造 → 无法进 phase 1000 之后
- **影响面**：usb 功能不可用（adb/mtp 等）；不阻塞 boot
- **还原**：git checkout 该文件

### 1.7 UsbService onBootPhase(1000) join → 10s 超时（v85）★usb 三层坑之三
- **文件**：`frameworks/base/services/usb/java/com/android/server/usb/UsbService.java`
- **改动**：`mOnActivityManagerPhaseFinished.join()`（无限等 550 阶段异步任务完成）→ `get(10, TimeUnit.SECONDS)` + catch 后继续 `bootCompleted()`
- **动机**：550 阶段任务（`systemReady() → complete()`）因 usb HAL 缺失永不 complete → 1000 的 join 死等
- **v86（2026-09-23 已改源码，待编译）**：`get(10, ...)` → `get(0, ...)`（不等待、只探测；保留 Slog.w 作为“550 任务是否完成”的信号）+ 550 任务里加 `v86: USB550 systemReady enter/exit` 诊断。补丁存档 `patches/v86-usbservice.diff`
- **还原**：git checkout 该文件

### 1.8 SystemServiceManager BOOTPHASE 日志（v81，诊断）
- **文件**：`frameworks/base/services/core/java/com/android/server/SystemServiceManager.java`
- **改动**：`startBootPhase()` 每个服务调用前 `Slog.i(TAG, "BOOTPHASE " + phase + ": " + service.getClass().getName())`
- **用途**：精确定位卡在哪个 phase 的哪个服务（本 session 靠它定位 UsbService）
- **还原**：git checkout 该文件（诊断用，可长期保留）

### 1.9 ActivityManagerService finishBooting FB 标记（v83，诊断）
- **文件**：`frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java`
- **改动**：finishBooting 入口/等 bootanim 前/PHASE_BOOT_COMPLETED 前后打 `FB: xxx` 日志（5 行）
- **用途**：定位 finishBooting 卡点（配合 BOOTPHASE）
- **还原**：git checkout 该文件（诊断用，可长期保留）

---

## 2. Vendor blobs 相关

### 2.1 恢复 audio HAL rc + 自启 + interface（v68）
- **文件**：`vendor/lenovo/sycamore/proprietary/etc/init/android.hardware.audio.service.mediatek.rc` + `vendor-blobs.mk` v68 段
- **改动**：rc 去 `disabled`（class hal 自启）+ 加 `interface android.hardware.audio@7.1::IDevicesFactory default`
- **背景**：v62 曾删全部 MTK A16 rc（audio/usb/gnss/omx/sensors/pq）→ audio 缺失致 audioserver 死等 → v68 恢复 audio（sensors 用 AOSP 替代、gnss/omx/pq 仍删）

### 2.2 补 soundtrigger@2.0 库（v70）
- **文件**：`vendor/lenovo/sycamore/proprietary/lib64/android.hardware.soundtrigger@2.0.so`（AOSP 编译产物）+ `vendor-blobs.mk` v70 段
- **改动**：`mka android.hardware.soundtrigger@2.0` 产物 COPY 到 vendor/lib64
- **动机**：audio HAL linker 报 CANNOT LINK（源提取漏 2.0，只有 2.1-2.3）

### 2.3 logkmsg 服务（v61/v62）+ kernel buffer（v69）
- **文件**：`vendor/lenovo/sycamore/proprietary/etc/init/logkmsg.rc`（blobs.mk v62 段）
- **内容**：`logcat -b main,system,crash,kernel -v threadtime -f /metadata/logkmsg.log -r 2048 -n 2 *:I`
- **用途**：boot 日志通道（USB 死路/data 加密后唯一手段）
- **注意**：2MB×2 轮转会丢 boot 早期日志；kernel buffer 噪音大（充电器 dump 刷屏）

### 2.4 禁用的 A16 服务 rc（v62 删除，不再打包）
- 从 out/TF VENDOR/etc/init 删除（源码仍在 proprietary）：
  - `android.hardware.gnss-service.mediatek.rc`（gnss HAL 崩循环）
  - `android.hardware.media.omx@1.0-service.rc`（omx 崩循环）
  - `android.hardware.secure_element@1.2-service-mediatek.rc`
  - `android.hardware.sensors-service-multihal.rc`（sensors 用 AOSP 替代，见 2.5）
  - `mtkgnss-batching.rc`
  - `vendor.mediatek.hardware.pq_aidl-service.rc`
  - `vendor.lenovo.hardware.usb.rc`（usb hal 崩；usbd class late_start 死锁）
- **恢复方法**：文件拷回 TF VENDOR/etc/init（源码在 proprietary 原位置）— 注意 init 只解析 /vendor/etc/init/*.rc 顶层，hw/ 子目录需平铺（见 2.6）

### 2.5 AOSP sensors 空实现（v63）
- **文件**：device.mk `PRODUCT_PACKAGES += android.hardware.sensors-service.example`
- **来源**：`hardware/interfaces/sensors/aidl/default/`（AOSP 空 sensors impl，rc=sensors-default.rc）
- **动机**：MTK A16 multihal 崩循环 + SensorService 直接等 binder（不看 vintf manifest）→ 需活 ISensors

### 2.6 wmt_launcher rc 放顶层（v73）
- **文件**：`vendor-blobs.mk` v73 段：`proprietary/etc/init/hw/init_connectivity.rc → vendor/etc/init/init_connectivity.rc`（顶层平铺）
- **动机**：init 只解析 /vendor/etc/init/*.rc 顶层（不递归 hw/）；wmt_launcher（class early_hal）不跑 → connsys 不就绪 → audio HAL 卡 BT 查询
- **注意**：TF 顶层曾有同名空文件（历史残留），blobs COPY 覆盖

### 2.7 内核模块 wmt 链加载（v72）
- **文件**：`device/lenovo/sycamore/modules_dlkm/modules.load`（追加）
- **改动**：末尾追加 `wmt_drv.ko / wmt_chrdev_wifi.ko / bt_drv_connac1x.ko`
- **动机**：/dev/stpbt（audio HAL BT 查询）由 wmt 驱动提供；原 modules.load 缺 wmt 链
- **影响**：加载 MTK wifi/bt 内核驱动（wmt_chrdev_wifi 已在跑；固件主体缺失状态待观察）

### 2.8 logkmsg 滤波更新（v78/v83）★日志通道
- **文件**：`vendor/lenovo/sycamore/proprietary/etc/init/logkmsg.rc`（blobs.mk v62 段）
- **当前内容**：`logcat -b main,system,crash -v threadtime -f /metadata/logkmsg.log -r 2048 -n 2 *:I BootAnimation:S ged-swd:S composer@3.1-se:S hwcomposer:S WifiThreadRunner:S`
- **v78 改动**：去掉 kernel buffer（avc denied 洪流刷屏），滤 BootAnimation/ged-swd/composer 噪音
- **v83 改动**：加滤 hwcomposer（STYLUS_MODE 每 2ms 洪水）/WifiThreadRunner
- **注意**：2MB×2 轮转，多轮重启会覆盖早期日志；读时 .log/.log.1/.log.2 都要拉
- **⚠️ 2026-09-24 v86 刷测踩坑：拉不到日志 ≠ 脚本卡死**
  - 真凶：`adb wait-for-device` 在 recovery 下**永久阻塞**（recovery 的 transport 状态是 `recovery` 而非 `device`）——脚本第一行就卡死且无任何输出，看起来像“拉取慢/卡死”。**禁止用 `adb wait-for-device`，改用带 timeout 的 `adb shell true` 探活**
  - 现状：`/metadata` 62M 用了 51M（**只余 11M**）；`logkmsg.log` **0 字节**、`.1` 是 **9月3日** 旧内容、`.2` 已是**二进制垃圾** → 本轮启动 logcat 完全没写进去
  - 平板时钟停在 **9月18日 21:51**（RTC 没被系统校准）→ **所有 mtime 不可信，只能看内容里的时间戳**
  - `pstore` 也不是万灵药：本次 `console-ramoops`/`pmsg-ramoops` 内容是 **Fox recovery 自己**的（`recoverycharge_status`/`GetBatteryInfo`），不是 LOS 启动
  - 待查：为何 logcat 不写、`/metadata` 51M 被谁占、v74-v85 那些 logkmsg 分析当时是怎么拿到的
- **2026-09-24 01:56 深入查证（.1 到底是什么时候的日志）**
  - `.1` 全文**只包含 `09-03`**（22:25:52 → 22:26:17，**25 秒就写满 2MB**：847 条 BOOTPHASE、finishBooting×4、systemReady×6、FATAL×1、watchdog×1）→ 这是 **9/3 时代的某轮启动**，不是近期的
  - `.1`/`.2` 的 mtime = 9/18 21:44，内容时间戳却是 09-03 → 再次坐实**设备时钟会跳变，mtime 完全不可信**
  - **`.1` 的文件尾是截断的二进制垃圾**（半行/乱码）→ “写入未落盘就断电”的典型特征，非正常关闭
  - `.log` = 0 字节但 mtime = **当前设备时钟（21:51）** → 今晚 logcat **确实 create/truncate 了它**，却一个字节没落盘
  - 两个嫌疑（待雨决定性实验区分）：
    - ① **DBG 的 `syscall(reboot, ...)` 是硬复位，不走 Android `Reboot()` 的 sync 路径** → page cache 里的日志全丢
    - ② logcat 起来后立即死亡（exec 失败 / SELinux 拒绝 / logd 未就结），根本没写
  - **重要推论**：当前 `/metadata` 里没有近期日志 → **v74-v85 那几轮分析用的日志不可能是从现在的 /metadata 拉的**，应该是**当时 adbd 存活时实时拉取**的 → “拉日志”的前提是先让 **adbd 起来**
  - 明天的决定性实验：Fox 里 `rm -f /metadata/logkmsg.log*` → 刷 **dbg600** → **活着的时候**（adb 一出现就）`scripts/pull_logs.sh`（不经重启就不可能丢数据）；若 600s 内 adb 始终不出现且重启后 `.log` 仍 0 字节 → 确诊是 ②（1 行 `ro.debuggable` 级别的小事），不是丢数据

### 2.9 secure_element rc 崩循环回归（未解决）
- **现象**：`mtk_secure_element_hal_service` signal 9 崩循环（v62 删除的 rc 又出现）
- **怀疑**：blobs.mk 还有 COPY 段把 rc 拷回 /vendor/etc/init/ → **待排查**
- **影响**：崩循环刷日志（不阻塞 boot 到当前阶段）

### 2.10 AOSP gnss example（v77）
- **文件**：`device.mk` `PRODUCT_PACKAGES += android.hardware.gnss-service.example`
- **动机**：MTK gnss HAL rc 被删（崩循环）→ gnss service 缺失 → system_server 早期等 gnss → 用 AOSP 空实现顶上
- **效果**：boot 流程完整走完（出现 "internal problem" 警告 + FallbackHome 黑屏）

### 2.11 product/system_ext first_stage_mount + 根挂载点（v75/v76）★关键
- **文件**：`device/lenovo/sycamore/fstab.mt6835` + `vendor/lenovo/sycamore/proprietary/etc/fstab.mt8755`（两份同步改）
- **改动**：
  - product/system_ext 行 target 改 canonical：`/product` → `/system/product`、`/system_ext` → `/system/system_ext`
  - product/system_ext 行 flags 加 `first_stage_mount`
- **配套**：`device.mk` v75 段 COPY `.keep` 建 `/system/product`、`/system/system_ext` 目录
- **动机**：first_stage init 挂载点必须是 canonical target（挂 /product 会失败）→ 之前 product/system_ext 挂不上 → PackageManager 起不来
- **效果**：**见到 LineageOS 开机动画**（首个大里程碑）
- **注意**：两份 fstab 必须同步改；vb 里的 fstab 来自 device.mk:41（`fstab.mt6835 → first_stage_ramdisk/fstab.mt8755`），改完 `mka vendorbootimage`

### 2.12 vb fstab 打包来源（device.mk:41）
- `device/lenovo/sycamore/fstab.mt6835` → COPY 到 vb ramdisk 的 `first_stage_ramdisk/fstab.mt8755`
- 改 fstab 后必须 `mka vendorbootimage` 重编 vb（不能只编 super）

### 2.13 WiFi 三个缺口修复（v89/v90）★WiFi 打通
- **文件**：① `device/lenovo/sycamore/modules_dlkm/modules.load`（加一行 `wlan_drv_gen4m_6835.ko`）
  ② `vendor/lenovo/sycamore/vendor-blobs.mk`（把 `android.hardware.wifi.supplicant-V1-ndk.so` 装到 `/vendor/lib64/`）
  ③ `vendor/lenovo/sycamore/proprietary/etc/init/hw/init_connectivity.rc`（`mkdir /data/vendor/wifi/wpa{,/sockets}`）
- **动机/证据**：见 §6「2026-09-27」小节（驱动从没被加载 / supplicant 缺 AIDL V1 ndk 库 / wpa 状态目录没建）
- **影响**：WiFi 可用；vendor 多一个 ~500KB 的 .so
- **补丁存档**：`patches/los-device-hacks.diff` —— 3 处文本改动的 hunk（机械生成：把当前文件按已知改动还原成 original 再 `diff -u`；正/反向 `patch -p1 --dry-run` 均已通过）。二进制 `.so` **不在**补丁里
- **还原**：反向应用上面那个补丁即可 = `modules.load` 删 `wlan_drv_gen4m_6835.ko` 那 1 行、`vendor-blobs.mk` 删 v89 那 3 行（注释 + `PRODUCT_COPY_FILES += \` + 文件行）、`init_connectivity.rc` 删 v90 那 6 行（3 行注释 + 3 行 `mkdir`）

---

### 2.14 音频 HAL 空指针崩溃：RT5512 smartpa 死配置（v92）★稳定性

- **文件**：`vendor/lenovo/sycamore/proprietary/etc/aurisys_config_rv.xml`
- **改动**：删掉 `<aurisys_scenario aurisys_scenario="AURISYS_SCENARIO_DSP_PLAYBACK_SMARTPA">`（原第 9–14 行）及其库声明 `<library name="smartpa_rt5512" …>`（原第 134–168 行），换一条说明注释；8228 → 6420 字节
- **动机**：该场景注释写着 "for all mixed streamout"（= **普通播放路径**），而它声明的 `libaudiosmartpartk.so`（`/vendor/lib` 与 `/vendor/lib64`）和 `SmartPaVendor1_AudioParam.dat` **在本机全部不存在**（`/vendor` 全盘搜索为空；原厂 A16 也没有 → 参考设计遗留的死配置）→ A13 的 `new_aurisys_lib_manager` `dlopen` 失败后解引用空指针 → **SIGSEGV，3 分钟崩 30 次**
  ⚠️ **更正（2026-09-28 02:30）**：删完仍然以**同一栈**崩（`tombstone_22`，`Process uptime: 0s`）→ 这确实是死配置，但**不是崩溃主因**。主因是 `/system/vendor/etc/aurisys_config.xml` 这个旧布局路径不存在（详见 §6 稳定性排查第 1 条）。这条清理保留（无害且合理），但真正要修的是那个 symlink。
- **影响**：音频 HAL 不再崩；普通播放走 passthrough（本机没 RT5512 功放，本来就无需这个场景）
- **还原**：把 `blobs_vendor/etc/aurisys_config_rv.xml`（原厂原文件，md5 `f50af70d486c02860bfc1402ea16b226`）拷回该路径

## 3. 设备树/编译配置

### 3.1 TARGET_BOARD_PLATFORM := mt6835（v52d）★显示链关键
- **文件**：`device/lenovo/sycamore/BoardConfig.mk`
- **效果**：ro.board.platform 生效 → hw_get_module 找到 hwcomposer.mt6835.so → SF/composer 工作

### 3.2 首启 dex2oat 减负（v64）
- **文件**：device.mk `PRODUCT_SYSTEM_PROPERTIES += pm.dexopt.first-boot=verify pm.dexopt.boot=verify pm.dexopt.install=verify`
- **说明**：实测非关键（不是慢的问题），保留无害

### 3.3 SELinux permissive
- **文件**：BoardConfig.mk / cmdline `androidboot.selinux=permissive`
- **说明**：测试期必需；audit 日志显示大量 denied（permissive=1 不执行）

---

## 4. init DBG（仅测试用）

### 4.1 first_stage DBG 重启（自动重启 + 限定日志窗口）

**✅ 2026-09-24 验证：4 个 DBG 镜像的等待秒数都对（不用刷机）** —— 拆开镜像读 `init` 里那个 `MOVZ w0, #N` 即可：**init 内偏移 974912** 处就是 sleep 秒数（已核对 dbg45=45／dbg120=120／dbg300=300／dbg600=600；4 个镜像彼此只差 build-id + 这 1 字节）。
**✅ 2026-09-24 02:57 实机验证（v4）：45s 到点自动回到 fastboot** —— 之前「到点卡 logo」的根因是补丁只发裸 reboot syscall、**没写 BCB**（见下）；v4 补上 `write_reboot_bootloader()`。`tmp/logs/watch_dbg45.log`：02:56:21 离线 → **02:57:38 `[fastboot] <序列号>`**（用户同步确认「进fb了」）。
```bash
unpack_bootimg --boot_img=archive/initboot_dbg600.img --out=/tmp/x && cd /tmp/x \
  && mkdir rd && lz4 -d ramdisk rd/r.cpio && (cd rd && cpio -idm --quiet < r.cpio)
# 读 rd/init 偏移 974912 起 4 字节：00 4b 80 52 = MOVZ w0,#600
```
- **文件**：`system/core/init/first_stage_init.cpp`（`~/los20`）
- **内容（v4）**：FirstStageMain 在 `execv("/system/bin/init")` 前插入
  `if (fork() == 0) { sleep(N); sync(); if (!write_reboot_bootloader(&err)) LOG(WARNING) << err; syscall(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, "bootloader"); _exit(0); }`
  - `sync()`：裸 syscall 是**不干净关机**，不落盘（曾把 `/metadata/logkmsg.log.2` 写成二进制垃圾）
  - `write_reboot_bootloader(&err)` = 往 misc 写 `bootonce-bootloader`（`bootable/recovery/bootloader_message/bootloader_message.cpp:230`，内部用 `ReadDefaultFstab` 找 `/misc`；misc 里已有未执行命令时返回 false，只 `LOG(WARNING)`）——**MTK LK 只认这个 BCB 才进 fastboot**；AOSP 自己也只有第二阶段 init `reboot.cpp:1033` 写它
  - 收尾仍用 raw syscall：`RebootSystem()` 内部查 `IsRebootCapable()`，first_stage 子进程没权限
- **补丁（v4，3 文件 / 2 个 git 项目）**：`patches/initboot-dbg.diff` —— `system/core/init/first_stage_init.cpp`（DBG 主体）+ `system/core/init/Android.bp`（增链 `libbootloader_message`）+ `bootable/recovery/bootloader_message/Android.bp`（加 `ramdisk_available: true`，否则 Soong 报 `missing dependencies: libbootloader_message{...image:ramdisk...}`）。**原补丁源码 2026-09-23 确认丢失**（`~/.bash_history` 无记录、`first_stage_init.cpp.bak` 是干净版、无 git stash）→ 此文件是按本节描述**重建**的。重建正确性已验证：两个变体的 `init` 只差 16 字节 build-id + **2 字节 sleep 常量**（45=0x2D / 300=0x12C，与源码 movz 立即数完全对应）；且今天重编的 `initboot_clean.img` 的 `init` 与 9/9 归档版**逐字节相同**（证明源码/工具链未变）
- **构建（推荐）**：`scripts/build_initboot.sh <秒数>` —— [0/5] 清服务器残留构建进程 → 打补丁（两个 repo）→ `mka initbootimage -j8` → **三关校验**（产物含 `DBG-BOOT` 串 + 偏移 974912 的 MOVZ 常量 = `0x52800000+(N<<5)` + `init_boot.img` 时间戳新鲜）→ 拉回 `archive/initboot_dbg<N>.img` → 刷新 `MD5SUMS` → **自动还原源码**；校验不过直接报错退出（专治「9 秒假成功」）
- **版本（`archive/`）**：

  | 文件 | 窗口 | 状态（全部 v4，2026-09-24 重编） |
  |---|---|---|
  | `initboot_dbg45.img` | 45s（最快迭代） | ✅ 已实测：到点自动回 fastboot |
  | `initboot_dbg120.img` | 120s（默认刷测） | ✅ 同补丁，常量已核 |
  | `initboot_dbg300.img` | 300s（长窗口） | ✅ 同补丁，常量已核 |
  | `initboot_dbg600.img` | 600s（最长窗口） | ✅ 同补丁，常量已核 |
  | `initboot_clean.img` | 无 DBG | 2026-09-23 重编（用于 Fox 基线） |

- **还原干净版**：`cd ~/los20/system/core && git checkout -- init/first_stage_init.cpp init/Android.bp` + `cd ~/los20/bootable/recovery && git checkout -- bootloader_message/Android.bp`
- **不靠脚本编译**：`cd ~/los20 && mka initbootimage -j8`（增量 ~10-130s；目标名**不是** `init_bootimage`）
- **注意**：
  - 源码带此补丁时 `mka bacon` 会把 DBG 编进**所有** init_boot 产物 → 编完 DBG 必须还原（脚本已自动做）
  - DBG 在 recovery（Fox）**也生效** → 刷了 DBG 版再进 Fox 拉日志，N 秒后会被自动重启（要趁早拉，或换 `initboot_clean.img`）
  - ⚠️ **`init_boot.img` 的 ramdisk 只装 `init_first_stage` 模块**（`ramdisk/init` ← `init_first_stage`）；`init.cpp` 属 `init_second_stage`（装到 system/bin/init）。DBG 打在 `init.cpp` 上**静默无效**：`mka initbootimage` 9 秒“成功”、ninja `no work to do`、`init_boot.img` 一字节没变（2026-09-24 实测，白折腾半小时）—— 所以才要有上面的三关校验
  - `mka ... | tail -3` 会把失败吞掉 → 一律 `mka ... > log 2>&1; echo exit=$?`
  - `RESTART2 "bootloader"` 的 MTK LK 不完全认 → **根因已查明 = 没写 BCB**，v4 已修并实测能自动进 fastboot

---

## 5. 测试环境基线

- **测试组合**（缺一不可）：`fastboot erase misc` + flash super + flash **vb_v77**（系统 vendor_boot，`archive/vb_v77.img`）+ flash init_boot（120s DBG）+ `fastboot reboot`
  - **一条命令版**：`scripts/flash_test.sh <super版本> [45\|120\|300\|600\|clean]`——刷前用 `archive/MD5SUMS` 校验、刷后把实际组合+md5 写进 `tmp/logs/flash_*.log`，且**不自作主重启**
- **拉日志**：fastboot → flash `fox_vb12.img` → `fastboot reboot recovery` → `scripts/pull_logs.sh`（自动挂 metadata、拉 `/metadata/logkmsg.log*` + `/sys/fs/pstore/*`）→ `scripts/analyze_logs.sh`
  - `pstore/ramoops` 只在 panic/异常重启后才有内容；干净重启后为空是正常的（logkmsg 只有 logcat 的 I 以上级别，更早的崩只有 pstore 有）
- **收尾**：vb12（Fox）+ `archive/initboot_clean.img`
- **血泪**：vendor_boot 残留 Fox 刷测 = 假象（卡 logo/重启循环）——已两次犯错

---

> ⛔ **A13 已收官（2026-09-28 用户决定）：下面所有未完成项一律「不可用 / 已放弃」，不是待办**。§6 之后的内容按「A16 迁移的参考实现」阅读；新主线见 `A16_PORT.md`。

## 6. 当前状态与下一步（2026-09-28 02:00：**WiFi ✅ 通 + 无线 adb ✅ 通 + Xime 中文输入法 ✅ 预装 + 显示/背光 daemon ✅ 编入正式版本（v91）+ 音频 HAL 崩溃 ✅ 已修（v92）**；v88 首次开机成功已取证）

### 2026-09-28：日常包 v91（Xime 输入法 + 显示 daemon 转正式服务 + 内核日志常驻）✅ 已刷测

**三件事（一次编译 + 一次刷 super）**
1. **Xime 2.8.6 预装**（`com.kingzcheung.xime`，GPL-3.0，Rime 引擎，简体拼音）：APK 源件 `device/lenovo/sycamore/prebuilt/xime/Xime.apk`（归档 `archive/apks/Xime-2.8.6-arm64-v8a.apk`）→ 用 `android_app_import`（`prebuilt/xime/Android.bp`）+ `PRODUCT_PACKAGES += Xime`。⚠️ **AOSP 禁止 `PRODUCT_COPY_FILES` 拷 APK**（`build/make/core/Makefile:72` 直接报错，整个 build 1 分半就死）—— 本轮踩的坑。实机 ✓ 键盘能出拼音候选词。
2. **显示/背光 daemon 转正式**：`device/lenovo/sycamore/prebuilt/led_daemon.sh` → `/system/bin/led_daemon.sh`，`init.tb335.display.rc` → `/system/etc/init/tb335_display.rc`（`on property:sys.boot_completed=1` 启动，`seclabel u:r:su:s0`）—— **本 build SELinux = Permissive，所以不需要任何 sepolicy 规则**。
3. **内核日志常驻**：同一个 daemon 启动时 `dmesg > /data/local/tmp/dbg-kernel.log` 再 `cat /dev/kmsg` 实时追加（4MB 轮转）—— 免费送了一手现场证据，WiFi 驱动 insmod / 挂起唤醒 / 充电三个悬案从此有据可查。

**刷测验证（2026-09-28 01:41，`super_v91` + `vb_v77` + `initboot_clean`）**
- `init.svc.tb335_display = running` ✓、`/sys/power/wake_lock = tb335_nosleep` ✓（内核 `Pending Wakeup Sources: tb335_nosleep …` 也看得到）、`logcat` 里有 `init: starting service 'tb335_display'...` ✓
- 唤醒测试：`input keyevent 224` → `Display State=ON` + `SF mScreenAcquired=1` ✓，且 `LED=102` **是 daemon 按 `mBrightnessState` 算出来写的**（不是卡住的旧值）✓
- `dbg-kernel.log` 618KB，里面 `[wlan_drv_gen4m_6835]` 的 `cnmTimerDoTimeOutCheck` 在跳 = **WiFi 驱动真在跑** ✓
- ⚠️ 验证时的三个假象（别重蹈）：① `adb shell` 不是 root 时读 `/sys/power/wake_lock` 报 Permission denied；② **平板时钟不准**（显示 09-23，文件 mtime 全错，判新鲜度只能看内容/大小）；③ `ps -A | grep led_daemon` 匹配不到（进程名是 `sh`）→ 用 `getprop init.svc.tb335_display` + `/proc/*/cmdline` 判。
- 遗留小瑕疵：平板时钟比现实慢 5 天（时区 `Asia/Shanghai` 正确，怀疑时间服务/NITZ 没对）；keyguard 图层残留（设置页左上角叠了个大号时钟）。

### 2026-09-28：稳定性排查（用户报「系统稳定性不是很好」）

**根因排名（按证据强度）**
1. ✅ **音频 HAL 崩溃 —— 真因已定位，修法已验证（运行时）**：3 分钟 30 次 SIGSEGV，进程 `/vendor/bin/hw/android.hardware.audio.service.mediatek`，栈 = `new_aurisys_lib_manager+148`(`audio.primary.mt6835.so`) ← `create_aurisys_lib_manager` ← `AudioALSAPlaybackHandlerBase::CreateAurisysLibManager()` ← `AudioALSAPlaybackHandlerFast::open()` ← `AudioALSAStreamOut::write` ← `WriteThread::threadLoop`（`Process uptime: 0s` = 一播放就崩）。
   **真因**：厂商 blob 硬编码旧布局路径 **`/system/vendor/etc/aurisys_config.xml`**，而 A13 system 里 **`/system/vendor` 根本不存在**（`ls: No such file or directory`）→ `aurisys_config_parser: parse_aurisys_config("/system/vendor/etc/aurisys_config.xml")` / `xmlParseFile ... fail` / `check whether xml exists, ret=-1`（HAL 自己的日志，`logcat -b all | grep aurisys`）→ 空配置继续往下走 → 解引用空指针。**又一次坑 18（旧布局兼容 symlink 在 `/vendor/etc/init/hw/*.rc` 里，A13 init 不解析子目录）**。
   - 同类证据：`/vendor/etc/init/hw/factory_init.rc:115` 与 `meta_init.rc:99` 都有 `symlink /system/vendor /vendor`（意向明确，但都是 factory/meta 变体 + 在 `hw/` 子目录）
   - ⚠️ **§2.14 的 smartpa 删除是「死配置清理」（该删），但不是这个崩溃的原因**（删后仍以同一栈崩，`tombstone_22` 验证）
   - **修法：✅ 已验证可行（运行时，2026-09-28 02:14）** —— ⚠️ **`/` 和 `/system` 是同一张 erofs ro（system-as-root）：`adb root` 后 `ln` 也报 EROFS**（先前写的「/system 是 rw overlay」是错的：那个 `/mnt/scratch/overlay/system/upper` 不是常驻）。正解 = **先给 `/system` 套一层 rw overlay，再建 symlink**（厂商自己也是这么干的）：
     ```bash
     mkdir -p /data/local/tmp/ovl/upper /data/local/tmp/ovl/work
     mount -t overlay ovl -o lowerdir=/system,upperdir=/data/local/tmp/ovl/upper,workdir=/data/local/tmp/ovl/work /system
     ln -sfn /vendor /system/vendor     # 挂完立刻能建；/system/bin/sh、/system/framework 等全部照常（实测 ✓）
     ```
   - ❌ **`post-fs-data` 里用 init 的 `symlink` 不行**（init 自己的报错）：`Command 'symlink /vendor /system/vendor' action=post-fs-data ... failed: symlink() failed: Read-only file system`
   - **固化（v95）**：`led_daemon.sh` 启动时做「overlay + symlink」（主路径，跑的是验过的 shell 命令）+ `init.tb335.display.rc` 里同款 init 命令（双保险；init 的 `mount` 语法若不认只会记一条错误、不影响其它命令）
   - ✅ 实测（挂 overlay + symlink 后 8 分钟）：音频 HAL `pid=531` 全程存活（活 452s = 整个开机时长）、`aurisys` 无新报错；但 `dumpsys media.audio_flinger` 里输出线程还是 `Standby: yes` → **还没真放过音，待用户实操复验**
   - ❌ **编译期拷贝方案不通（重要教训）**：`PRODUCT_COPY_FILES` 能拷进 staging 的 `system/vendor/etc/` ✓，但 **AOSP 建 `system.img` 时把整棵 `system/vendor/**` 过滤掉**（那棵树在 AOSP 眼里属于 vendor 分区地盘）→ 挂载镜像验证仍是空目录（因此 `super_v93` 与 v92 等价，**没刷**）。另：`install_symlink` 本树不存在（`build/soong/symlink/` 没有）
   - **永久修法（已实施，v95）**：`led_daemon.sh` 启动时：① 给 `/system` 套 rw overlay（`mount -t overlay ovl -o lowerdir=/system,upperdir=/data/local/tmp/ovl/upper,workdir=/data/local/tmp/ovl/work /system`）② `ln -sfn /vendor /system/vendor`。⚠️ **顺序不能反**：`/system` 是 erofs ro，直接 `ln`/init 的 `symlink` 全是 EROFS（`post-fs-data` 阶段实测失败）
   - ⚠️ **v95 事故（2026-09-28 02:24 刷，02:30 回退）**：`super_v95` 刷上后 **能启动**（logkmsg 实证：`09-23 04:29:10 ActivityManager: FB: setting sys.boot_completed`、phase 100→000 全过、SF 跑了 3910 行）**但屏幕停在 LK 的 lenovo logo**（用户看到的「卡 logo」+「重启好一会儿了」）。v95 相比 v94 **只有两处改动**：rc 的 `on post-fs-data` overlay 挂载、daemon 启动时挂载 → **必有一处伤了显示栈**（v94 显示完全正常：LED=102 ✓）。已刷回 `super_v94` + `vb_v77` + `initboot_clean`（02:32，`boot_completed=1` ✓），并手动打回 `symlink`（`svc_tb335=running` ✓）。**下步隔离实验**：只留 daemon 那处 → 编刷 → 看显示是否正常 → 再试 rc 那处（别两处一起上）。
   - **验证方法**：`logcat -b all -d | grep aurisys` 不再报 fail + 音频 HAL 的 `/proc/<pid>/stat` 存活时长能持续涨
2. ✅ **打字「一卡一卡」/ 触摸 5 秒卡死 —— 根因已锁定（就是 §2.14 那条音频链的下游）**：ANR 三连 = `InputMethod (server)` 等 MotionEvent 5002ms / `com.kingzcheung.xime` 5001ms / `PointerEventDispatcher0`（system_server）5120ms。
   **证据链**（`/data/system/dropbox/system_server_anr`）：`"android.ui"`（system_server 的 `UiThread`，**同时就是分发输入事件的那条线程**）状态 **Blocked**，栈 = `AudioService.isStreamMute(AudioService.java:4690)` 等 `<VolumeStreamState>` 类锁（held by tid=102）← `playSoundEffectVolume(5917)` ← `AudioManager.playSoundEffect` ← **`ViewRootImpl.playSoundEffect`** ← `View.performClick`（= 你点键盘时的**点击音效**）；而持锁的 `"AudioService"` tid=102 栈 = `nanosleep/usleep` ← **`ServiceManagerShim::getService`** ← `AudioSystem::get_audio_policy_service()` ← `setStreamVolumeIndex(8254)` ← `applyDeviceVolume_syncVSS(8273)` —— 即 `media.audio_policy` 不在（`audioserver` 正被音频 HAL 崩溃拉着重启）→ `getService` 无限重试（**《工作区笔记》（未随仓库发布） 坑 16 的又一实例，这次卡在 system_server 自己的输入线程上**）→ 输入分发停摆 → 事件送不到输入法 → 多秒停顿（`gfxinfo` 尾部 1050/1100/4050/4950ms 各若干）。
   - 排除掉的假信号（本轮踩到的）：`xime` 的 main/RenderThread 在 ANR 现场**都是空闲**（`__epoll_pwait`）、没有任何 `dequeueBuffer/eglSwapBuffers` 卡点；CPU 也正常（2.0GHz / `schedutil` / 32-35°C 不限频 / `PSI` 无 full 卡顿）→ **不是 app 慢、不是算力不够、不是渲染卡，而是事件根本没送到**。
   - 触摸链路本身干净：`HXTP` 日志无报错、`i2c-mt65xx` 中断正常增长、`InputReader` 空闲在 `EventHub::getEvents` ✓。
   - **立即缓解（免重启）**：`settings put system sound_effects_enabled 0`（关点击音效 → 完全绕开 audio 链路 ✓ 已应用）；**根治** = §2.14 的 v92（音频 HAL 不崩 → `media.audio_policy` 不消失 → 锁不再被攥住）。
3. ⚠️ **SELinux denials**：内核日志里 20 条 `avc: denied`（permissive → 只记不拦；待分类，可能有「别的不工作」是因为它）
4. ⚠️ **平板时钟慢 5 天**（时区对）→ 影响 TLS/证书/日志判读
5. ⚠️ **keyguard 图层残留**（设置页左上角叠大号时钟）

**判读经验（本轮踩到的假信号）**
- `dumpsys media.audio_flinger | grep "Frames written"` **不能判「有没有播过声」**（mixer 线程空闲即销毁重建，计数归 0）
- 判文件「新鲜度」别信 mtime（平板时钟不准）→ 看内容/大小
- 判进程别用 `ps -A | grep 脚本名`（进程名是 `sh`）→ 用 `getprop init.svc.<服务名>` 或 `/proc/*/cmdline`

**用户问「正常 ROM 怎么修这类问题」→ 答案（本轮实践）：移植别家固件时，参考设计的死配置要删。** 本案的 `smartpa_rt5512` 在 A16 里是死链条（库与参数文件都不存在，A16 的 manager 容忍），搬到 A13 就变成崩溃点。对照：主配置 `aurisys_config.xml` 引用的 5 个库（`lib_iir.so` / `libaudioloudc.so` / `libaurisysdemo.so` / `libawinic_mtk_aurisys.so` / `libmtkspparser.so`）本机全在 ✓ 不用动。

### 2026-09-28：显示栈修复（背光不关 + 挂起后开屏卡死）—— 根因与救命招（现已成为 v91 正式服务，见上）

详见本文 **下方「附 2」**（根因定案 + 救命招 + `scripts/display_fix.sh` + 实测 + 局限）。三句话：
- **有背光的黑屏** = A16 HWC 丢了背光写入（系统一切正常，不用救）；**全黑且电源键不亮** = 挂起后开屏的状态机卡死。
- `bash scripts/display_fix.sh rescue` 能把第二种救回来（`adb root` + `setprop ctl.restart vendor.hwcomposer-3-1`；会掐断无线 adb，重连即可）；`start` 起的 daemon 则自动防（LED 写 0 + 禁挂起锁）+ 自愈（唤醒失败 3 秒内重启 composer）。
- **v91 起这条已产品化**（daemon = 正式 init 服务 `tb335_display`，开机自起，不再需要手动 `start`；`display_fix.sh` 降级为手动备用）。

### 2026-09-27：WiFi 三个缺口（v89 修前两个，v90 修第三个）

**实测症状**：v88 时「打不开、扫不到」；v89 后变「开关拨开就自己弹回去」（= 框架真的去启动了，然后回滚），
logcat 与之一一对应。

**缺口 1：`wlan_drv_gen4m_6835.ko` 从来没被装进内核**（厂商 rc 那条 `insmod` 根本没跑到）
- 证据：v6 dump 的 `/proc/modules` 里**有** `wmt_chrdev_wifi`（因为它在 `modules.load` 里，第一阶段装的）
  但**没有** `wlan_drv_gen4m_6835`；logcat 里 `W/mod: Unknown iface name: wlan0`
- 修（v89）：`device/lenovo/sycamore/modules_dlkm/modules.load` 末尾加一行 `wlan_drv_gen4m_6835.ko`
- ✅ 已验证：v7 dump 里 `wlan_drv_gen4m_6835.ko rc=-1 errno=17`（17=EEXIST，**表示已经装上了**）+ 该模块
  出现在 `/proc/modules`；`/proc/net/dev` 当时（T+45s）还没 `wlan0`，配置接口在 ~T+53s；第②步
  logcat：`wificond createClientInterface wiphy_index 0` + `wlan0` ✓

**缺口 2：`android.hardware.wifi.supplicant-V1-ndk.so` 缺失**（A16 的 `wpa_supplicant` 依赖它）
- 证据：`F linker: CANNOT LINK EXECUTABLE "/vendor/bin/hw/wpa_supplicant": library
  "android.hardware.wifi.supplicant-V1-ndk.so" not found`
- 修（v89）：`m android.hardware.wifi.supplicant-V1-ndk`（HAL 源码 A13 里就有）→ 产物拷进
  `vendor/lenovo/sycamore/proprietary/lib64/` → `vendor-blobs.mk` 加一条
  `PRODUCT_COPY_FILES += …:vendor/lib64/…`（装到 `/vendor/lib64/`，因为要它的进程在 vendor）
- ✅ 已验证：`CANNOT LINK` 消失，supplicant 起得来
- ⚠️ 陷阱：这行必须挂在 `PRODUCT_COPY_FILES += \` 后面，否则 kati 把源码路径当规则目标 →
  `vendor/lenovo/sycamore/vendor-blobs.mk:2964: error: writing to readonly directory: …`

**缺口 3：`/data/vendor/wifi/wpa` 目录根本不存在**（v90 修，✅ 已实测通过）
- 证据链（`tmp/logs/logkmsg.log.1`）：`WifiNative: Failed to write to
  /data/vendor/wifi/wpa/wpa_supplicant.conf Errno: No such file or directory` +
  `Failed copying /vendor/etc/wifi/wpa_supplicant.conf` → `ISupplicantStaIface.addIface failed` →
  `WifiActiveModeWarden: ClientModeManager start failed!` → 开关弹回 ✓ 与用户看到的一致
- 根因：A13 init 只解析 `/system/etc/init/hw/init.rc` + `/vendor/etc/init`（**非递归**）+ 它们的 import；
  厂商建目录的那句在 `hw/init.connectivity.common.rc`，被 `hw/init.connectivity.rc` import ——
  这条 import 链 A13 不跟（09-01 那轮就实测过）。09-01 时 WiFi 服务启动没报这个错，是因为当时
  照抄了 stock 的**顶层** `hostapd.android.rc`（它建 `/data/vendor/wifi/hostapd`），我们是 partial copy。
- 修（v90）：在我们**已装到顶层**的 `proprietary/etc/init/hw/init_connectivity.rc` 里自己 mkdir
  `/data/vendor/wifi`、`/data/vendor/wifi/wpa`、`/data/vendor/wifi/wpa/sockets`（`on post-fs-data`，
  追在 connsyslog 的 mkdir 后面）→ `mka bacon -j8` + `pack_super.sh 90`
- ✅ **已实测（2026-09-27 03:50，`super_v90` + `vb_v77` + `initboot_clean`）：WiFi 开关能保持打开、
  能扫到周围网络 —— WiFi 三个缺口全修完，WiFi 这条线通了**

**附：无线 adb 可用（2026-09-27 04:00）** —— WiFi 通了之后开「无线调试」并配对一次 →
`adb connect <平板IP>` 直接进系统（`adb shell` / `adb logcat` / `adb install` 全通），
平板自己也通外网。USB gadget 仍然坏，但**开发/预装/拉日志不用再绕 Fox 了**（见 `BUILD.md` §5.5）。

**附 2：熄屏后「黑屏有背光」/ 拔电后「全黑・电源键不亮」—— 根因已定案、已现场修复（2026-09-27 04:14 首遇 → 2026-09-28 01:30 定案）**

**先看结论（操作手册）**
- **LED = 你的 brightness 设置值（例 102 vs 103）+ 屏黑** → 「有背光」型：HWC 只丢了背光写入，
  **系统一切正常，不用救**；想让背光真关 → `bash scripts/display_fix.sh start`（同时拿住禁挂起锁）。
- **LED=0 + 完全无光 + 电源键不亮** → 「睡死」型：**能救** —— `bash scripts/display_fix.sh rescue`
  （内部 = `adb root` + `setprop ctl.restart vendor.hwcomposer-3-1`）→ 显示几秒内回来。
  ⚠️ 该动作**会掐断无线 adb**（composer 重启连带 SF 重启），重连 `adb connect <平板IP>` 即可。
- 有 daemon 在跑时（`display_fix.sh start`）：灭屏背光自动写 0、禁挂起锁常驻、唤醒失败 3 秒自动自愈。
- **触发条件（实测）**：熄屏后 **10 秒内**唤醒 ✅ 正常；静置 **2 分钟以上**（真正进挂起）唤醒 ❌ 必失败。
  拔线只是巧合 —— **睡眠时长才是病因**（所以「拔线睡死」和「息屏黑屏」是同一件事）。

**根因（2026-09-28 定案）**：A13 SurfaceFlinger × A16 厂商 AIDL composer(3.1)/HWC 混血，
**「挂起后再开屏」这条路径的状态机走不完整**：
- 面板侧其实执行了（内核 `lcm_panel_init start`），但 SF 拿不回显示：`mScreenAcquired=0`、
  `mHWVsyncAvailable=0`、`ScreenOff: 0d00:03:03`，内核 `Pending Wakeup Sources` 里 `disp_crtc0_wakelock`
  一直挂着 → 画面起不来（屏黑）。
- 同时 HWC 对 `/sys/class/leds/lcd-backlight` 的亮度写入被丢弃（vendor 只暴露 `IComposerExt@1.0`，
  无 `android.hardware.graphics.composer@2.x`，与 `lshal` 一致；`setPowerMode` 两边都有所以面板关得了）
  → LED 卡在用户亮度：关屏不写 0、开屏不写回，就是你看到的「黑屏但有背光」。
- 顺带写实的一条：拔线后 `dumpsys battery` 仍报 `USB powered: true` / `CHARGING`（内核
  `typec_attach_new:1 vbus:4522`）→ **MTK 充电驱动没认到拔线**（独立小问题，另记）。
- ⚠️ 别拿 `input keyevent 26` 当唤醒测试（不可靠 ✗，物理电源键才准）；也别信
  `debug.tracing.screen_state`（卡住时它仍是 `1`，不跟实际状态走）。

**救命招与自愈 daemon（都已实测，2026-09-28 01:20）**
- **`adb root` 可用**（userdebug：`ro.debuggable=1`）→ 直写 LED、拿禁挂起锁、重启显示栈都行。
  （`echo 0 > /sys/class/leds/lcd-backlight/brightness` 立刻生效，实测 102→0 ✓）
- **救命招**：`setprop ctl.restart vendor.hwcomposer-3-1`（厂商 rc 里有 `onrestart restart surfaceflinger`）
  → 重启后显示立刻回来：`Display State=ON` / `mWakefulness=Awake` / `mScreenAcquired=1` /
  `mHWVsyncAvailable=1`（连之前设的 `mBrightnessState=0.2` 都被采用了）。副作用：掐断无线 adb。
- **`scripts/display_fix.sh`（本机脚本，`start|stop|rescue|status`）**：把 `/data/local/tmp/led_daemon.sh`
  推上平板并跑起来，daemon 三段逻辑：
  1. `echo tb335_nosleep > /sys/power/wake_lock`（禁挂起锁；实测 `suspend success=0` 一直不深睡）；
  2. 事件驱动（`cat /dev/kmsg`，**别用轮询**：`dumpsys` 53ms / `getprop` 25ms / `settings` 54ms 一次）——
     `lcm_panel_init start` → 读 `mBrightnessState` 换算 0-255 写 LED；
     `[lenovo_panel_notifier_callback:848] suspend` → LED 写 0；
  3. **自愈看门狗**：亮屏事件 3 秒后若 `dumpsys SurfaceFlinger` 里没有 `mScreenAcquired=1`
     → `setprop ctl.restart vendor.hwcomposer-3-1`（20 秒限流，时间戳落 `/data/local/tmp/led_daemon.rescue`）。
- **实测结果**：灭屏 LED=0 ✓（不再发光）、亮屏 LED 跟到 102 ✓、`suspend success=0` ✓、
  看门狗自动救活过一次（rescue uptime=919 ✓）、用户物理电源键静置 3 分钟后能正常亮 ✓。
- **局限（已知，未做）**：① daemon **重启即丢** → 用户决定「先归档，正式版本一起编入」（见文末 TODO）；
  ② 亮度滑条拖动**不会实时**改 LED，只在下次亮屏时按 `mBrightnessState` 生效（framework 的亮度调用
  被 HWC 丢弃，只能我们代写）；③ 根治要等 A16 迁移（HWC/AIDL composer 版本适配）。

**本轮教训（新增）**
- DBG 子进程跑在 **kernel 域** → **读不到任何属性**（v7 dump 里 props 全 `<unset>`，连 `ro.*` 都是）。
  想知道属性状态得换域，或从 logcat 里 `getprop` 的痕迹看。
- 查 WiFi 要同时看三处：`/proc/modules`（驱动装没装）、`/data/vendor/wifi/wpa`（supplicant 状态目录）、
  logcat 里 `WifiNative` / `supplicant` / `ActiveModeWarden` 三家的话。
- 「驱动装上没有」的硬判据是 **`/proc/net/dev` 里有没有 `wlan0`**；`/proc/modules` 里 Live 只说明模块在。
- 主日志通道够用（`logcat` 里就能看到 supplicant/linker 的报错），不必依赖内核日志；内核日志只在
  查「驱动/insmod 为什么失败」时才必须。

### 2026-09-25 深夜（04:05 收工）新增：DBG v6 + WiFi/KSU 诊断

**① DBG 补丁升级到 v6（`patches/initboot-dbg.diff`，只需重编 init_boot ~14s）**
— T=N 秒时那个子进程现在做四件事：试装 `/metadata/kernelsu.ko` → 复测 `wlan_drv_gen4m_6835.ko`
→ **用 `syscall(__NR_syslog, SYSLOG_ACTION_READ_ALL=3)` 把内核 ring buffer 全量** + `/proc/cmdline`
+ `/proc/modules` 写 `/metadata/dbg-kernel.log` → 写 BCB 重启进 fastboot。
— **教训 1（白跑一轮）**：`/dev/kmsg` 读不到历史消息！它的读位置是「打开那一刻之后的新消息」，
ring buffer 里已有的全读不到。dmesg 用的是 `syslog(2)` 系统调用（READ_ALL，且不清 buffer）。
— **教训 2**：结论（rc/errno）要**直接写进 dump 文件**，别只写日志——日志丢一次就白跑一轮。
— **教训 3**：`finit_module()` 对**未解析符号**返回 `-ENOENT`（`Unknown symbol X (err -2)`），
跟 `open()` 的 ENOENT 完全撞车；记录 RC/errno 时必须分开写，否则会误判成“文件不在”。
— **教训 4**：内核 ring buffer 只存 **~70 秒**（MTK 太吵：实测窗口 60.16s→129.5s）→ 想看早期
启动阶段（厂商 rc 的 insmod 在 t≈20-40s）必须用**小窗口**（`dbg45`）dump。
— 一条命令跑完整循环：`scripts/ksu_test.sh`（~5 分钟，自动刷 4 个分区 + 推 .ko + 拉日志；
**在 recovery 里就跑就自己跳进 fastboot，不用按键**；只动 vendor_boot_a/init_boot_a/misc，碰不到 super）。

**② WiFi 诊断（真凶·半截结论）**：`/proc/modules` 里**没有 `wlan_drv_gen4m_6835`**，
但 DBG v6 手动 `finit_module` **成功**（内核日志：`Create wireless device success` → `mtk_axi_probe done`
→ `initWlan::Init`），且 WMT 确实把 `vendor.connsys.driver.ready` 设成了 `yes`（`wmt_loader`/
`wmt_launcher` 日志）→ 所以不是模块/文件/权限的问题，是**厂商 rc 的 insmod 没生效或失败被冲掉**。
→ 下一步：`scripts/build_initboot.sh 45` 编 v6 的 45s 窗口，用 `scripts/ksu_test.sh` 再跑一轮，
看 t≈20-40s 那段内核日志里厂商那次 insmod 的原文（`/dev/kmsg` 里“`no symbol version`/`Unknown symbol`”
这种字样就是定性关键）。

**③ KernelSU 诊断（预编译 LKM 不可行，已定性；2026-09-28 用 `adb root` 现场复测，不用刷机）**：
`archive/kernelsu-android13-5.15-v3.3.0.ko`（374032 B，vermagic `5.15.202-android13-5.15.202_r00-dirty`）
对我们内核 `5.15.185-android13-8-00044-g051a97cf151a` **三重不匹配**：

| 维度 | 我们的内核（`/proc/version`） | KSU 预编译 .ko |
|---|---|---|
| 内核版本 | `5.15.185` | `5.15.202` |
| KMI 分支 | `android13-8-00044-g051a97cf151a` | `android13-5.15.202_r00` |
| 符号表 | **没有** `kvrealloc` 等 | 需要 `policydb_read` / `symtab_insert` / `kvrealloc` / `ebitmap_*` / `avtab_*` / `change_pid` / `static_key_count` / `sidtab_destroy` / `avc_has_perm` / `security_context_to_sid` … |

`insmod` 报 `kernelsu: Unknown symbol … (err -2)` ×20+（全是 SELinux 内部符号 + 一个 5.15.202 才有的
`kvrealloc`）；而 `CONFIG_MODVERSIONS` 开着，符号 CRC 也必须逐个对上 → **结构上不可能加载**，不是「差一点」。
（旧记录里"能过 vermagic"是错的：那次测的是另一个 `.ko`，`path_umount`/`filp_open`/`init_mm`/`selinux_blob_sizes`
那批符号属于更早的一次试验。）

**自编也不可行**：我们的内核是**预编译镜像** —— `device/lenovo/sycamore/BoardConfig.mk:23`
`TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/Image`，服务器 `~/los20` 里既**没有内核源码树**
（只有 `kernel/configs|google|prebuilts|tests`）也**没有 `Module.symvers`**；自编要先下载 GKI `android13-8`
全套源码 + 完整编一遍内核拿符号表（2-4 小时 + 大下载，CRC 仍可能对不上）。

→ **结论：改走 Magisk**（纯用户态，把 `magiskinit` 塞进 `init_boot` 的 ramdisk 冒充 `/init`、再 exec 真 init，
   **不碰内核、不碰符号**），Magisk app 就是 root 管理器。

**⚠️ 两个附带事实（别被旧记录带偏）**：
- 今晚那轮「KSU LKM 路线」的 `.ko` **其实没进镜像**：设备上 `/vendor/lib/modules/kernelsu.ko` 不存在、
  `/vendor/lib/modules/modules.load` 里也没有该行 → 那次是**空跑**，不能当成"已经试过 LKM 部署"。
- 手动 `insmod` + `dmesg` 定性比刷机快一万倍，前提是 **`adb root` 可用**（userdebug：`ro.debuggable=1`）。

**⚠️ 顺带确认的坑**：`/metadata` 上新推的文件在系统启动后会消失过一次（那次 `kernelsu` rc=-1 errno=2
其实是 finit_module 的 ENOENT，见教训 3）——但**顺手把 .ko 推到 `/metadata` 这种做法本身不可靠**：
系统可能对 `/metadata` 做初始化/格式化。要长期可用就放 ramdisk（`lib/modules/`）或 `vendor_dlkm`。

### 已达里程碑
- 显示链全通（v52d）→ SystemServer 进（v63）→ FATAL 清零（v67）→ **开机动画**（v75/76）→ boot 流程走完（v77）
- **finishBooting 进入 + SurfaceFlinger “Boot is finished”**（v83-v85）
- phase 1000 只剩 UsbService 最后一环（v85 超时生效，但仍循环重启）
- **v86 刷测后真相（2026-09-24）：不是“等”的问题，是 1000 阶段 `mUsbService.bootCompleted()` 在 null 上调用（NPE）** —— 见下
- **DBG 自动重启修好（2026-09-24 03:00，v4）**：旧版只发裸 `syscall(RESTART2,"bootloader")`（不写 BCB、不落盘）→ 窗口到点卡 logo；v4 加 `write_reboot_bootloader()` + `sync()`，**45s 实测自动回 fastboot**（`tmp/logs/watch_dbg45.log`：02:56:21 离线 → 02:57:38 fastboot）。详见 §4.1

### ⚠️ v86 刷测结论（2026-09-24 01:55 实测）：v86 生效了，但暴露了真正的最后一环

**证据（pulled logs；设备时钟显示 09-18，实际是 2026-09-24）**：
```
W UsbService: AM phase not finished, proceeding anyway
   at com.android.server.usb.UsbService$Lifecycle.onBootPhase(UsbService.java:118)
E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: android.display
E AndroidRuntime: java.lang.RuntimeException: Failed to boot service com.android.server.usb.UsbService$Lifecycle: onBootPhase threw an exception during phase 1000
E AndroidRuntime: Caused by: java.lang.NullPointerException: Attempt to invoke virtual method 'void com.android.server.usb.UsbService.bootCompleted()' on a null object reference
```
- `get(0, ...)` **确实生效**（不再等 10s，直接进 catch 打 warning）—— **但紧接着的 1000 阶段代码去调 `mUsbService.bootCompleted()`，而 `mUsbService` 是 null**（550 阶段那个任务因为 AM 永不完成而没把它造出来）→ NPE → system_server 死 → **每 ~17 秒一轮重启循环**（logs 里 3 轮：20:04:31 / 20:04:48 / 20:05:04）
- 副产物（解释了今晚另外两个谜）：UsbService 崩 → **USB gadget 配不起来 → adb 永不出现**；system_server 循环崩 → **logkmsg 只写 ~37 秒就停**（不是“丢数据”，也不是“logcat 没写”）
- 现象吻合：开机动画播一遍 → 卡 logo（bootanim 永远等不到 `enableScreen`）

### v88（2026-09-24：03:28 bacon 编译成功（09:53，0 error）、03:29 打包 → `archive/super_v88.img`，md5 `1e576696a845695b9bcf60c988c94a50`）★最后卡点，**已破——首次开机成功**

**刷测结果（2026-09-25 03:07：`scripts/flash_test.sh 88 120`）**：`erase misc` + `super_v88` + `vb_v77` + `initboot_dbg120` → 03:07:04 `fastboot reboot` 起动 →
屏幕走出开机动画、到**桌面/初始设置页**（用户实机目击）= **`sys.boot_completed=1` 达成**（项目主目标）。USB/adb 仍然坏（符合预期）。

**日志硬证据（2026-09-25 03:11 拉取；v88 段 = 最新 `/metadata/logkmsg.log`（925 KB，平板时钟 09-19 21:10，**FATAL=0**））**：
```
09-19 21:10:24.103 I SurfaceFlinger: Boot is finished (18240 ms)
09-19 21:10:24.107 I ActivityManager: FB: finishBooting enter
09-19 21:10:24.111 I ActivityManager: FB: before PHASE_BOOT_COMPLETED
09-19 21:10:24.296 I ActivityManager: FB: after PHASE_BOOT_COMPLETED
09-19 21:10:24.300 I ActivityManager: FB: setting sys.boot_completed   ← ★ 主目标达成
09-19 21:10:26.151 I ActivityManager: Posting BOOT_COMPLETED user #0
09-19 21:10:28.893 I ActivityManager: Finished processing BOOT_COMPLETED for u0
```
v87 在同一位置是 `FAIL`（`SystemServerInitThreadPool.shutdown()` 抛 `IllegalStateException`，未完成任务 `UsbService$Lifecycle#onStart/#onBootPhase`）；
v88 段从头到尾 **0 个 FATAL**，且 LOCKED_BOOT_COMPLETED / BOOT_COMPLETED 广播全部处理完。
- 教训（当晚踩的坑）：`scripts/flash_test.sh` 因没看到 fastboot 直接退了（**没刷任何东西**），我错误地跟着敲了 `fastboot reboot` → 当时 vendor_boot 还是 Fox → 正常启动死循环。**《工作区笔记》（未随仓库发布） 坑 2 是真的**：vendor_boot=Fox 时只能 `fastboot reboot recovery`；正常启动只能在 vendor_boot=vb_v77 时用。

**根因（从 v87 刷测日志坐实）**：boot 已经走到 **`PHASE_BOOT_COMPLETED` 前一行**，只因 USB 的两个线程池任务没收尾被打死：
```
java.lang.IllegalStateException: Cannot shutdown. Unstarted tasks [] Unfinished tasks
  [UsbService$Lifecycle#onStart, UsbService$Lifecycle#onBootPhase]
  at SystemServerInitThreadPool.shutdown(SystemServerInitThreadPool.java:180)
  at SystemServiceManager.startBootPhase(SystemServiceManager.java:312)
  at ActivityManagerService.finishBooting(ActivityManagerService.java:5179)
  → FATAL EXCEPTION IN SYSTEM PROCESS: android.display → Sending signal. PID: 3930 SIG: 9
```
- **`#onStart` 卡在哪**（构造任务线程最后那段日志）：`I UsbPortManager: USB HAL AIDL present` 之后只剩每秒一条
  `W ServiceManager: Waited one second for android.hardware.usb.IUsb/default (is service started? ...)`，永远等下去
- 代码位置：`services/usb/java/com/android/server/usb/hal/port/UsbPortAidl.java:156` 的 `isServicePresent()` 用
  `ServiceManager.isDeclared(USB_AIDL_SERVICE)` = **只看 VINTF 声明**；A16 vendor 声明了 `android.hardware.usb.IUsb/default`
  但没起 AIDL 实例 → 返回 true → `new UsbPortAidl(...)` 构造里的 `ServiceManager.waitForService()` 无超时重试
- 前几环都已被 v87 兜住（HIDL `IUsbGadget.getService()` → `NoSuchElementException`；`UsbHandlerLegacy` 读 legacy sysfs →
  `ErrnoException: ENOENT` → `Error initializing UsbHandler`），所以整个 boot 只剩这一个坑

**修法（1 文件 1 行）**：`patches/v88-usbport-aidl.diff`
```java
-            return ServiceManager.isDeclared(USB_AIDL_SERVICE);
+            return ServiceManager.getService(USB_AIDL_SERVICE) != null;   // v88: 即时探测，没实例就没 port HAL
```
没实例 → `UsbPortHalInstance.getInstance()` 落到 HIDL 分支（`UsbPortHidl.isServicePresent()` 也 false）→ 返回 null →
`UsbPortManager.mUsbPortHal = null`（全程 null 检查）→ 构造返回 → 两个池任务收尾 → `shutdown()` 不抛 →
**`PHASE_BOOT_COMPLETED` = `sys.boot_completed=1`**（USB 功能仍坏，符合预期）

**代价**：USB port HAL（PD/污染检测通知）在本混血上永远不可用——可接受（gadget 本来就坏）。
**还原**：`cd ~/los20/frameworks/base && git checkout -- services/usb/java/com/android/server/usb/hal/port/UsbPortAidl.java`

### v87（已编译、打包、刷测（2026-09-24 02:26 完成 / 02:31 起动），待拉日志）

**根因链（2026-09-24 从 v86 日志推出，比 NPE 深一层）**：
```
UsbService.java:192  new UsbDeviceManager(...)        ← 构造函数里就抛异常
  UsbDeviceManager.java:311  IUsbGadget.getService()   ← A16 gadget HAL 拿不到
  UsbDeviceManager.java:335  UsbHandlerLegacy.<init> → FileUtils.readTextFile
      → android.system.ErrnoException: open failed: ENOENT (No such file or directory)
  E UsbDeviceManagerJNI: could not open control for mtp No such file or directory
→ mUsbService 永远 null → 550 阶段任务永久阻塞在 mOnStartFinished.join()
  （所以 `v86: USB550 systemReady enter` 压根没打印）→ 1000 阶段 NPE → system_server 每 ~17s 重启
```
注意：`/sys/class/android_usb` **存在**（所以进的是 UsbHandlerLegacy 分支），但里面的控制节点缺失 → 属坑 16 那类 “A16 厂商侧没就绪”问题。

**v87 改动（已打到源码，`patches/v87-usbservice.diff`）——3 处，都很小**：
1. `onStart()` 里 `new UsbService()` **try/catch(Throwable) + finally complete**（构造失败不再永久阻塞 join、不再 null）
2. 550 阶段任务：`mOnStartFinished.join()` 后 `if (mUsbService == null) return;`（带 `v87: USB550 skip` 日志）
3. 1000 阶段：`bootCompleted()` 前 `if (mUsbService == null) { Slog.w("v87: UsbService not created, skip bootCompleted"); return; }`

**预期与风险**：boot 应该能跑到底（`boot_completed`），**但 USB gadget 大概率仍是坏的 → adb 依旧不出现**（因为构造函数那一步就没成功）。所以验证靠：屏上 UI 是否出来 + `scripts/pull_logs.sh` 里的 logkmsg 搜 `boot_completed`（*不是*靠 adb）。下一步真正的硬骨头是让 UsbDeviceManager 在 A16 gadget 节点下能活（或容忍缺失）。

**流程**：`cd ~/los20 && … mka bacon -j8` → `~/superwork/pack_super.sh 87` → `scripts/flash_test.sh 87 600`

### v86（已完成）
1. 构建：`cd ~/los20 && export ALLOW_MISSING_DEPENDENCIES=true && source build/envsetup.sh && lunch lineage_sycamore-userdebug && mka bacon -j8`（日志 `~/losbuild.log`）
2. 打包：`~/superwork/pack_super.sh 86` → scp 到本机 `archive/super_v86.img`（并在 `archive/MANIFEST.md` 登记）
3. 刷测：`scripts/flash_test.sh 86`（等价于 `erase misc` + `super_v86` + `vb_v77.img` + `initboot_dbg120.img` + 手动 `fastboot reboot`，组合见 §5）
4. 拉日志：`scripts/pull_logs.sh && scripts/analyze_logs.sh`

### v86 改动内容
- `UsbService.java` 1000 阶段：`get(10, SECONDS)` → `get(0, ...)`（不等待、只探测，省下与 watchdog 抢的 10s；保留 Slog.w 信号）
- `UsbService.java` 550 阶段任务：进/出 `systemReady()` 各打一条 `v86: USB550 systemReady enter/exit`，用来确认是否卡在里面
- 补丁：`patches/v86-usbservice.diff`（可用 `git apply` 重放）；退回 v85 行为：`git checkout -- services/usb/java/com/android/server/usb/UsbService.java`

### 判读（拉完日志）
- `scripts/pull_logs.sh` → `scripts/analyze_logs.sh`
- 到 `sys.boot_completed=1` → 成功，进“开机后收尾”（bootanim 退出 / user 0 unlock / Launcher）
- `USB550 enter` 有、`exit` 无 → 卡在 `UsbService.systemReady()` 内部，下一刀切那条调用链（usb HAL / `getService(true)`）
- 仍 watchdog 循环 → 看 FB 最后标记定位 1000 之后的卡点（v81 BOOTPHASE + v83 FB）

### 遗留
- [ ] secure_element 崩循环回归（见 2.9）
- [ ] user 0 unlock 仍未发生（unlockUser 日志从未出现；watchdog "Blocked in handler on display thread"）
- [ ] 稳定后收窄：还原 v65/v66 冗余 try-catch
- [ ] logkmsg 轮转加大（防 boot 早期日志丢失）
- [ ] **把 display daemon 编进正式版本**（`scripts/display_fix.sh` → 设备树/init_boot 侧 init 服务，见 §6 附 2）
- [ ] MTK 充电驱动「拔线不认」（`mPlugType=USB` 一直报插着）
- [ ] wmt 固件主体缺失影响（wifi/bt 功能不可用预期内）
- [ ] **终局方向：A16 移植**（本类"等不存在的 A16 服务"死锁全消；A13 混血已证明硬件可行）

---

> ⛔ **以上 TODO 清单属于 A13 阶段，自 2026-09-28 起全部冻结**（「不可用 / 已放弃」，不是待办）。新主线 = **A16 迁移**（`A16_PORT.md`）。
