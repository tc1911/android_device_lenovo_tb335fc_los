# BUILD.md — TB335FC 构建参考手册

> 本文件只放**当前有效的参考信息**（设备 / 环境 / 命令 / 刷机 / FAQ）。
> 时序排错过程（"当时为什么这么改"）→ 《开发日志》（未随仓库发布）。
> 启动 hack 清单 → `BOOT_HACKS.md`。工作规则与硬坑 → 《工作区笔记》（未随仓库发布）。
> 最后更新：2026-09-28

## 0. 文档地图

| 文档 | 内容 | 何时看 |
|---|---|---|
| 《工作区笔记》（未随仓库发布） | 工作规则、硬坑（16 条）、刷测组合、当前状态 | **每次会话先读** |
| `BOOT_HACKS.md` | 为启动做的全部非常规改动（位置/动机/影响/还原）+ 当前状态与下一步 | 改 boot 相关前 |
| `BUILD.md` | 本文件：参考手册 | 要敲构建/刷机命令时 |
| 《开发日志》（未随仓库发布） | 2026-08-26 ~ 09-09 全部 session 原文（时序） | 查历史实验/根因时 |
| `A16_PORT.md` | **A16（LineageOS 23）迁移计划书**：硬证据 / 迁移面 / 分阶段 / 空间预算 / 风险（2026-09-28，未动工） | 讨论 A16 迁移时 |
| 《共存计划》（未随仓库发布） | 系统与 recovery 共存计划书（方案 A–E） | 讨论共存时 |
| `patches/framework-hacks.diff` | frameworks/base 7 + frameworks/native 1 + lineage-sdk 2（截至 v88）的源码补丁 | 还原/移植 hack 时 |
| `archive/` | 镜像归档 | 刷机取镜像时 |
| `archive/docs_backup_2026-09-23/` | 本次文档重构前的原文备份（含 MD5SUMS） | 对照旧文档时 |
| `external-refs/` | 第三方资料（MTK 解密教程、LOS 编译指南、stock manifest） | 解密/编译调研时 |

## 1. 设备规格

- 联想 TB335FC（小新平板）/ MTK **MT6835**（sycamore）/ ZUI
- ROM：TB335FC_ZUXOS_1.5.10.233（build 260615_233）
- 启动：boot v4 三镜像 = `boot`（仅内核）+ `init_boot`（ramdisk）+ `vendor_boot` v4（vendor ramdisk + dtb），**无独立 recovery 分区**
- 分区：A/B + 动态分区 `super`（system / vendor / product / system_ext / odm / odm_dlkm / vendor_dlkm / system_dlkm，EROFS）
- 内核：设备 stock 5.15.185-android13-8（KMI android13-8）；设备树实际用 `prebuilt/Image`（25 021 375 B，vermagic `5.15.185-android13-8-gab2004cfb148` = **与厂商模块完全一致**，见 `A16_PORT.md` §1）；历史记录里的「Google 原版 GKI 源码 `common-android13-5.15-2025-07`（051a97c）」指的是同一条 GKI 线
- ⚠️ `ro.boot.hardware=` **mt8755**（vendor 命名，不是 mt6835）——HAL/库名按 mt8755 找
- BL：**已解锁**。解锁脚本 `/run/media/tc191/data/lenovopad112025/bl/unlock_bl.sh`，sn.img 同目录 `/run/media/tc191/data/lenovopad112025/bl/sn.img`
- ⚠️ 刷官方整机包会**回锁**（Firmware Upgrade 写 lenovoraw.img）；此机 ROM 工具只支持 Firmware Upgrade，不支持 Download Only

## 2. 服务器与编译环境

