# overlay/

Resource overlays for SC-06D. `device.mk` prepends this directory to
`DEVICE_PACKAGE_OVERLAYS` so that anything here wins over the d2att values
inherited from the unified tree.

It is empty on purpose: nothing is known to differ yet, and a wrong overlay
is worse than none. Add files only once a real difference has been observed
on hardware, mirroring the AOSP path being overridden, e.g.

    overlay/frameworks/base/core/res/res/values/config.xml
    overlay/packages/providers/TelephonyProvider/res/values/config.xml

The CM13-era d2dcm tree carried overlays for exactly those three paths
(frameworks/base core res, TelephonyProvider, and Telephony strings), all
telephony-related. If docomo signalling misbehaves on Pie, that is where the
CM13 tree put the fix and where to look first.
