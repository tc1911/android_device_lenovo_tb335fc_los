# LineageOS product config for Lenovo TB335FC (sycamore / MT6835)
DEVICE_PATH := device/lenovo/sycamore

# 纯 64 位设备：必须继承 core_64_bit.mk（设 ro.zygote=zygote64，否则默认 zygote32 起不来）
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_ramdisk.mk)
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

$(call inherit-product, $(DEVICE_PATH)/device.mk)

PRODUCT_DEVICE := sycamore
PRODUCT_NAME := lineage_sycamore
PRODUCT_BRAND := Lenovo
PRODUCT_MODEL := TB335FC
PRODUCT_VENDOR_PROPERTIES += ro.product.model=TB335FC
PRODUCT_VENDOR_PROPERTIES += ro.product.device=TB335FC
PRODUCT_VENDOR_PROPERTIES += ro.product.name=TB335FC_PRC
PRODUCT_MANUFACTURER := LENOVO
PRODUCT_RELEASE_NAME := TB335FC

# A/B
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    dtbo \
    init_boot \
    vendor_boot \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    system \
    system_ext \
    vendor \
    product \
    vendor_dlkm \
    odm_dlkm

# GKI kernel
BOARD_USES_GENERIC_KERNEL_IMAGE := true
TARGET_NO_KERNEL := false
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/Image
BOARD_KERNEL_IMAGE_NAME := Image

# Boot header v4
BOARD_BOOT_HEADER_VERSION := 4
BOARD_VENDOR_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS := --header_version 4 --kernel_offset 0x00008000 --ramdisk_offset 0x26f08000 --dtb_offset 0x7c88000 --tags_offset 0x7c88000

# Dynamic partitions
BOARD_SUPER_PARTITION_SIZE := 11811160064
BOARD_SUPER_PARTITION_GROUPS := lenovo_dynamic_partitions
BOARD_LENOVO_DYNAMIC_PARTITIONS_SIZE := 11800023040
BOARD_LENOVO_DYNAMIC_PARTITIONS_PARTITION_LIST := \
    system \
    system_ext \
    vendor \
    product \
    vendor_dlkm \
    odm_dlkm

# Filesystem
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_METADATAIMAGE_FILE_SYSTEM_TYPE := f2fs
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USES_METADATA_PARTITION := true

# Recovery
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb_dir

# SELinux
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2

# Build super image
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_BUILD_VENDOR_IMAGE := true
PRODUCT_PACKAGES += snapuserd.vendor_ramdisk