- **本机**（`工作区根`）：文档、镜像归档、平板 fastboot 操作。**不含源码**
- **服务器**：`ssh <服务器>`（密钥免密 + NOPASSWD sudo），Debian 13 (Trixie)，Xeon E3-1270 v5 4C8T / 16GB / 500GB NVMe
- 源码树：`~/twrp`（TWRP 14.1）、`~/fox_14.1`（OrangeFox）、`~/los20`（lineage-20.0，97G）
- 本地封装：`scripts/los_ops.sh {build|status|log|product|get-vendor-boot|pack <版本>}`、`scripts/mount_srv.sh {mount|umount}`（SSHFS → `srv_home`）；全部脚本见 《工作区笔记》（未随仓库发布）「脚本」表
- Python：repo 2.54 **只能用 `python3`**（3.13 死锁）
- swap：`/swapfile` 30G（soong 卡住 = 内存不足；**编译期间勿删**，编译完 `swapoff + rm`）
- 空间：fox_14.1 的 `.repo`=150G 可删（删后仍可编译，只是不能 repo sync）；LOS 约需 100G

## 3. 设备树

- 本目录副本：`android_device_lenovo_sycamore/` → 源码树内 `device/lenovo/sycamore/`
- blobs：`vendor/lenovo/sycamore/proprietary/`（1.3G，`proprietary-files.txt` 3292 条）
- 关键文件：`BoardConfig.mk`（GKI 内核/动态分区/AVB）、`device.mk`（fstab/rc/COPY）、`lineage_sycamore.mk`（LOS 产品）、`twrp_sycamore.mk`、`fstab.mt6835`、`recovery.fstab`、`init.recovery.mt6835.rc`、`prebuilt/{Image,dtb}`、`modules_copy.mk`、`extract-files.sh`、`setup-makefiles.sh`
- ⚠️ 两份 fstab **必须同步改**：`device/lenovo/sycamore/fstab.mt6835` + `vendor/lenovo/sycamore/proprietary/etc/fstab.mt8755`；改完 `mka vendorbootimage`
- ⚠️ blobs 配置文件名必须是 `vendor-blobs.mk`（**不能叫 `Android.mk`**，kati 扫描会触发 PRODUCT_COPY_FILES 只读报错）
- hack 标记：源码里以 `vNN:` 注释，`grep -rn "vNN:"` 定位；登记在 `BOOT_HACKS.md`

## 4. 构建命令

前置（所有目标）：`export ALLOW_MISSING_DEPENDENCIES=true && source build/envsetup.sh`

```bash
# 4.1 LineageOS 20（主线）— 产物 super / boot / vbmeta 全套
cd ~/los20 && lunch lineage_sycamore-userdebug && mka bacon -j8      # 日志 ~/losbuild.log
grep DeviceProduct ~/los20/out/soong/soong.variables                # 必须 lineage_sycamore（防编成 aosp_arm）

# 4.2 只重编 init_boot（DBG 版走这里）— 增量 ~14s
cd ~/los20 && mka initbootimage -j8        # 注意：不是 init_bootimage！

# 4.3 只重编 vendor_boot（改 fstab 后必须）
cd ~/los20 && mka vendorbootimage -j8

# 4.4 TWRP（已收尾，稳定）
cd ~/twrp    && lunch twrp_sycamore-ap2a-userdebug  && mka vendorbootimage -j8   # 日志 ~/build.log

# 4.5 OrangeFox（已收尾，稳定）
cd ~/fox_14.1 && lunch fox_sycamore-ap2a-userdebug && mka vendorbootimage -j8   # 日志 ~/foxbuild.log
```

- 产物在服务器 `out/target/product/sycamore/`；拉到本机：`scp <服务器>:<路径> /tmp/opencode/x.img`
- super 打包（`lpmake -S` 直接出可刷 sparse，**不要** raw+truncate+img2simg）：服务器 `~/superwork/pack_super.sh <版本号>`
- DBG init_boot 源码：`~/los20/system/core/init/first_stage_init.cpp`（sleep N + reboot "bootloader"）；**bacon 会把 DBG 编进所有 init_boot 产物**，要干净版先 `git checkout -- system/core/init/first_stage_init.cpp`

## 5. 刷机 / 救砖 / 日志

