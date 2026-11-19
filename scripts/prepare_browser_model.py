"""Install Camoufox's verified, pinned fingerprint model before signing the app."""
from pathlib import Path
import os
import shutil
import sys


def prepare(cache_root: Path) -> Path:
    # The shipped application always uses Camoufox's checksum-pinned model.
    os.environ.pop("FPGEN_MODEL_URL", None)
    os.environ.pop("FPGEN_NO_INIT", None)
    from camoufox.fpgen_model import PIN, STAMP, ensure_fpgen_model, fpgen_data_dir

    cache = cache_root / PIN["sha256"]
    ensure_fpgen_model(cache)
    destination = fpgen_data_dir()
    destination.mkdir(parents=True, exist_ok=True)
    for name in [*PIN["file_sha256"], STAMP]:
        # The pinned future timestamps also disable fpgen's age-based refresh.
        shutil.copy2(cache / name, destination / name)
    ensure_fpgen_model(destination)
    return cache


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))
    print("Bundled browser fingerprint model prepared and verified")
