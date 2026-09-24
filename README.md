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