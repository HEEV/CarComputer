# CarComputer

SD card image for the car's dashboard: a Raspberry Pi 5 running a trimmed
Linux kernel, a static busybox userspace, and
[CarDisplay](https://github.com/HEEV/CarDisplay) started by init.

## Build

```bash
git clone --recursive --depth 1 https://github.com/HEEV/CarComputer.git
cd CarComputer
./create-image.sh          # Linux
./build-in-docker.sh       # macOS, or anywhere without the Linux tooling
```

The kernel takes a while, so rebuild one piece at a time while iterating:

```bash
./create-image.sh app image     # just the app, then repack
./create-image.sh --list        # kernel busybox rootfs app image
./create-image.sh --clean
```

### Dependencies on Linux

```bash
sudo apt install $(sed 's/#.*//' compile_configs/build-deps.txt)
sudo apt install crossbuild-essential-arm64   # x86 hosts only
```
