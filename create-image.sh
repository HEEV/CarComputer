#!/usr/bin/env bash
#
# Build a bootable SD card image for the car computer: Raspberry Pi 5, RPi
# kernel, static busybox userspace, and the CarDisplay app started by init.
#
# Needs no root and no loop devices: both filesystems are built as plain files
# and spliced into a partition table, so this runs the same on a workstation,
# in CI and in an unprivileged container, and a failed run leaves nothing
# mounted behind it.
#
# Usage:
#   ./create-image.sh                 # everything
#   ./create-image.sh app image       # just rebuild the app and repack
#   ./create-image.sh --list          # show the stages
#
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TOP
readonly BUILD="$TOP/build"
readonly BOOT_STAGE="$BUILD/boot"
readonly ROOT_STAGE="$BUILD/root"
readonly IMAGE="$TOP/data.img"
readonly DEPS="$TOP/compile_configs/build-deps.txt"

# Boot holds a 24 MB kernel, a dtb and the overlays, so 48 leaves room for a
# second kernel to bisect against.
readonly BOOT_MIB=48
# Root is sized from its contents plus this slack, so it cannot be outgrown.
readonly ROOT_SLACK_MIB=64
readonly ALIGN_MIB=1

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

readonly KERNEL_DTB=bcm2712-rpi-5-b.dtb
readonly KERNEL_IMAGE=kernel8.img

# Must be case-sensitive; see check_kernel_src. The container points it at a
# volume because a macOS bind mount is not.
KERNEL_SRC="${KERNEL_SRC:-$TOP/linux}"
readonly KERNEL_SRC

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    readonly C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_OFF=$'\033[0m'
else
    readonly C_DIM='' C_RED='' C_GRN='' C_YEL='' C_OFF=''
fi

say()  { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
note() { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# An empty JOBS would turn every make -j"$JOBS" into an unbounded make -j,
# which on a kernel build is an out-of-memory kill rather than a fast build.
jobs_() {
    local n=''
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    case "$n" in
        ''|0|*[!0-9]*) echo 4 ;;
        *) echo "$n" ;;
    esac
}
JOBS="${JOBS:-$(jobs_)}"
case "$JOBS" in
    ''|*[!0-9]*|0) die "JOBS must be a positive integer, got \"$JOBS\"" ;;
esac
readonly JOBS

# rm first and --sparse=never: the kernel Image is sparse, and virtiofs, which
# is what a macOS bind mount is in the container, rejects hole punching.
put() {
    local mode="$1" src="$2" dst="$3"
    [ -d "$dst" ] && dst="${dst%/}/${src##*/}"
    rm -f "$dst"
    cp --sparse=never "$src" "$dst"
    chmod "$mode" "$dst"
}

# ------------------------------------------------------------- preflight ----

# Checked up front, because finding out forty minutes into a kernel build
# that mcopy is missing is how people stop running the build at all.
check_tools() {
    local missing=() t
    for t in git make cmake ninja dd truncate find cmp file awk sed \
             "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}g++" \
             mkfs.vfat mcopy mmd mdir sfdisk e2fsck debugfs; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done

    # mke2fs -d landed in e2fsprogs 1.43. Probe the capability, not a version,
    # and capture first: mke2fs exits nonzero printing usage, which pipefail
    # would read as the check itself failing.
    if command -v mke2fs >/dev/null 2>&1; then
        local mke2fs_usage
        mke2fs_usage="$(mke2fs -h 2>&1 || true)"
        case "$mke2fs_usage" in
            *"-d root-directory"*) ;;
            *) missing+=("mke2fs (too old for -d, need e2fsprogs >= 1.43)") ;;
        esac
    else
        missing+=(mke2fs)
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        printf '%serror:%s missing build tools:\n' "$C_RED" "$C_OFF" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        printf '\nOn Debian or Ubuntu:\n  sudo apt install %s\n' \
            "$(sed 's/#.*//' "$DEPS" | tr '\n' ' ' | tr -s ' ')" >&2
        printf '  plus crossbuild-essential-arm64 on an x86 host.\n' >&2
        printf '\nNot on Linux? The container has all of it pinned:\n  ./build-in-docker.sh\n' >&2
        exit 1
    fi

    command -v fakeroot >/dev/null 2>&1 || warn \
        "fakeroot not found; rootfs files will be owned by $(id -un) instead of root"
}

