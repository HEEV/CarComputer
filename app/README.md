# SuperM Computer App Glue

Runs with LVGL and combines all Local projects including:
- Burn Coast Sim
- Car Display 
- SensorHub

LVGL ships drivers for the whole Linux graphics stack, and this port can build
against any of them:

| Backend            | Description                            |
| ------------------ | -------------------------------------- |
| `LV_USE_SDL`       | SDL2 (default) — a desktop window      |
| `LV_USE_WAYLAND`   | Wayland                                |
| `LV_USE_X11`       | X11                                    |
| `LV_USE_GLFW`      | GLFW3 (OpenGL)                         |
| `LV_USE_LINUX_DRM` | DRM/KMS (`/dev/dri/*`)                 |
| `LV_USE_LINUX_FBDEV` | Legacy framebuffer (`/dev/fb*`)      |

Configuration is driven by **Kconfig**, the same system used by the Linux
kernel, so you can pick drivers, features and demos from a menu instead of
editing a header by hand.

### Tweak with menuconfig

Once you have a `.config`, open the interactive menu to enable/disable drivers,
features, fonts and demos:

```bash
menuconfig
```

Save and exit, then rebuild:

```bash
cmake -B build
cmake --build build -j$(nproc)
```

## Backends

This port supports these Linux display and input backend that LVGL provides.
A backend is compiled in when its `CONFIG_LV_USE_*` option is enabled (through
Kconfig, as above). The glue code for each one lives in:

- Displays: [`src/lib/display_backends`](src/lib/display_backends) —
  `sdl`, `wayland`, `x11`, `glfw3`, `drm`, `fbdev`
- Input devices: [`src/lib/indev_backends`](src/lib/indev_backends) — `evdev`

If several backends are enabled at once, pick one at runtime with `-b`:

```bash
./build/bin/lvglsim -b sdl
```

## Cross compilation

Cross compilation is supported with CMake. Edit
`cmake/user_cross_compile_setup.cmake` to point at your toolchain, then:

```bash
cmake -B build -GNinja -DCMAKE_TOOLCHAIN_FILE=./user_cross_compile_setup.cmake
cmake --build build
```

## Environment variables


### Legacy framebuffer (fbdev)

- `LV_LINUX_FBDEV_DEVICE` — override the default (`/dev/fb0`) framebuffer device node.

### DRM/KMS

- `LV_LINUX_DRM_CARD` — override the default (`/dev/dri/card0`) card.