"""Prepare a reusable, signed Python runtime outside the application bundle."""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


RUNTIME_ROOT = Path.home() / "Library/Application Support/KnowLake/Runtime"
MANIFEST = "manifest.json"
EXCLUDED_NAMES = {
    "__pycache__", "test", "tests", "PyObjCTest", "include", "Cython", "pyximport",
    "cython.py", "pip", "setuptools", "pkg_resources", "_distutils_hack",
    "distutils-precedence.pth", "ensurepip",
}
EXCLUDED_DISTRIBUTIONS = {"cython", "pip", "setuptools"}
MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def copy_exclusions(directory: str, names: list[str]) -> set[str]:
    """Filter development payloads while retaining runtime code and licenses."""
    excluded = set()
    for name in names:
        distribution = name.partition("-")[0].lower()
        metadata = name.endswith((".dist-info", ".egg-info"))
        if (name in EXCLUDED_NAMES or name.endswith((".pyc", ".pyo", ".dSYM"))
                or (metadata and distribution in EXCLUDED_DISTRIBUTIONS)):
            excluded.add(name)
    return excluded


def runtime_environment(engine_path: Path) -> dict[str, str]:
    environment = dict(os.environ)
    for key in ("PYTHONHOME", "VIRTUAL_ENV", "FPGEN_MODEL_URL", "FPGEN_NO_INIT"):
        environment.pop(key, None)
    environment.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1",
                       PYTHONPATH=str(engine_path))
    return environment


def source_details(root: Path) -> dict[str, str]:
    python = root / "engine/.venv/bin/python3"
    probe = (
        "import importlib.util,json,platform,sys; print(json.dumps(dict(base=sys.base_prefix,"
        "version=sys.version,architecture=platform.machine(),"
        "stdlib=f'python{sys.version_info.major}.{sys.version_info.minor}',"
        "wechat_browser=importlib.util.find_spec('camoufox') is not None)))"
    )
    details = json.loads(subprocess.check_output([str(python), "-I", "-B", "-c", probe], text=True))
    managed = Path(subprocess.check_output(["uv", "python", "dir"], cwd=root, text=True).strip())
    if not Path(details["base"]).resolve().is_relative_to(managed.resolve()):
        raise RuntimeError("Use scripts/setup.sh to prepare a uv-managed Python runtime")
    return details


def runtime_identity(root: Path, details: dict[str, str], signing_identity: str) -> tuple[str, dict]:
    specification = {
        "schema": 1,
        "privateModules": has_private_modules(root / "engine"),
        "wechatBrowser": details.get("wechat_browser", False),
        "lockSHA256": digest(root / "engine/uv.lock"),
        "pythonVersion": details["version"],
        "architecture": details["architecture"],
        "recipeSHA256": digest(Path(__file__)),
        "modelPreparationSHA256": digest(root / "scripts/prepare_browser_model.py"),
        "signingIdentity": signing_identity,
    }
    key = hashlib.sha256(json.dumps(specification, sort_keys=True).encode()).hexdigest()[:24]
    return f"{details['stdlib']}-{details['architecture']}-{key}", specification


@contextmanager
def runtime_lock(runtime_id: str):
    directory = RUNTIME_ROOT / ".locks"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / f"{runtime_id}.lock").open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def move_to_trash(path: Path) -> Path:
    trash = Path.home() / ".Trash"
    trash.mkdir(exist_ok=True)
    destination = trash / f"KnowLake-runtime-{path.name}-{uuid.uuid4().hex[:8]}"
    shutil.move(str(path), str(destination))
    return destination


def inventory(runtime_path: Path) -> dict:
    entries = {}
    for directory, folders, filenames in os.walk(runtime_path):
        for name in sorted([*folders, *filenames]):
            path = Path(directory) / name
            relative = path.relative_to(runtime_path).as_posix()
            if path.is_symlink():
                entries[relative] = {"symlink": os.readlink(path)}
            elif path.is_file():
                entries[relative] = {"size": path.stat().st_size, "sha256": digest(path)}
    return entries


def macho_files(runtime_path: Path):
    for directory, _, filenames in os.walk(runtime_path):
        for name in sorted(filenames):
            path = Path(directory) / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    yield path


