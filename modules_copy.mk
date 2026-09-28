# vendor_dlkm 分区模块：stock 原版全量（modules_dlkm/，含 mali/GPU 全族）
# ramdisk /lib/modules（recovery/root）只保留早期 203 个基础模块（避免 ramdisk 过大）
SYCA_KO_FILES := $(wildcard $(DEVICE_PATH)/modules_dlkm/*.ko)
PRODUCT_COPY_FILES += $(foreach f,$(SYCA_KO_FILES),$(f):$(TARGET_COPY_OUT_VENDOR_DLKM)/lib/modules/$(notdir $(f)))

PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/modules_dlkm/modules.load:$(TARGET_COPY_OUT_VENDOR_DLKM)/lib/modules/modules.load \
    $(DEVICE_PATH)/modules_dlkm/modules.dep:$(TARGET_COPY_OUT_VENDOR_DLKM)/lib/modules/modules.dep \
    $(DEVICE_PATH)/modules_dlkm/modules.alias:$(TARGET_COPY_OUT_VENDOR_DLKM)/lib/modules/modules.alias \
    $(DEVICE_PATH)/modules_dlkm/modules.softdep:$(TARGET_COPY_OUT_VENDOR_DLKM)/lib/modules/modules.softdep
