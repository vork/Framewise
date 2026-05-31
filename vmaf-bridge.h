// Bridging header for the optional bundled-libvmaf build.
//
// Only used when Framewise is compiled with FRAMEWISE_VMAF=1 (see README →
// "Building with VMAF"). build.sh passes this via `-import-objc-header` together
// with the libvmaf include/lib paths; the default build never references it.
#ifndef FRAMEWISE_VMAF_BRIDGE_H
#define FRAMEWISE_VMAF_BRIDGE_H

#include <libvmaf/libvmaf.h>

#endif /* FRAMEWISE_VMAF_BRIDGE_H */
