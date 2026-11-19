"""Convert the existing PNG logo to a complete macOS icon without changing its design."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid


def png_info(path: Path) -> tuple[int, int, bool]:
    with path.open('rb') as file:
        header = file.read(26)
    if len(header) < 26 or header[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Invalid PNG icon: {path.name}')
    width, height = struct.unpack('>II', header[16:24])
    return width, height, header[25] in (4, 6)


def build_icon(source: Path, output: Path) -> Path:
    width, height, alpha = png_info(source)
    if width != height or width < 1024 or not alpha:
        raise ValueError('App logo must be a square PNG of at least 1024 px with alpha.')
    work = Path(tempfile.mkdtemp(prefix='knowlake-icon-'))
    try:
        iconset = work / 'KnowLake.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                target = iconset / name
                subprocess.run(
                    ['sips', '-z', str(pixels), str(pixels), str(source), '--out', str(target)],
                    check=True, capture_output=True,
                )
                if png_info(target) != (pixels, pixels, True):
                    raise ValueError(f'Icon size or alpha mismatch: {name}')
        result = work / 'KnowLake.icns'
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(result)], check=True)
        data = result.read_bytes()
        if data[:4] != b'icns' or struct.unpack('>I', data[4:8])[0] != len(data):
            raise ValueError('Invalid ICNS output')
        output.parent.mkdir(parents=True, exist_ok=True)
        if not output.exists() or output.read_bytes() != data:
            shutil.copy2(result, output)
        print('App icon verified: 10 representations, 16–1024 px, alpha preserved')
        return output
    finally:
        trash = Path.home() / '.Trash'
        try:
            trash.mkdir(exist_ok=True)
            shutil.move(str(work), str(trash / f'KnowLake-icon-build-{uuid.uuid4().hex[:10]}'))
        except OSError:
            print(f'Icon build intermediates retained at {work}')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=root / 'assets/branding/knowlake-logo.png')
    parser.add_argument('--output', type=Path, default=root / 'assets/branding/KnowLake.icns')
    args = parser.parse_args()
    print(build_icon(args.source, args.output))
