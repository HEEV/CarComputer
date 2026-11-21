#!/bin/sh

# Export compile variables
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PRIMARY=$(pwd)

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
cp -r boot/overlays ../build/boot
cd ..
cp device_configs/{cmdline.txt,config.txt} build/boot

# Compile Busybox 
cp compile_configs/busybox_config busybox/.config
cd busybox 
make -j$(nproc)
make INSTALL_PATH=../build/root install
cd ..

# Compile xCrypt
export PREFIX=$PRIMARY/build/root/
export BUILD=arm64-linux
export HOST=aarch64-linux-gnu
export COMPILER=aarch64-linux-gnu-gcc
git clone https://github.com/besser82/libxcrypt
cd libxcrypt/
./autogen.sh CC=$COMPILER --prefix=$PREFIX
./configure CC=$COMPILER --prefix=$PREFIX --host=$HOST
make -j8 install
cd ..

# Compile DropBear
git clone https://github.com/mkj/dropbear
cd dropbear/
CFLAGS="-I./ -I$PRIMARY/libxcrypt/" LDFLAGS="-L$PRIMARY/libxcrypt/.libs/ -Wl,-rpath,$PRIMARY/libxcrypt/.libs/" CC=$COMPILER ./configure --build=$BUILD --host=$HOST --prefix=$PREFIX --disable-zlib
sed -i.bak '5i #define HAVE_CRYPT 1' src/sysoptions.h
sed -i.bak '5i #define HAVE_SETRESGID 1' src/sysoptions.h
make PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" -j8 install
cd ..

# Prep RootFS
cd build/root
mkdir -p etc/init.d etc/dropbear proc sys dev tmp var/log
chmod 777 tmp
sudo mknod dev/console c 5 1
touch etc/passwd
cd ../..
cp device_configs/inittab build/root/etc
cp device_configs/rcS build/root/etc/init.d
cp device_configs/usbether build/root/etc/init.d
sudo chmod +x build/root/etc/init.d/rcS
sudo chmod +x build/root/etc/init.d/usbether
cp -r /usr/aarch64-linux-gnu/lib/* build/root/lib

# Create SSH passwords
sudo useradd --prefix $PRIMARY/build/root -u 0 -s /bin/sh -M root
sudo passwd --prefix $PRIMARY/build/root root
dropbearkey -t rsa -f $PRIMARY/build/root/etc/dropbear/dropbear_rsa_host_key

# Compile and Copy App
cd CarDisplay
cmake -B build -GNinja -DCMAKE_TOOLCHAIN_FILE=./cmake/cross.cmake
cmake --build build -j$(nproc)
cp bin/main ../build/root
cd ..

# Create Image 
dd if=/dev/zero of=data.img bs=1M count=384
(
echo o # Create a new empty DOS partition table
echo n # Add a new partition
echo p # Primary partition
echo 1 # Partition number
echo 2048  # First sector
echo +50M  # Last sector
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
sudo mkfs.ext4 /dev/loop1p2  # Root partition 
sudo mount /dev/loop1p1 /mnt
sudo cp -r build/boot/* /mnt
sudo umount /mnt
sudo mount /dev/loop1p2 /mnt
sudo cp -r build/root/* /mnt
sudo umount /mnt
sudo losetup -d /dev/loop1

echo "Now go forth and conquer in the name of Jesus Christ our Lord!"