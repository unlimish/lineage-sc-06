#
# Product definition for the docomo GALAXY S III (SC-06D).
#

# Inherit device configuration.
$(call inherit-product, device/samsung/d2dcm/device.mk)

# Inherit some common LineageOS stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Stock SC-06D identity. d2om is the stock product name and SC06DOMBMF1 the
# last docomo firmware build (Android 4.1.2, JZO54K). Keeping these lets
# docomo-signed blobs and the RIL see the identity they expect.
PRODUCT_BUILD_PROP_OVERRIDES += \
    PRODUCT_NAME=d2om \
    TARGET_DEVICE=d2dcm \
    PRIVATE_BUILD_DESC="d2om-user 4.1.2 JZO54K SC06DOMBMF1 release-keys"

BUILD_FINGERPRINT := samsung/d2om/d2dcm:4.1.2/JZO54K/SC06DOMBMF1:user/release-keys

# Set those variables here to overwrite the inherited values.
PRODUCT_NAME := lineage_d2dcm
PRODUCT_DEVICE := d2dcm
PRODUCT_BRAND := samsung
PRODUCT_MANUFACTURER := samsung
PRODUCT_MODEL := SC-06D
