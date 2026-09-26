# CarComputer

To clone: 
```bash
git clone --recursive --shallow-submodules --depth 1 https://github.com/HEEV/CarComputer.git
```

To build:
```bash
./create-image.sh
```

Note - if Busybox no longer has a certain commit, use this command to get the newest:
```bash
git submodule update --force --recursive --init --remote
```

We reqiure the aarch64-linux-gnu toolchain to compile everything for the RPI 5, make sure to have that installed, as well as make, cmake, and losetup.