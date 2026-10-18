"""PlatformIO target `merged`: one flash image at offset 0x0.

    pio run -e esp32dev -t merged   ->  .pio/build/esp32dev/firmware-merged.bin

Bootloader, partition table, boot_app0 and the app are placed at the offsets
PlatformIO itself uses for the board (they differ between ESP32 and ESP32-S3),
so deploy.sh can flash any board with `write-flash 0x0`.
"""

Import("env")  # noqa: F821 (SCons global)

MERGED = "$BUILD_DIR/firmware-merged.bin"


def merge(source, target, env):
    images = [(offset, image) for offset, image in env["FLASH_EXTRA_IMAGES"]]
    images.append((env.get("ESP32_APP_OFFSET", "0x10000"), env.subst("$BUILD_DIR/${PROGNAME}.bin")))
    args = []
    for offset, image in images:
        args += [offset, env.subst(image)]
    cmd = [
        env.subst("$PYTHONEXE"), env.subst("$UPLOADER"),
        "--chip", env.BoardConfig().get("build.mcu"),
        "merge_bin", "-o", env.subst(MERGED),
        "--flash_mode", env.BoardConfig().get("build.flash_mode", "dio"),
        "--flash_size", env.BoardConfig().get("upload.flash_size", "4MB"),
    ] + args
    print("merge_bin:", " ".join(args))
    return env.Execute(env.VerboseAction(" ".join(f'"{c}"' for c in cmd), "Building merged image"))


env.AddCustomTarget(  # noqa: F821
    name="merged",
    dependencies="$BUILD_DIR/${PROGNAME}.bin",
    actions=merge,
    title="Merged image",
    description="Single flash image at 0x0 for deploy.sh",
)