### 5.1 LOS 刷测标准组合（缺一不可）

一条命令搞定（刷前 md5 校验、刷后写 `tmp/logs/flash_*.log`，不自作主重启）：
```bash
scripts/flash_test.sh 86            # 默认 initboot_dbg120；窗口可选 45|120|300|600|clean
```

等价的手工命令（脚本内部就干这些）：
```bash
fastboot erase misc
fastboot flash super          archive/super_vNN.img
fastboot flash vendor_boot_a  archive/vb_v77.img          # 系统 vb，不是 Fox！
fastboot flash init_boot_a    archive/initboot_dbg120.img # 默认 DBG 120s
fastboot reboot
```

⚠️ 拉完日志（刷过 Fox）后再测系统 boot，**必须把 vendor_boot 刷回 vb_v77**，否则卡 logo/重启循环 = 假象（已犯错 2 次）。

### 5.2 刷 recovery（TWRP / OrangeFox）

```bash
fastboot flash vendor_boot_a <out>/vendor_boot.img
fastboot reboot recovery        # 绝不 fastboot reboot（会进系统无限重启）
```

### 5.3 救砖

- 首选 **fastboot 刷回 stock**（平板能进 fastboot 时，比 SPFT 快 10 倍）
- fastboot 不可用（黑屏重启循环）→ **SPFT**：脚本 `/run/media/tc191/data/lenovoPadROMToolkit/roms/TB335FC_ZUXOS_1.5.10.233_Tool/TB335FC_ZUXOS_1.5.10.233_Tool/刷vendor_boot.sh`
  - scatter 用 `vendor_boot_only_full_scatter.xml`，非 vendor_boot 分区 `file_name=NONE` + `is_download=false`
  - SPFT：`/opt/spflashtool/SPFlashToolV6`（`LD_LIBRARY_PATH=/opt/spflashtool QT_QPA_PLATFORM=offscreen`），**命令行 timeout 要长**（super 8.8G 需 10-20 分钟）
  - 救回后回正常系统，super/userdata 不动
- 组合键：进 TWRP = 音量上 + 电源；强制关机 = 长按电源 10s（平板按键由用户手动做）

### 5.4 日志

```bash
# Fox recovery 里：挂 metadata → 拉 logkmsg
mount /dev/block/by-name/metadata /metadata
adb pull /metadata/logkmsg.log* ./tmp/logs/
# 或一键：scripts/pull_logs.sh
```

- `logkmsg.rc` 写 `/metadata/logkmsg.log`（2MB×2 轮转）；多轮重启会累积多个 boot 段在同一文件，判断版本看 FATAL 计数 + 时间轴
- 日志已滤 BootAnimation / ged-swd / composer / hwcomposer / WifiThreadRunner（v78/v83 滤波）

### 5.5 往平板里塞文件 / 装软件

**★ 首选（2026-09-27 起）：无线 adb** —— WiFi 修好后不用再绕 recovery：

```bash
adb connect <平板IP>     # 平板 WiFi 的 IP；adbd 直接听着 5555（来源未查明，实测可用）
adb install Xime.apk                # 装 APK 就这一条
adb push x.apk /sdcard/Download/    # /sdcard = /data/media/0
adb shell / adb logcat / adb pull … # 系统里跑命令、拉日志
```

一次性配对（做一次就长期有效；配对信息存在平板 + 本机 `~/.android/adbkey`）：平板 **设置 → 系统 →
开发者选项 → 无线调试 → 使用配对码配对设备** → 把屏幕上的 **配对码** 和 **IP:端口** 念出来 →
本机 `adb pair <IP:端口> <配对码>` → 之后 `adb connect <IP:5555>`。若 5555 连不上（adbd 没开 TCP），
连接端口用 mDNS 查：`avahi-browse -r -t _adb-tls-connect._tcp | grep -E "address|port"`（2026-09-27 实测
得到 `<平板IP>:40355`），再 `adb connect`。

