"""PlatformIO pre-build step.

1. Runs `buf generate` when the nanopb output is missing or older than the .proto files.
2. Defines HEXAPOD_FW_VERSION and HEXAPOD_FW_GIT_HASH from git.
"""

import os
import shutil
import subprocess
from pathlib import Path

Import("env")  # noqa: F821 (SCons global)

FIRMWARE = Path(env.subst("$PROJECT_DIR"))  # noqa: F821
REPO = FIRMWARE.parent
PROTO = REPO / "proto"
GENERATED = FIRMWARE / "lib" / "proto" / "hexapod" / "v1"


def find_buf():
    extra = [Path.home() / "go" / "bin", Path.home() / ".local" / "bin"]
    path = os.pathsep.join([os.environ.get("PATH", "")] + [str(p) for p in extra])
    return shutil.which("buf", path=path), path


def generate_proto():
    sources = list(PROTO.glob("hexapod/v1/*.proto")) + list(PROTO.glob("hexapod/v1/*.options"))
    outputs = list(GENERATED.glob("*.pb.[ch]"))
    newest_source = max(p.stat().st_mtime for p in sources)
    if outputs and min(p.stat().st_mtime for p in outputs) >= newest_source:
        return
    buf, path = find_buf()
    if buf is None:
        raise SystemExit("pre_build: `buf` not found (go install github.com/bufbuild/buf/cmd/buf)")
    print("pre_build: buf generate")
    subprocess.run([buf, "generate"], cwd=PROTO, check=True, env={**os.environ, "PATH": path})


def git(*args, default):
    try:
        return subprocess.run(["git", *args], cwd=REPO, check=True, capture_output=True,
                              text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return default


generate_proto()

version = git("describe", "--tags", "--always", "--dirty", default="unknown")
git_hash = git("rev-parse", "HEAD", default="")
env.Append(CPPDEFINES=[  # noqa: F821
    ("HEXAPOD_FW_VERSION", env.StringifyMacro(version)),  # noqa: F821
    ("HEXAPOD_FW_GIT_HASH", env.StringifyMacro(git_hash)),  # noqa: F821
])