def sign_runtime(runtime_path: Path, signing_identity: str) -> None:
    for path in macho_files(runtime_path):
        subprocess.run(["codesign", "--force", "--sign", signing_identity, str(path)], check=True)


def verify_signatures(runtime_path: Path) -> None:
    for path in macho_files(runtime_path):
        subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)


def has_private_modules(engine_path: Path) -> bool:
    return (engine_path / "knowlake_engine/private_modules.py").is_file()


def smoke_check(runtime_path: Path, engine_path: Path) -> None:
    program = """
from importlib.util import find_spec
import sqlite3, bs4, markdownify, markdown_it, subprocess
from PIL import Image
from knowlake_engine.module_registry import PRIVATE_MODULES

if PRIVATE_MODULES:
    import yt_dlp, httpx, imageio_ffmpeg
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-version'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
if find_spec('camoufox'):
    from AppKit import NSScreen
    from camoufox.fpgen_model import load_fpgen
    load_fpgen().Generator()
print('External engine runtime verified')
"""
    subprocess.run([str(runtime_path / "bin/python3"), "-B", "-c", program],
                   env=runtime_environment(engine_path), check=True, timeout=120)


def validate_runtime(runtime_path: Path, engine_path: Path) -> None:
    """Verify a completed runtime when packaging or installing, never per request."""
    runtime_path = Path(runtime_path)
    manifest = json.loads((runtime_path.parent / MANIFEST).read_text())
    if manifest.get("runtimeID") != runtime_path.parent.name or manifest.get("schema") != 1:
        raise RuntimeError(f"Runtime completion record does not match its directory: {runtime_path}")
    if inventory(runtime_path) != manifest["files"]:
        raise RuntimeError(f"Runtime files changed or are incomplete; preserved without overwriting: {runtime_path}")
    verify_signatures(runtime_path)
    smoke_check(runtime_path, engine_path)
    if inventory(runtime_path) != manifest["files"]:
        raise RuntimeError(f"Runtime validation changed its files: {runtime_path}")


def prepare_runtime(root: Path, signing_identity: str) -> tuple[str, Path]:
    """Build once per locked dependency/runtime recipe and reuse verified builds."""
    root = Path(root)
    details = source_details(root)
    runtime_id, specification = runtime_identity(root, details, signing_identity)
    destination = RUNTIME_ROOT / runtime_id
    runtime_path = destination / "Python"
    engine = root / "engine"
    with runtime_lock(runtime_id):
        if destination.exists():
            manifest = json.loads((destination / MANIFEST).read_text())
            if manifest.get("specification") != specification:
                raise RuntimeError(f"Runtime specification differs; preserved without overwriting: {destination}")
            validate_runtime(runtime_path, engine)
            print(f"Reusing engine runtime: {runtime_id}")
            return runtime_id, runtime_path

        staging = Path(tempfile.mkdtemp(prefix=f".staging-{runtime_id}-", dir=RUNTIME_ROOT))
        unfinished = staging
        try:
            staged_python = staging / "Python"
            shutil.copytree(Path(details["base"]), staged_python, symlinks=True, ignore=copy_exclusions)
            site = engine / ".venv/lib" / details["stdlib"] / "site-packages"
            shutil.copytree(site, staged_python / "lib" / details["stdlib"] / "site-packages",
                            symlinks=True, dirs_exist_ok=True, ignore=copy_exclusions)
            if specification["wechatBrowser"]:
                subprocess.run(
                    [str(staged_python / "bin/python3"), "-B",
                     str(root / "scripts/prepare_browser_model.py"), str(root / ".build/browser-models")],
                    env=runtime_environment(engine), check=True)
            smoke_check(staged_python, engine)
            sign_runtime(staged_python, signing_identity)
            manifest = {"schema": 1, "runtimeID": runtime_id, "specification": specification,
                        "files": inventory(staged_python)}
            (staging / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
            staging.rename(destination)
            unfinished = destination
            validate_runtime(runtime_path, engine)
        except BaseException:
            if unfinished.exists():
                move_to_trash(unfinished)
            raise
    print(f"Prepared engine runtime: {runtime_id}")
    return runtime_id, runtime_path
