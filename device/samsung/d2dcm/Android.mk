# Only descend into this tree when we are actually building d2dcm, so that
# checking out this repo alongside other device trees costs nothing.
ifneq ($(filter d2dcm,$(TARGET_DEVICE)),)
include $(call all-makefiles-under,$(call my-dir))
endif