# A submodule that was never checked out is an empty directory, and an empty
# directory is exactly what several of the steps below would happily build
# nothing out of. CarDisplay in particular degrades silently: with SensorHub
# and BmsHub absent it configures fine and produces a demo-only binary, which
# then boots on the car and shows made-up numbers.
check_submodules() {
    local need_init=()
    local -A probe=(
        [CarDisplay]=CMakeLists.txt
        [CarDisplay/lvgl]=CMakeLists.txt
        [SensorHub]=CMakeLists.txt
        [BmsHub]=CMakeLists.txt
        [busybox]=Makefile
    )

    local path
    for path in "${!probe[@]}"; do
        [ -f "$TOP/$path/${probe[$path]}" ] || need_init+=("$path")
    done

    if [ ${#need_init[@]} -ne 0 ]; then
        say "fetching submodules: ${need_init[*]}"
        git -C "$TOP" submodule update --init --depth 1 --recursive "${need_init[@]}"
        for path in "${!probe[@]}"; do
            [ -f "$TOP/$path/${probe[$path]}" ] ||
                die "submodule $path still looks empty after a fetch"
        done
    fi
}

# Does this directory's filesystem tell Foo and foo apart? Dies rather than
# guessing if it cannot find out, since "probe failed" and "case-insensitive"
# want very different messages.
fs_is_case_sensitive() {
    local dir="$1" probe rc=0
    probe="$(mktemp -d "${dir%/}/.case-probe.XXXXXX")" ||
        die "cannot create a file in $dir to test it; is it writable?"
    : > "$probe/CaseProbe"
    [ -e "$probe/caseprobe" ] && rc=1
    rm -rf "$probe"
    return "$rc"
}

# The kernel tree holds thirteen pairs of files whose names differ only in
# case. A case-insensitive filesystem keeps one of each, and the build then
# dies half an hour in on a target it can plainly see on disk.
check_kernel_src() {
    [ -d "$KERNEL_SRC" ] || die "no kernel source at $KERNEL_SRC"

    if ! fs_is_case_sensitive "$KERNEL_SRC"; then
        die "$KERNEL_SRC is on a case-insensitive filesystem, which cannot hold
    the Linux source tree: it has files whose names differ only in case, and
    one of each pair silently overwrites the other.

    On macOS, build in the container, which keeps the kernel on its own
    volume:
      ./build-in-docker.sh

    To build on the host anyway, put the source on a case-sensitive volume:
      diskutil apfs addVolume disk3 'Case-sensitive APFS' kernel
      KERNEL_SRC=/Volumes/kernel/linux ./create-image.sh"
    fi

    # The direct symptom, in case the probe above is ever fooled.
    local dirty
    dirty="$(git -C "$KERNEL_SRC" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${dirty:-0}" -gt 0 ]; then
        warn "$dirty files look modified in $KERNEL_SRC.
    If you did not edit the kernel, the checkout is damaged; the usual cause
    is a case-insensitive filesystem. First few:
$(git -C "$KERNEL_SRC" status --porcelain | head -5 | sed 's/^/      /')"
    fi
}

# Put the pinned kernel in KERNEL_SRC, wherever that is. The revision comes
# from the superproject's gitlink, so a container build and a host build
# always agree on which kernel they are building, and an already-checked-out
# submodule satisfies this without a special case.
fetch_kernel_src() {
    local url rev
    url="$(git -C "$TOP" config -f .gitmodules submodule.linux.url)"
    rev="$(git -C "$TOP" ls-tree HEAD linux | awk '{print $3}')"
    [ -n "$url" ] && [ -n "$rev" ] || die "cannot work out which kernel revision to fetch"

    if [ "$(git -C "$KERNEL_SRC" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
        note "kernel source already at ${rev:0:12}"
        return 0
    fi

    say "fetching kernel ${rev:0:12} into $KERNEL_SRC"
    mkdir -p "$KERNEL_SRC"
    git -C "$KERNEL_SRC" rev-parse --git-dir >/dev/null 2>&1 ||
        git -C "$KERNEL_SRC" init --quiet
    git -C "$KERNEL_SRC" fetch --depth 1 --quiet "$url" "$rev"
    git -C "$KERNEL_SRC" checkout --quiet --force FETCH_HEAD
}

# ---------------------------------------------------------------- stages ----

stage_kernel() {
    say "kernel"
    mkdir -p "$BOOT_STAGE" "$ROOT_STAGE"
    fetch_kernel_src
    check_kernel_src

    # Compare before copying so that a rerun with an unchanged config does not
    # bump the mtime and send kbuild off to rebuild the world.
    if ! cmp -s "$TOP/compile_configs/linux_config" "$KERNEL_SRC/.config"; then
        cp "$TOP/compile_configs/linux_config" "$KERNEL_SRC/.config"
    fi

    make -C "$KERNEL_SRC" olddefconfig
    check_kernel_config

    # No modules at all: the hardware is fixed, everything needed is built in,
    # and a module nothing loads is a driver that silently does not exist.
    make -C "$KERNEL_SRC" -j"$JOBS" Image dtbs

    put 644 "$KERNEL_SRC/arch/arm64/boot/Image" "$BOOT_STAGE/$KERNEL_IMAGE"
    put 644 "$KERNEL_SRC/arch/arm64/boot/dts/broadcom/$KERNEL_DTB" "$BOOT_STAGE"

    # Overlays come from the kernel tree, so they cannot be a version behind
    # the kernel that loads them. This is also why the firmware submodule is
    # not needed: a Pi 5 keeps its bootloader in EEPROM.
    local overlays="$KERNEL_SRC/arch/arm64/boot/dts/overlays"
    if [ -d "$overlays" ]; then
        mkdir -p "$BOOT_STAGE/overlays"
        local dtbo
        for dtbo in "$overlays"/*.dtbo; do
            [ -e "$dtbo" ] || break
            put 644 "$dtbo" "$BOOT_STAGE/overlays"
        done
        [ -f "$overlays/README" ] && put 644 "$overlays/README" "$BOOT_STAGE/overlays"
    fi

    put 644 "$TOP/device_configs/cmdline.txt" "$BOOT_STAGE"
    put 644 "$TOP/device_configs/config.txt" "$BOOT_STAGE"

    note "kernel $(du -h "$BOOT_STAGE/$KERNEL_IMAGE" | cut -f1), no modules"
}

# The assertion lines from required_symbols.txt: either CONFIG_X=y or the
# "# CONFIG_X is not set" spelling kconfig uses, both matched literally
# against .config so that negatives are checked as strictly as positives.
required_symbols() {
    grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' \
        "$TOP/compile_configs/required_symbols.txt"
}

# A trimmed config is only safe to keep trimming if something checks that the
# drivers on the boot, display and telemetry path survived it. With no
# initramfs and nothing loading modules, a symbol that slipped from y to m or
# n is a board that does not come up, and the symptom shows up on the car.
check_kernel_config() {
    local required="$TOP/compile_configs/required_symbols.txt"
    local missing
    missing="$(required_symbols | grep -Fxv -f "$KERNEL_SRC/.config" || true)"

    if [ -n "$missing" ]; then
        printf '%serror:%s the kernel config lost drivers this board needs:\n' \
            "$C_RED" "$C_OFF" >&2
        printf '%s\n' "$missing" | sed 's/^/  - /' >&2
        printf '\nSee %s.\n' "${required#"$TOP"/}" >&2
        exit 1
    fi
    note "$(grep -c '=y$' "$KERNEL_SRC/.config") symbols built in, $(grep -c '=m$' "$KERNEL_SRC/.config") modules"
}

stage_busybox() {
    say "busybox"
    mkdir -p "$ROOT_STAGE"

    if ! cmp -s "$TOP/compile_configs/busybox_config" "$TOP/busybox/.config"; then
        cp "$TOP/compile_configs/busybox_config" "$TOP/busybox/.config"
    fi

    # Busybox's kconfig has no olddefconfig, and its silentoldconfig, which is
    # where plain `make` lands, refuses to run without a terminal. So the old
    # build only completed with a human there to answer prompts. Empty lines
    # take every default; the process substitution keeps `yes` taking SIGPIPE
    # from becoming the build's exit status.
    local oldconfig_log="$BUILD/busybox-oldconfig.log"
    if ! make -C "$TOP/busybox" oldconfig < <(yes '') > "$oldconfig_log" 2>&1; then
        tail -20 "$oldconfig_log" >&2
        die "busybox oldconfig failed; full output in $oldconfig_log"
    fi

    local new_syms
    new_syms="$(grep -c '(NEW)' "$oldconfig_log" || true)"
    if [ "${new_syms:-0}" -gt 0 ]; then
        warn "$new_syms busybox symbols are newer than compile_configs/busybox_config and took their defaults.
    Details in $oldconfig_log. To adopt them deliberately:
      cp busybox/.config compile_configs/busybox_config"
    fi

    make -C "$TOP/busybox" -j"$JOBS"

    # The variable is CONFIG_PREFIX. The old script passed INSTALL_PATH, which
    # busybox ignores; it only landed in the right place because the checked-in
    # config happened to carry the same value.
    make -C "$TOP/busybox" CONFIG_PREFIX="$ROOT_STAGE" install

    file "$TOP/busybox/busybox" 2>/dev/null | grep -q 'statically linked' ||
        warn "busybox is not static; the rootfs ships no shared libraries"
}

stage_rootfs() {
    say "rootfs"
    mkdir -p "$ROOT_STAGE"/{etc/init.d,proc,sys,dev,tmp,var/log/dash,run,mnt,boot}

    # 1777, not 777: without the sticky bit anyone can unlink anyone's
    # temporary files. Harmless on a single-user car, free to get right.
    chmod 1777 "$ROOT_STAGE/tmp"

    put 644 "$TOP/device_configs/inittab" "$ROOT_STAGE/etc/inittab"
    put 755 "$TOP/device_configs/rcS" "$ROOT_STAGE/etc/init.d/rcS"
    put 644 "$TOP/device_configs/fstab" "$ROOT_STAGE/etc/fstab"
    put 644 "$TOP/device_configs/svlogd-config" "$ROOT_STAGE/var/log/dash/config"

    mkdir -p "$ROOT_STAGE/etc/service/dash/log"
    put 755 "$TOP/device_configs/service/dash/run" "$ROOT_STAGE/etc/service/dash/run"
    put 755 "$TOP/device_configs/service/dash/log/run" "$ROOT_STAGE/etc/service/dash/log/run"

    printf 'carcomputer\n' > "$ROOT_STAGE/etc/hostname"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ROOT_STAGE/etc/passwd"
    printf 'root:x:0:\n' > "$ROOT_STAGE/etc/group"
    mkdir -p "$ROOT_STAGE/root"

    # Every applet init and the service scripts name. A missing one shows up
    # as a dashboard that never starts, or one that keeps no log.
    local applet
    for applet in runsvdir runsv svlogd mount hostname sh; do
        [ -n "$(find "$ROOT_STAGE" -maxdepth 3 \( -type f -o -type l \) \
                -name "$applet" -print -quit)" ] ||
            die "busybox has no $applet applet, but the boot scripts call it"
    done
}

stage_app() {
    say "app"
    local src="$TOP/CarDisplay"
    local out="$BUILD/app"

    # Point the app's build at the sibling checkouts explicitly. Left to its
    # own search it falls back to a demo-data build when they are missing,
    # which is the right call for a laptop simulator and the wrong one for an
    # image that goes in the car.
    cmake -S "$src" -B "$out" -GNinja \
        -DCMAKE_TOOLCHAIN_FILE="$TOP/compile_configs/aarch64.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCD_SENSORHUB_PATH="$TOP/SensorHub" \
        -DCD_BMSHUB_PATH="$TOP/BmsHub" \
        -DSH_BUILD_TESTS=OFF -DSH_BUILD_MONITOR=OFF \
        -DJBD_BUILD_TESTS=OFF -DJBD_BUILD_MONITOR=OFF

    cmake --build "$out" -j"$JOBS"

    # EXECUTABLE_OUTPUT_PATH in CarDisplay points back into its own source
    # tree, so the binary lands there rather than in the build directory.
    local bin="$src/bin/main"
    [ -f "$bin" ] || die "expected the app at $bin but it is not there"

    local kind
    kind="$(file -b "$bin")"
    case "$kind" in
        *aarch64*) ;;
        *) die "app is not an aarch64 binary: $kind" ;;
    esac
    # Fatal, not a warning: the rootfs ships no shared libraries, so a dynamic
    # binary here boots to a "no such file or directory" that really means the
    # loader is missing. Pass -DCARCOMPUTER_STATIC=OFF if you mean it.
    case "$kind" in
        *"statically linked"*) ;;
        *) die "app is dynamically linked, but the rootfs has no shared libraries: $kind" ;;
    esac

    put 755 "$bin" "$ROOT_STAGE/main"
    note "app $(du -h "$ROOT_STAGE/main" | cut -f1), $kind"
}

# --------------------------------------------------------------- imaging ----

# Build the two filesystems as files and splice them into a partition table.
# Doing it this way is what buys us a root-free, loop-free, reentrant build.
stage_image() {
    say "image"
    [ -f "$BOOT_STAGE/$KERNEL_IMAGE" ] || die "no kernel staged; run the kernel stage first"
    [ -x "$ROOT_STAGE/bin/busybox" ] || die "no busybox staged; run the busybox stage first"

    local work="$BUILD/image"
    rm -rf "$work"
    mkdir -p "$work"

    local root_content_mib root_mib total_mib
    root_content_mib="$(du -sm "$ROOT_STAGE" | cut -f1)"
    root_mib=$(( root_content_mib + ROOT_SLACK_MIB ))
    total_mib=$(( ALIGN_MIB + BOOT_MIB + root_mib ))
    note "root content ${root_content_mib}M, root partition ${root_mib}M, image ${total_mib}M"

    say "  boot filesystem (fat32)"
    local bootfs="$work/boot.img"
    # 512 reserved directory entries and a volume label the firmware is happy
    # with. mkfs.vfat on a plain file needs the block count spelled out.
    mkfs.vfat -F 32 -n BOOT -C "$bootfs" $(( BOOT_MIB * 1024 )) >/dev/null
    # mcopy -s copies directories, but only if the destination exists, and a
    # fresh filesystem has no overlays/ yet.
    ( cd "$BOOT_STAGE"
      shopt -s nullglob
      local entry
      for entry in *; do
          if [ -d "$entry" ]; then
              mmd -i "$bootfs" "::/$entry"
              mcopy -i "$bootfs" -s "$entry"/* "::/$entry/"
          else
              mcopy -i "$bootfs" "$entry" "::/"
          fi
      done )

    say "  root filesystem (ext4)"
    local rootfs="$work/root.img"
    # fakeroot so that mke2fs -d records the staged tree as root:root without
    # this script needing real privileges. Buildroot does the same.
    #
    # The journal stays on: a car gets its power cut, and replaying a log beats
    # coming up needing a manual fsck.
    local -a fakeroot=()
    command -v fakeroot >/dev/null 2>&1 && fakeroot=(fakeroot --)
    "${fakeroot[@]}" mke2fs -q -t ext4 -L rootfs \
        -d "$ROOT_STAGE" \
        -E root_owner=0:0 \
        -O has_journal \
        "$rootfs" "${root_mib}M"
    verify_rootfs "$rootfs"

    say "  partition table"
    rm -f "$IMAGE"
    truncate -s "${total_mib}M" "$IMAGE"
    sfdisk --quiet --label dos "$IMAGE" <<EOF
label: dos
unit: sectors
start=$(( ALIGN_MIB * 2048 )), size=$(( BOOT_MIB * 2048 )), type=c, bootable
start=$(( (ALIGN_MIB + BOOT_MIB) * 2048 )), size=$(( root_mib * 2048 )), type=83
EOF

    dd if="$bootfs" of="$IMAGE" bs=1M seek="$ALIGN_MIB" conv=notrunc status=none
    dd if="$rootfs" of="$IMAGE" bs=1M seek=$(( ALIGN_MIB + BOOT_MIB )) conv=notrunc status=none

    verify_image "$bootfs" "$rootfs"
    rm -rf "$work"

    say "wrote $IMAGE ($(du -h "$IMAGE" | cut -f1) on disk, ${total_mib}M apparent)"
    cat <<EOF

To flash it, with the card's device in place of diskN or sdX:

  macOS:  diskutil unmountDisk /dev/diskN
          sudo dd if=$IMAGE of=/dev/rdiskN bs=4m status=progress
  Linux:  sudo dd if=$IMAGE of=/dev/sdX bs=4M conv=fsync status=progress
EOF
}

# Is the filesystem itself right? Checked on the bare filesystem file, where
# e2fsck and debugfs can reach it without an offset.
verify_rootfs() {
    local fs="$1"
    e2fsck -fn "$fs" >/dev/null || die "the root filesystem does not pass fsck"
    debugfs -R "stat /main" "$fs" 2>/dev/null | grep -q 'User: *0' ||
        die "/main is not owned by root; is fakeroot working?"
    debugfs -R "stat /etc/init.d/rcS" "$fs" 2>/dev/null | grep -q 'Mode: *0755' ||
        die "/etc/init.d/rcS is not executable"
}

# Did the assembly put them where the partition table says? An image whose
# root starts a mebibyte from where its table claims looks perfect right up
# until it does not boot, so compare bytes rather than trust the arithmetic.
verify_image() {
    say "  verifying"
    local bootfs="$1" rootfs="$2"

    # The trailing newline matters: read returns nonzero at EOF without one,
    # and under set -e that kills the build with no message at all.
    local boot_start root_start
    read -r boot_start root_start < <(
        sfdisk --json "$IMAGE" | grep -oE '"start":[[:space:]]*[0-9]+' |
            grep -oE '[0-9]+' | tr '\n' ' '
        echo
    )
    [ -n "$boot_start" ] && [ -n "$root_start" ] ||
        die "could not read the partition table back out of $IMAGE"
    [ "$boot_start" = "$(( ALIGN_MIB * 2048 ))" ] ||
        die "boot partition starts at sector $boot_start, not $(( ALIGN_MIB * 2048 ))"
    [ "$root_start" = "$(( (ALIGN_MIB + BOOT_MIB) * 2048 ))" ] ||
        die "root partition starts at sector $root_start, not $(( (ALIGN_MIB + BOOT_MIB) * 2048 ))"

    cmp -s -n "$(stat -c %s "$bootfs")" "$bootfs" <(dd if="$IMAGE" bs=1M skip="$ALIGN_MIB" status=none) ||
        die "the boot filesystem is not byte-identical at its partition offset"
    cmp -s -n "$(stat -c %s "$rootfs")" "$rootfs" <(dd if="$IMAGE" bs=1M skip=$(( ALIGN_MIB + BOOT_MIB )) status=none) ||
        die "the root filesystem is not byte-identical at its partition offset"

    # And read the boot partition the way the firmware will, through the table.
    local f
    for f in config.txt cmdline.txt "$KERNEL_IMAGE" "$KERNEL_DTB"; do
        mdir -i "$IMAGE@@$(( ALIGN_MIB * 1024 * 1024 ))" "::/$f" >/dev/null 2>&1 ||
            die "$f is not readable from the boot partition of the finished image"
    done

    note "both partitions byte-exact at their table offsets, boot readable through it"
}

# ------------------------------------------------------------------ main ----

readonly ALL_STAGES=(kernel busybox rootfs app image)

usage() {
    cat <<EOF
usage: ${0##*/} [stage ...]

Stages, in order: ${ALL_STAGES[*]}
With no arguments all of them run.

  --list          list the stages and exit
  --clean         remove build/ and data.img, then exit
  -h, --help      this

environment:
  JOBS            parallel jobs (default $JOBS)
  CROSS_COMPILE   toolchain prefix, empty to use the native compiler
                  (currently "$CROSS_COMPILE")
EOF
}

main() {
    local -a asked=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; return 0 ;;
            --list) printf '%s\n' "${ALL_STAGES[@]}"; return 0 ;;
            --clean) say "removing $BUILD and $IMAGE"; rm -rf "$BUILD" "$IMAGE"; return 0 ;;
            -*) die "unknown option $1 (try --help)" ;;
            *)
                case " ${ALL_STAGES[*]} " in
                    *" $1 "*) asked+=("$1"); shift ;;
                    *) die "unknown stage $1 (try --list)" ;;
                esac
                ;;
        esac
    done

    # Run in dependency order whatever order they were asked for. rootfs needs
    # the directories busybox installed, app needs rootfs, image needs both, so
    # honouring the argument order would just be a way to fail confusingly.
    local -a stages=()
    local s
    for s in "${ALL_STAGES[@]}"; do
        if [ ${#asked[@]} -eq 0 ] || [[ " ${asked[*]} " == *" $s "* ]]; then
            stages+=("$s")
        fi
    done

    check_tools
    check_submodules
    mkdir -p "$BUILD" "$BOOT_STAGE" "$ROOT_STAGE"

    for s in "${stages[@]}"; do "stage_$s"; done

    say "Now go forth and conquer in the name of Jesus Christ our Lord!"
}

main "$@"
