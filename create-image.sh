#!/bin/sh

# Export compile variables
ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-


# Create Build directories
mkdir build
mkdir build/root
mkdir build/boot
mkdir build/app

# Compile Linux Kernel
cp compile_configs/linux_config linux/.config
cd linux
make -j$(nproc) olddefconfig
make -j$(nproc)
make INSTALL_MOD_PATH=../build/root modules_install
cp arch/arm64/boot/Image ../build/boot/kernel8.img 
cd ..