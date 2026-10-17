#!/usr/bin/env bash
#
# Regenerate compile_configs/linux_config, trimmed to the hardware the car
# actually has. Run it when the kernel is bumped or the hardware changes; the
# result is committed, so a normal build does not need this.
#
#   ./compile_configs/trim-kernel-config.sh
#
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TOP
readonly KERNEL_SRC="${KERNEL_SRC:-$TOP/linux}"
readonly CONFIG="$TOP/compile_configs/linux_config"
readonly BASE="$TOP/compile_configs/linux_base_config"

[ -f "$KERNEL_SRC/scripts/config" ] || { echo "no kernel source at $KERNEL_SRC" >&2; exit 1; }

export ARCH=arm64

# From the committed base, which this script never writes. Reading its own
# output instead lets the config accumulate sediment: an earlier blunt pass
# turned HID off and no later fix could put it back. The base is the team's
# trimmed config, not upstream's bcm2712_defconfig, which would undo that
# trimming and add 326 drivers back.
cp "$BASE" "$KERNEL_SRC/.config"
cfg() { "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" "$@"; }

# Resolve first, so symbols from a kernel bump are visible to the passes
# below. Otherwise olddefconfig adds them afterwards at their default, which
# with MODULES=n means built in.
make -C "$KERNEL_SRC" olddefconfig

# Subsystems the car has no use for; kconfig drops everything beneath each.
# The board has wifi and bluetooth; the dashboard uses neither. Sound and DRM
# are NOT here: DRM_VC4 depends on SND && SND_SOC because HDMI carries audio,
# and the KMS display path is what lets the output be forced on without a
# monitor attached at boot.
# FB_RPISENSE is here because MODULES=n promoted it and it then fails to link:
# the FB_SYS_FOPS it selects no longer exists in 6.18.
for sym in \
    BT WIRELESS WLAN RFKILL \
    NETFILTER BRIDGE_NETFILTER IP_SET NF_TABLES \
    MD BLK_DEV_DM DM_BUILTIN \
    MEDIA_SUPPORT DVB_CORE \
    INFINIBAND SCSI ATA NVME_CORE \
    HID_LOGITECH HID_ROCCAT HID_WACOM HID_SONY HID_STEAM HID_DEBUG \
    INPUT_JOYSTICK INPUT_TOUCHSCREEN INPUT_TABLET \
    SQUASHFS BTRFS_FS XFS_FS F2FS_FS NFS_FS NFSD SUNRPC CEPH_FS CIFS JFS_FS \
    CAN WIREGUARD VIRTUALIZATION \
    USB_GADGET SPEAKUP COMEDI \
    ANDROID_BINDER_IPC ANDROID \
    BPF_SYSCALL \
    FTRACE \
    PROFILING KPROBES \
    KGDB KGDB_KDB KGDB_SERIAL_CONSOLE \
    LATENCYTOP KALLSYMS_ALL SCHEDSTATS \
    FB_RPISENSE \
    SND_OSSEMUL SND_PCM_OSS SND_SEQUENCER SND_RAWMIDI SND_MIXER_OSS \
    SND_SUPPORT_OLD_API SND_HRTIMER SND_PCM_TIMER SND_DRIVERS SND_USB \
    SND_SPI SND_VIRTIO SND_SOC_I2C_AND_SPI
do
    cfg --disable "$sym"
done

# A panic should cost a reboot, not the rest of the race. Zero meant hang
# forever, and with KGDB above an oops sat at a debugger prompt.
cfg --set-val PANIC_TIMEOUT 10
cfg --enable PANIC_ON_OOPS

# MODULES=n promotes every module that defaults to y, which is how a Pi ends
# up with an Intel 40-gigabit NIC, 38 RTC chips and GPIO_MOCKUP built in.
# Sweep the families where the board has at most one real device.
grep -oE '^CONFIG_(NET_VENDOR|RTC_DRV|HID|SENSORS|GPIO|IIO|BACKLIGHT|LEDS|KEYBOARD|TOUCHSCREEN|JOYSTICK|SND_SOC|SND_USB|SND_SEQ|SND_BCM2835)_[A-Z0-9_]+' \
    "$KERNEL_SRC/.config" | sed 's/^CONFIG_//' |
    while IFS= read -r sym; do
        case "$sym" in
            # Subsystem gates, not device drivers. Sweeping these takes the
            # drivers underneath with them, and the enable pass below cannot
            # put a driver back whose dependency is off.
            HID_SUPPORT|HID_GENERIC|LEDS_CLASS|GPIO_CDEV|GPIO_SYSFS) ;;
            # SND_SOC core and its dmaengine PCM are what DRM_VC4 links
            # against for HDMI audio; only the codec drivers go.
            SND_SOC_GENERIC_DMAENGINE_PCM|SND_SOC_COMPRESS|SND_SOC_TOPOLOGY) ;;
            NET_VENDOR_CADENCE|NET_VENDOR_BROADCOM) ;;
            GPIO_BRCMSTB|GPIO_RASPBERRYPI_EXP|GPIO_REGMAP|GPIO_GENERIC) ;;
            *) cfg --disable "$sym" ;;
        esac
    done

# Build in everything on the boot, display and telemetry path, and restore the
# real devices the sweep above caught. With no initramfs and nothing loading
# modules, =m means absent.
sed -n 's/^CONFIG_\([A-Z0-9_]*\)=y$/\1/p' "$TOP/compile_configs/required_symbols.txt" |
    xargs -n1 "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" --enable

# Fixed hardware, everything needed built in: 1117 modules and 14 MB of image
# that nothing ever loaded.
cfg --disable MODULES

make -C "$KERNEL_SRC" olddefconfig
cp "$KERNEL_SRC/.config" "$CONFIG"

echo "wrote $CONFIG"
echo "  built-in: $(grep -c '=y$' "$CONFIG"), modules: $(grep -c '=m$' "$CONFIG")"
