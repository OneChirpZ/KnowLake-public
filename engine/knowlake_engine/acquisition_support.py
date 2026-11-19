"""Acquisition progress and recoverable staging cleanup used by source modules."""
import os
import shutil
import uuid
from pathlib import Path


def recycle(path: Path) -> bool:
    """Keep evicted bytes recoverable through the user's Trash."""
    if not path.exists() and not path.is_symlink():
        return True
    trash = Path(os.environ.get('KNOWLAKE_TRASH', str(Path.home() / '.Trash')))
    try:
        trash.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(trash / ('KnowLake-acquisition-' + path.name + '-' + uuid.uuid4().hex)))
        return True
    except OSError:
        return False


def report(callback, message: str, stage: str, status: str = 'started', artifacts=()):
    if getattr(callback, 'structured_progress', False):
        callback(message, stage=stage, status=status, artifacts=list(artifacts))
    else:
        callback(message)