**备用：Fox recovery（USB）** —— 无线不可用时（刚刷完、WiFi 还没连、或系统挂了）。USB gadget 坏
（A16 blob 不匹配）→ 系统里没 USB adb；`/data` 未加密（2026-09-25 实测），Fox 能挂能读：

```bash
# 平板进 Fox（fastboot reboot recovery）后：
adb push x.apk /sdcard/Download/     # /sdcard = /data/media/0，明文可读
adb push x.apk /data/local/tmp/      # 系统起来后 app 也能读到
adb pull /sdcard/Download/pic.jpg .  # 反向捞文件
```

装 APK 的三条路（按可靠性排序）：

1. **编进 super（最稳，适合“预装”）**：APK 作为 prebuilt 加进设备树 `PRODUCT_PACKAGES`（或
   `PRODUCT_COPY_FILES` 拷到 `/system/preinstall/`）→ 重编 bacon + 刷 super，刷一次全部到位。
   ⚠️ **预装只做最小集**：输入法 / root 管理器；**不要塞日用软件**（B站/淘宝/夸克这类，2026-09-25 用户明确）。
   ⚠️ 手推 `/system/priv-app/` **不可行**：super 里是只读镜像（`mount | grep erofs` 验），
   就算 Fox 里 remount rw 还要处理 SELinux label，不值当。
   ℹ️ 现成的（已编在系统里，不用加）：`system/priv-app/PackageInstaller` + `system/priv-app/DocumentsUI`
   （「文件」= 系统内装 APK 的入口）。
   ⚠️ 输入法**必须自己装**：`product/app/LatinIME` **只有英文键盘、没有中文引擎**（2026-09-25 用户指出）。
   **选定：Xime（曦码）** —— `ximeiorg/Xime`，GPL-3.0 开源，基于 Rime，**默认内置五笔86/98 + 拼音 + 混输**
   （不用联网下方案），要求 Android 9+ ✓，包名 `com.kingzcheung.xime`，Releases 提供 **arm64-v8a 单 APK** ✓。
   下载：github 直连不通 → 走 `ghfast.top`/`gh-proxy` 镜像或 openapk.net 镜像（KSU APK 也是这么下的）。
   ⚠️ **必须是 universal APK，不能用 XAPK / 分体包**：分体包只能靠 `install-multiple`（系统里没 adb）
   或预装成 `/system/preinstall/<dir>/{base.apk,split_config.*.apk}` 目录；想手动点装就只能用整包。
2. **系统里点开装**：`adb push` 到 `/sdcard/Download/` → 系统里用「文件(Files)」点 APK →
   系统 PackageInstaller 弹装（首次要给「文件」授“安装未知应用”）。
   **⚠️ 待实测**：LOS20 的 Files 能不能直接开 APK；不行就先用路线 1 把一个文件管理器编进去，之后就能自由装。
3. 手机助手 / OTG U 盘：能认 U 盘就最省事（未实测）。

**不能干**：往 `/data/app/` 手推 APK（缺 PackageManager 的安装账本，系统不认）；recovery 里 `pm install`（没有 pm 服务）。

## 6. 已发布开源（均 MIT）

| 项目 | 仓库 | 本机 git 目录 |
|---|---|---|
| TWRP | https://github.com/tc1911/android_device_lenovo_tb335fc_twrp | **本机已删**（兜底 `archive/git-bundles/open-source-repo.bundle`） |
| OrangeFox | https://github.com/tc1911/android_device_lenovo_tb335fc_fox | **本机已删**（兜底 `archive/git-bundles/open-source-repo-fox.bundle`） |

- 状态如实标注：recovery 全功能可用，**/data 解密未解决**
- 本机 git 身份：user=tc1911，email=13999822369@163.com，SSH key `~/.ssh/id_ed25519`；推 GitHub 用本机

## 7. 历史阶段索引（详见 《开发日志》（未随仓库发布） 同名小节）

