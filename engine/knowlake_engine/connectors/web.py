from __future__ import annotations
import json
import urllib.request
from pathlib import Path

UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0 Safari/537.36'

def fetch(url: str, headers: dict | None = None, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={'User-Agent': UA, **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()

def fetch_json(url: str, headers: dict | None = None) -> dict:
    return json.loads(fetch(url, headers))

def save_image(url: str, directory: Path, name: str, referer: str) -> str | None:
    from PIL import Image
    from io import BytesIO
    if url.startswith('//'):
        url = 'https:' + url
    raw = fetch(url, {'Referer': referer})
    with Image.open(BytesIO(raw)) as image:
        extension = '.jpg' if image.format == 'JPEG' else '.' + image.format.lower()
        path = directory / 'assets' / (name + extension)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        # The library preview is a separate derivative; retain the downloaded source verbatim.
        thumbnail = image.copy()
        thumbnail.thumbnail((480, 480))
        thumbnail.convert('RGB').save(path.with_name(path.stem + '-thumb.jpg'), 'JPEG', quality=82)
    return str(path.relative_to(directory))
