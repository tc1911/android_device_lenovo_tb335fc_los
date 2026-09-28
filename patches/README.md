# patches/ —— 补丁集总目录

> **LOS 官方没有「补丁集」这个东西。** LineageOS 的模型是 **repo/manifest**：每个改动都是某个 git 项目的
> commit（官方设备支持 = 自己的 `device/` + `vendor/` 仓库 + local_manifest）。我们的现状：
> `device/lenovo/sycamore`、`vendor/lenovo/sycamore` 是**手工放进 `~/los20` 的普通目录（不是 git 仓库）**，
> AOSP 源码改动是**脏工作树**。→ 所以「补丁集」只能自己维护，本目录就是它。

## 目录

| 文件 | 覆盖范围 | 状态 | 重放 / 校验（在服务器） |
|---|---|---|---|
| `framework-hacks.diff` | AOSP 源码 10 文件，v65–v88：`frameworks/base`(7) + `frameworks/native`(1, v71 binder) + `lineage-sdk`(2, v65) | ✅ 2026-09-27 核对：与服务器现状**逐行一致**，三个 repo 反向 `apply -R --check` 全 OK | 见下方「framework-hacks.diff 怎么用」 |
| `los-device-hacks.diff` | 设备树/vendor 树 **7 文件**，v89–v92：WiFi 三处（`modules_dlkm/modules.load` / `vendor-blobs.mk` / `init_connectivity.rc`）+ v91 日常包（`device.mk` / `prebuilt/led_daemon.sh` / `prebuilt/xime/Android.bp`）+ v92 音频崩溃修复（`vendor/…/etc/aurisys_config_rv.xml`） | ✅ 正/反向 `patch -p1 --dry-run` 均通过 | `cd ~/los20 && patch -p1 --dry-run < …`（反向 `-p1 -R`） |
| `initboot-dbg.diff` | `system/core`(2) + `bootable/recovery`(1)，DBG **v7**（写 BCB + `syslog(2)` 内核日志 dump） | ✅ 测试用，**用完必须还原** | `scripts/build_initboot.sh <秒数>` 自动打/自动还原 |
| `v86-usbservice.diff` / `v87-usbservice.diff` / `v88-usbport-aidl.diff` | 单步补丁（USB 卡点系列），完整版已并入 `framework-hacks.diff` | 存档（查根因过程用） | — |
| `framework-hacks.diff.bak-upto-v86` / `initboot-dbg.diff.v4-bak` | 旧版备份 | 存档 | — |

## framework-hacks.diff 怎么用（跨 3 个 repo，不能整体 apply）

```bash
P=patches/framework-hacks.diff   # 本机路径；服务器上用 /tmp 中转
cd ~/los20/frameworks/base  && git apply --include='services/*' $P     # 反向校验加 -R --check
cd ~/los20/frameworks/native && git apply --include='libs/*'     $P
cd ~/los20/lineage-sdk      && git apply --include='sdk/*'       $P
```
（`--include` 过滤掉不属于本 repo 的文件；三个 repo 各自 `-R --check` 已实测通过。）

## 不在补丁里的东西

- 二进制：`vendor/lenovo/sycamore/proprietary/lib64/android.hardware.wifi.supplicant-V1-ndk.so`（v89 新增，~500KB，从 A16 vendor 抠出来的）
- 编译产物/镜像：见 `archive/`（`super_vNN.img` / `vb_vNN.img` / `initboot_*.img`），清单 `archive/MANIFEST.md` + `archive/MD5SUMS`
- 设备树里的其它历史 hack（fstab、recovery、sepolicy、`prebuilt/`）：从未做过整树快照，只逐条记在 `docs/BOOT_HACKS.md`

## 想「正规化」的话（还没做）

1. `cd ~/los20/device/lenovo/sycamore && git init && git add -A && git commit`（当前状态即基线）
   → 之后每次改动就是 diffable 的 commit；`vendor/lenovo/sycamore` 同理（blob 大，注意磁盘）
2. AOSP 源码改动 → fork 对应 repo（GitHub），commit 后写 `local_manifest.xml` 覆盖
   → 优点：`repo sync` 不再需要手工重放补丁；缺点：要维护 fork（且 GitHub 直连不通，见 `docs/BUILD.md`）