| 阶段 | 版本 | 结论 |
|---|---|---|
| TWRP 编译/启动/花屏定位 | — | GKI recovery-as-boot 跑通；花屏根因 = kernel/dtb 匹配 |
| TWRP USB adb + 触控修复 | — | 补丁入 `bootable/recovery`（见 TWRP 仓库 `patches/`；本机副本已删） |
| OrangeFox 迁移 + 逻辑分区挂载 | — | 动态分区挂载修复；fstab 单字段 `slotselect,logical,wait` |
| vendor_boot 共存实验 | — | **死路**（单 ramdisk 无法兼服务系统+recovery）；方案与实验清单见 《共存计划》（未随仓库发布） |
| /data 解密排错 | — | **未解决**（keystore2 SIGABRT / binder panic）；稳定版 fox_vb12。⚠️ 2026-09-25 实测：当前 LOS 构建**未启用 FBE**（`/data/unencrypted` 不存在、`/data/media/0` 明文）→ recovery 能直接挂载读写 /data；「未解决」只对**已加密**数据成立 |
| LOS 20 编译成功 | — | 首次 bacon 通过；lunch 被吞会编成 aosp_arm（必查 DeviceProduct） |
| LOS 启动突破 | v30-v34 | TEE verify_model 通过（`ro.product.device=TB335FC`）；转软件 keymint |
| 显示链 | v37-v52 | `TARGET_BOARD_PLATFORM=mt6835` → hwcomposer 找到 |
| SystemServer 进 + NPE 清 | v59-v67 | LineageSettings provider null 根源修复 |
| audio watchdog 三层 | v68-v71 | libbinder 允许线程池 shrink（ProcessState.cpp） |
| product/system_ext 挂载 | v75-v76 | **见到开机动画**（first_stage_mount + canonical 挂载点） |
| gnss 修复 → boot 走完 | v77 | `android.hardware.gnss-service.example`（AOSP 空实现） |
| finishBooting → phase 1000 | v81-v85 | SF "Boot is finished"；只剩 UsbService（usb 三层坑） |
| v86 补丁就绪 + 文档重构 | v86 | UsbService `get(0)` + `USB550 enter/exit` 诊断已改服务器源码（待编译）；AGENTS/BUILD/BOOT_HACKS 重构，原文备份在 `archive/docs_backup_2026-09-23/` |
| USB 四层链收敛 | **v88** | v86 NPE → v87 `UsbHandlerLegacy` legacy sysfs ENOENT + 550 卡 `join()` → v88 `UsbPortAidl.isServicePresent()` 1 行 → **首次开机成功**（`FB: setting sys.boot_completed` / `Boot is finished (18240 ms)` / FATAL=0，2026-09-25 03:10）|
| DBG 自动重启真正可用 | v4→v6 | v4：重启前 `write_reboot_bootloader()` 写 BCB（裸 syscall 不进 fastboot）；v6：`syslog(READ_ALL)` 把内核日志 dump 到 `/metadata/dbg-kernel.log` + KSU/wlan 试装 |
| 内核侧诊断 | — | 厂商 rc 的 `wlan_drv_gen4m_6835.ko` 没装上（手装 rc=0，说明是 rc 里那次 insmod 失效）→ WiFi 卡点；KSU 预编译 LKM 符号不解析（`Unknown symbol …`） |
| 脚本目录 + DBG 补丁重建 | — | 封装脚本集中到 `scripts/`（新增 `build_initboot.sh <秒数>`）；DBG init_boot 补丁源码确认丢失后重建为 `patches/initboot-dbg.diff`，新增 45s/300s 窗口；本地 `tmp/current`+`tmp/debug` 清 ~48G（先被 snapper `home` 小时快照钉住，`df` 不动；删快照 359/360/361 后异步释放，`df /home` 210G→162G）；服务器 `~/superwork` 47G→**7.8G**（只留 v81–v85 + `v76_vb.img` + `pack_super.sh`，删前已用 md5 校对 `super_v77/v85`、`vb_v77` 与 archive 一致） |
