"""Build a local app bundle and its matching external Python runtime."""
import os
import plistlib
import shutil
import subprocess
import time
import uuid
from pathlib import Path

from build_icon import build_icon
from runtime_support import has_private_modules, prepare_runtime, validate_runtime


ENGINE_FILES = (
    "__init__.py", "__main__.py", "acquisition_support.py", "exporting.py",
    "markdown_source.py", "module_registry.py", "store.py", "worker.py",
    "connectors/__init__.py", "connectors/web.py", "connectors/wechat.py",
    "connectors/wechat_converter.py", "connectors/wechat_parser.py", "connectors/wechat_utils.py",
)
PRIVATE_ENGINE_FILES = (
    "acquisition_cache.py", "bilinote_config.py", "generation.py", "private_modules.py",
    "connectors/bilibili.py", "transcribers/__init__.py", "transcribers/doubao.py",
)
USER_DATA_NAMES = {"config.json", "tasks.json", "library.sqlite3", "library.sqlite3-wal", "library.sqlite3-shm", ".KnowLake"}


def check_no_user_data(directory: Path) -> None:
    for path in directory.rglob("*"):
        if path.name in USER_DATA_NAMES or path.name == ".env" or path.name.startswith(".env."):
            raise RuntimeError(f"User data is not permitted in the build: {path.relative_to(directory)}")


def copy_engine(source: Path, target: Path, private: bool) -> None:
    files = ENGINE_FILES + (PRIVATE_ENGINE_FILES if private else ())
    for relative in files:
        package = Path("knowlake_engine") / relative
        output = target / package
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / package, output)
    shutil.copy2(source / "THIRD_PARTY.md", target)
    licenses = target / "licenses"
    licenses.mkdir()
    shutil.copy2(source / "licenses/wechat-to-md-MIT.txt", licenses)
    if private:
        shutil.copy2(source / "THIRD_PARTY_PRIVATE.md", target)
        shutil.copy2(source / "licenses/BiliNote-MIT.txt", licenses)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    engine = root / "engine"
    private = has_private_modules(engine)
    icon = build_icon(root / "assets/branding/knowlake-logo.png", root / "assets/branding/KnowLake.icns")
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())
    reader_bundle = binary_dir / "KnowLake_KnowLake.bundle"
    check_no_user_data(reader_bundle)
    identity = os.environ.get("KNOWLAKE_SIGN_IDENTITY", "-")
    runtime_id, runtime = prepare_runtime(root, identity)
    check_no_user_data(runtime)
    app = root / ".dist/KnowLake.app"
    if app.exists():
        trash = Path.home() / ".Trash" / (
            "KnowLake-build-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".app")
        trash.parent.mkdir(exist_ok=True)
        shutil.move(str(app), str(trash))

    mac = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    mac.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(icon, resources / "KnowLake.icns")
    executable = mac / "KnowLake"
    shutil.copy2(binary_dir / "KnowLake", executable)
    # Strip debug symbols, which contain absolute build paths, before signing.
    subprocess.run(["/usr/bin/strip", "-S", str(executable)], check=True)
    if os.fsencode(Path.home()) + b"/" in executable.read_bytes():
        raise RuntimeError("The release executable contains a local home directory path")
    shutil.copytree(reader_bundle, resources / reader_bundle.name)
    shutil.copy2(root / "LICENSE", resources)
    copy_engine(engine, resources / "engine", private)
    check_no_user_data(app)

    info = {
        "CFBundleIdentifier": "app.knowlake.desktop" if private else "app.knowlake.public",
        "CFBundleName": "KnowLake", "CFBundleDisplayName": "KnowLake", "CFBundleExecutable": "KnowLake",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.5.1", "CFBundleVersion": "10",
        "CFBundleIconFile": "KnowLake.icns", "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True, "KnowLakeRuntimeID": runtime_id,
        "UTExportedTypeDeclarations": [{
            "UTTypeIdentifier": "app.knowlake.library-source",
            "UTTypeDescription": "KnowLake Library Source",
            "UTTypeConformsTo": ["public.data"],
        }],
    }
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    subprocess.run(["codesign", "--force", "--deep", "--sign", identity, str(app)], check=True)
    validate_runtime(runtime, resources / "engine")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
