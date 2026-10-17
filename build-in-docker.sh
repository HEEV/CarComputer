#!/usr/bin/env bash
#
# Run the image build inside the container from the Dockerfile next door.
# This is the path for anyone not on Linux: macOS has no ext4 tools, no
# aarch64 Linux toolchain, and a case-insensitive filesystem the kernel tree
# does not survive.
#
# Arguments are handed straight to create-image.sh, so
#   ./build-in-docker.sh app image
# does what you would expect, and
#   ./build-in-docker.sh --shell
# drops you in the container to poke around.
#
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TOP
readonly TAG=carcomputer-build

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

DOCKER="${DOCKER:-}"
if [ -z "$DOCKER" ]; then
    for candidate in docker podman nerdctl; do
        command -v "$candidate" >/dev/null 2>&1 && { DOCKER="$candidate"; break; }
    done
fi
[ -n "$DOCKER" ] || die "no docker, podman or nerdctl on PATH"

"$DOCKER" info >/dev/null 2>&1 || die "$DOCKER is installed but its daemon is not responding.
On macOS with OrbStack:   open -a OrbStack
On macOS with Docker:     open -a Docker"

# Docker skips the build when the Dockerfile has not changed, so there is no
# reason to make the caller remember a separate step.
"$DOCKER" build -t "$TAG" "$TOP"

# A container writing as root leaves a build/ the host user cannot delete.
# macOS runtimes already translate ownership on the mount; Linux does not.
declare -a user_args=()
if [ "$(uname -s)" = "Linux" ]; then
    user_args=(--user "$(id -u):$(id -g)")
fi

# The kernel lives in a volume, not the bind mount, and that is the whole
# reason this wrapper exists rather than being a convenience: the Linux tree
# has files differing only in case, which a macOS bind mount cannot hold. A
# named volume is also ext4 inside the VM, so an interrupted kernel build
# resumes instead of starting over.
readonly KERNEL_VOLUME=carcomputer-kernel
"$DOCKER" volume inspect "$KERNEL_VOLUME" >/dev/null 2>&1 ||
    "$DOCKER" volume create "$KERNEL_VOLUME" >/dev/null

declare -a run_args=(
    --rm
    -v "$TOP:/src"
    -v "$KERNEL_VOLUME:/kernel"
    -e KERNEL_SRC=/kernel
    -e "JOBS=${JOBS:-}"
    "${user_args[@]}"
)
if [ -t 0 ] && [ -t 1 ]; then
    run_args+=(-it)
fi

if [ "${1:-}" = "--shell" ]; then
    exec "$DOCKER" run "${run_args[@]}" "$TAG" bash
fi

exec "$DOCKER" run "${run_args[@]}" "$TAG" ./create-image.sh "$@"
