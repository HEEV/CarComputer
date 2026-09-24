#!/bin/sh

# Export compile variables
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-


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
cp arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb ../build/boot/
cd ..

# Copy firmware files
cd firmware
cp boot/{start.elf,fixup.dat} ../build/boot/
cp -r boot/overlays ../build/boot
cd ..
cp device_configs/{cmdline.txt,config.txt} build/boot

# Compile Busybox 
cp compile_configs/busybox_config busybox/.config
cd busybox 
make -j$(nproc)
make INSTALL_PATH=../build/root install
cd ..

# Prep RootFS
cd build/root
mkdir -p etc/init.d proc sys dev tmp var/log 
chmod 777 tmp
sudo mknod dev/console c 5 1
cd ../..

cp device_configs/inittab build/root/etc
cp device_configs/rcS build/root/etc/init.d
cp -r /usr/aarch64-linux-gnu/lib/* build/root/lib

# Create Image 
dd if=/dev/zero of=data.img bs=1M count=512
(
echo o # Create a new empty DOS partition table
echo n # Add a new partition
echo p # Primary partition
echo 1 # Partition number
echo 2048  # First sector
echo +100M  # Last sector
echo t  # Set type
echo c  # Set to FAT32
echo n
echo p 
echo 2
echo 
echo 
echo w # Write changes
) | sudo fdisk ./data.img
sudo losetup -P /dev/loop1 ./data.img  # Mounts as /dev/loopX  
sudo mkfs.vfat /dev/loop1p1  # Boot partition  
sudo mkfs.ext4 /dev/loop1p2
sudo mount /dev/loop1p1 /mnt
sudo cp -r build/boot/* /mnt
sudo umount /mnt
sudo mount /dev/loop1p2 /mnt
sudo cp -r build/root/* /mnt
sudo umount /mnt
sudo losetup -d /dev/loop1

echo "Now go forth and conquer in the name of Jesus Christ our Lord"