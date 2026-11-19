from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterator

from .module_registry import canonical_url


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def folder_path(value: str) -> str:
    value = value.strip()
    if not value:
        return ''
    parts = [part.strip() for part in value.split('/')]
    if any(not part or part in ('.', '..') for part in parts):
        raise ValueError('文件夹名称不能为空，也不能使用 . 或 ..')
    return '/'.join(parts)


def folder_ancestors(path: str) -> list[str]:
    parts = path.split('/')
    return [ancestor for index in range(1, len(parts) + 1)
            if (ancestor := '/'.join(parts[:index]))]


@contextlib.contextmanager
def private_output(path: Path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        yield stream


class DuplicateSource(Exception):
    def __init__(self, source: dict, aliases: list[str]):
        super().__init__('资料已存在')
        self.source = source
        self.aliases = aliases


class Store:
    # One indexed aggregate per selected source, inside the page query. Existing
    # libraries need no data migration and artifacts are the source of truth.
    SOURCE_SELECT = """SELECT sources.*, (
        SELECT json_object(
            'artifact_count', COUNT(*),
            'note_count', COALESCE(SUM(kind='markdown'),0),
            'board_count', COALESCE(SUM(kind='html'),0),
            'image_count', COALESCE(SUM(kind='image'),0)
        ) FROM artifacts WHERE source_id=sources.id
    ) AS artifact_stats FROM sources"""
    def __init__(self, root: str | Path):
        self.root = Path(root).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.root / 'library.sqlite3', timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY, url TEXT UNIQUE NOT NULL, title TEXT NOT NULL,
                platform TEXT NOT NULL, created_at TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
                read INTEGER NOT NULL DEFAULT 0, starred INTEGER NOT NULL DEFAULT 0,
                collection TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]',
                image_path TEXT, status TEXT NOT NULL DEFAULT 'ready', version TEXT NOT NULL,
                content_path TEXT NOT NULL, segments_path TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS source_aliases (url TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id));
            CREATE INDEX IF NOT EXISTS sources_created ON sources(created_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS sources_collection ON sources(collection);
            CREATE VIRTUAL TABLE IF NOT EXISTS source_fts USING fts5(source_id UNINDEXED,title,content,tokenize='trigram');
            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id), kind TEXT NOT NULL,
                title TEXT NOT NULL, path TEXT NOT NULL, created_at TEXT NOT NULL, model TEXT, run_id TEXT);
            CREATE INDEX IF NOT EXISTS artifacts_source_kind ON artifacts(source_id,kind);
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, action TEXT NOT NULL, source_id TEXT, status TEXT NOT NULL,
                started_at TEXT NOT NULL, finished_at TEXT, error TEXT, metadata TEXT NOT NULL DEFAULT '{}');
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS folders (name TEXT PRIMARY KEY, created_at TEXT NOT NULL);
            INSERT OR IGNORE INTO folders(name,created_at)
                SELECT collection,MIN(created_at) FROM sources WHERE collection<>'' GROUP BY collection;
            PRAGMA user_version=1;
        ''')
        # Older libraries stored the full collection as a single folder name.
        # Keep those names and fill in their missing parents.
        for row in self.db.execute('SELECT name,created_at FROM folders').fetchall():
            self.db.executemany('INSERT OR IGNORE INTO folders(name,created_at) VALUES(?,?)',
                                [(name, row['created_at']) for name in folder_ancestors(row['name'])])
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    @contextlib.contextmanager
    def lock(self) -> Iterator[None]:
        with (self.root / '.write.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def source(self, row: sqlite3.Row | None) -> dict:
        if row is None:
            raise KeyError('资料不存在')
        data = dict(row)
        stats = data.pop('artifact_stats', None)
        if stats is not None:
            data.update(json.loads(stats))
        data['read'] = bool(data['read'])
        data['starred'] = bool(data['starred'])
        data['tags'] = json.loads(data['tags'])
        for key in ('image_path', 'content_path', 'segments_path'):
            if data.get(key):
                data[key] = str(self.root / data[key])
        return data

    def find_url(self, url: str) -> dict | None:
        row = self.db.execute(self.SOURCE_SELECT + ' WHERE url=? OR id IN (SELECT source_id FROM source_aliases WHERE url=?)', (url,url)).fetchone()
        return self.source(row) if row else None

    def require_new_source(self, *urls: str) -> None:
        aliases = list(dict.fromkeys(urls))
        for url in aliases:
            if existing := self.find_url(url):
                raise DuplicateSource(existing, aliases)

    def remember_source_aliases(self, source_id: str, aliases: list[str]) -> None:
        with self.lock(), self.db:
            self.db.executemany('INSERT OR IGNORE INTO source_aliases VALUES(?,?)',
                                [(alias, source_id) for alias in aliases])

    def list(self, params: dict) -> dict:
        conditions, values = [], []
        query = str(params.get('query', '')).strip()
        if query:
            if len(query) >= 3:
                conditions.append('id IN (SELECT source_id FROM source_fts WHERE source_fts MATCH ?)')
                values.append('"' + query.replace('"', '""') + '"')
            else:
                # Trigram cannot index 1–2 character Chinese queries; preserve useful matching.
                conditions.append('id IN (SELECT source_id FROM source_fts WHERE title LIKE ? ESCAPE \'\\\' OR content LIKE ? ESCAPE \'\\\')')
                pattern = '%' + query.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
                values.extend((pattern, pattern))
        if params.get('filter') == 'unread':
            conditions.append('read=0')
        elif params.get('filter') == 'starred':
            conditions.append('starred=1')
        if 'collection' in params:
            # An explicit empty path is the library root; omitting it searches all folders.
            conditions.append('collection=?')
            values.append(params['collection'])
        if params.get('platform'):
            conditions.append('platform=?')
            values.append(params['platform'])
        if params.get('tag'):
            conditions.append('EXISTS (SELECT 1 FROM json_each(sources.tags) WHERE value=?)')
            values.append(params['tag'])
        where = ' WHERE ' + ' AND '.join(conditions) if conditions else ''
        total = self.db.execute('SELECT count(*) FROM sources' + where, values).fetchone()[0]
        limit = min(200, max(1, int(params.get('limit', 60))))
        offset = max(0, int(params.get('offset', 0)))
        rows = self.db.execute(self.SOURCE_SELECT + where + ' ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?', [*values, limit, offset]).fetchall()
        collections = sorted({ancestor
            for row in self.db.execute("SELECT name FROM folders UNION SELECT collection FROM sources WHERE collection<>''")
            for ancestor in folder_ancestors(row[0])})
        tags = [r[0] for r in self.db.execute('SELECT DISTINCT value FROM sources,json_each(sources.tags) ORDER BY value')]
        return {'items': [self.source(row) for row in rows], 'total': total, 'collections': collections, 'tags': tags}

    def _folder_exists(self, name: str) -> bool:
        return self.db.execute('SELECT 1 FROM folders WHERE name=? UNION ALL '
                               'SELECT 1 FROM sources WHERE collection=? LIMIT 1',
                               (name, name)).fetchone() is not None

    def resolve_folder(self, name: str) -> str:
        # Folder paths are identifiers. Preserve legacy names that predate
        # path validation, including spaces around separators and empty parts.
        return name if name and self._folder_exists(name) else folder_path(name)

    def _ensure_folder(self, name: str) -> bool:
        created = False
        for ancestor in folder_ancestors(name):
            cursor = self.db.execute('INSERT OR IGNORE INTO folders(name,created_at) VALUES(?,?)', (ancestor,now()))
            created = cursor.rowcount == 1
        return created

    def create_folder(self, name: str, parent: str = '') -> dict:
        if not name.strip():
            raise ValueError('请输入文件夹名称')
        parent = self.resolve_folder(parent)
        candidate = parent + '/' + name if parent else name
        if self._folder_exists(candidate):
            name = candidate
        else:
            name = folder_path(name)
            name = parent + '/' + name if parent else name
        with self.lock():
            created = self._ensure_folder(name)
            self.db.commit()
        return {'name': name, 'created': created}

    def delete_folder(self, name: str, move_to_root: bool = False) -> dict:
        if not name:
            raise ValueError('无法删除资料库根目录')
        parent = name.rpartition('/')[0]
        destination = '' if move_to_root else parent
        with self.lock(), self.db:
            if not self._folder_exists(name):
                raise ValueError('文件夹已不存在')
            self._ensure_folder(destination)
            moved = self.db.execute(
                'UPDATE sources SET collection=? WHERE collection=? OR instr(collection, ?)=1',
                (destination, name, name + '/')).rowcount
            self.db.execute('DELETE FROM folders WHERE name=? OR instr(name, ?)=1',
                            (name, name + '/'))
        return {'destination': destination, 'moved': moved}

    def get(self, source_id: str) -> dict:
        source = self.source(self.db.execute(self.SOURCE_SELECT + ' WHERE id=?', (source_id,)).fetchone())
        artifacts = [self.artifact(r) for r in self.db.execute('SELECT * FROM artifacts WHERE source_id=? ORDER BY created_at DESC', (source_id,))]
        return {'source': source, 'content': Path(source['content_path']).read_text(),
                'segments': json.loads(Path(source['segments_path']).read_text()), 'artifacts': artifacts,
                'content_path': source['content_path'], 'segments_path': source['segments_path']}

    def insert_source(self, url: str, platform: str, title: str, content: str, segments: list, staged: Path, metadata: dict, refresh: bool = False, identity_url: str | None = None, collection: str | None = None, skip_existing: bool = False) -> dict:
        if collection is not None:
            collection = self.resolve_folder(collection)
        version = hashlib.sha256(content.encode()).hexdigest()
        with self.lock():
            identity = identity_url or url
            if skip_existing:
                self.require_new_source(identity, url, *metadata.get('aliases', []))
            existing = self.find_url(identity) or self.find_url(url)
            source_id = existing['id'] if existing else hashlib.sha256(identity.encode()).hexdigest()[:24]
            if existing and not refresh:
                for alias in metadata.get('aliases',[]):
                    self.db.execute('INSERT OR REPLACE INTO source_aliases VALUES(?,?)',(alias,existing['id']))
                if collection is not None:
                    self._ensure_folder(collection)
                    self.db.execute('UPDATE sources SET collection=? WHERE id=?', (collection, source_id))
                self.db.commit()
                return self.source(self.db.execute(self.SOURCE_SELECT + ' WHERE id=?', (source_id,)).fetchone())
            target = self.root / 'sources' / source_id / version[:16]
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                target = target.with_name(target.name + '-' + uuid.uuid4().hex[:8])
            staged.rename(target)
            (target / 'source.md').write_text(content, encoding='utf-8')
            write_json(target / 'segments.json', segments)
            write_json(target / 'source.json', {'id': source_id, 'url': url, 'title': title, 'platform': platform, 'version': version, **metadata})
            image = metadata.get('image_path')
            image_path = str((target / image).relative_to(self.root)) if image and (target / image).exists() else None
            self.db.execute('INSERT INTO sources(id,url,title,platform,created_at,image_path,status,version,content_path,segments_path) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET url=excluded.url,title=excluded.title,image_path=excluded.image_path,status=excluded.status,version=excluded.version,content_path=excluded.content_path,segments_path=excluded.segments_path',
                (source_id, url, title, platform, now(), image_path, metadata.get('status', 'ready'), version,
                 str((target/'source.md').relative_to(self.root)), str((target/'segments.json').relative_to(self.root))))
            if collection is not None:
                self._ensure_folder(collection)
                self.db.execute('UPDATE sources SET collection=? WHERE id=?', (collection, source_id))
            for alias in metadata.get('aliases',[]):
                self.db.execute('INSERT OR REPLACE INTO source_aliases VALUES(?,?)',(alias,source_id))
            self.db.execute('DELETE FROM source_fts WHERE source_id=?',(source_id,))
            self.db.execute('INSERT INTO source_fts(source_id,title,content) VALUES(?,?,?)', (source_id, title, content))
            self.db.commit()
        return self.find_url(url)

    def update(self, params: dict) -> dict:
        source_id = params['id']
        changes = {k: params[k] for k in ('read', 'starred', 'collection', 'tags') if k in params}
        if 'tags' in changes:
            changes['tags'] = json.dumps(list(dict.fromkeys(str(t).strip() for t in changes['tags'] if str(t).strip())), ensure_ascii=False)
        if 'collection' in changes:
            changes['collection'] = self.resolve_folder(str(changes['collection']))
        with self.lock():
            if changes:
                if changes.get('collection'):
                    self._ensure_folder(changes['collection'])
                self.db.execute('UPDATE sources SET ' + ','.join(f'{k}=?' for k in changes) + ' WHERE id=?', [*changes.values(), source_id])
                self.db.commit()
        return self.source(self.db.execute(self.SOURCE_SELECT + ' WHERE id=?', (source_id,)).fetchone())

    def artifact(self, row: sqlite3.Row) -> dict:
        data = dict(row)
        data['path'] = str(self.root / data['path'])
        return data

    def register_artifact(self, params: dict) -> dict:
        source_id = params['source_id']
        source = self.source(self.db.execute(self.SOURCE_SELECT + ' WHERE id=?', (source_id,)).fetchone())
        original = Path(params['path']).expanduser().resolve()
        if not original.is_file():
            raise ValueError('生成结果文件不存在')
        kind = params['kind']
        if kind not in ('markdown', 'html', 'image'):
            raise ValueError('不支持的产物格式')
        if kind == 'image':
            from PIL import Image
            with Image.open(original) as image:
                image.verify()
        elif not original.read_text(encoding='utf-8').strip():
            raise ValueError('生成结果为空')
        artifact_id = uuid.uuid4().hex
        target = self.root / 'artifacts' / artifact_id
        with self.lock():
            if params.get('run_id'):
                original_hash = digest(original)
                for previous in self.db.execute(
                    'SELECT * FROM artifacts WHERE source_id=? AND kind=? AND run_id=?',
                    (source_id, kind, params['run_id'])):
                    saved = self.root / previous['path']
                    if saved.is_file() and digest(saved) == original_hash:
                        return self.artifact(previous)
            target.mkdir(parents=True)
            # Preserve local resource siblings for generated HTML packages.
            if kind in ('html', 'markdown'):
                source_assets = Path(source['content_path']).parent / 'assets'
                if source_assets.is_dir():
                    shutil.copytree(source_assets, target / 'assets')
                if (original.parent / 'assets').is_dir():
                    shutil.copytree(original.parent / 'assets', target / 'assets', dirs_exist_ok=True)
            output = target / ('index' + original.suffix.lower())
            shutil.copy2(original, output)
            artifact = {'id': artifact_id, 'source_id': source_id, 'kind': kind,
                        'title': params.get('title') or source['title'], 'path': str(output.relative_to(self.root)),
                        'created_at': now(), 'model': params.get('model'), 'run_id': params.get('run_id')}
            parameters=dict(params.get('parameters',{}))
            for key in ('style','depth','context_start','context_end','harness'):
                if key in params:
                    parameters[key]=params[key]
            for record_name in ('codex-run.json','generation.json'):
                record_path=original.parent/record_name
                if record_path.is_file():
                    record=json.loads(record_path.read_text())
                    parameters={**record,**parameters}
                    shutil.copy2(record_path,target/record_name)
            write_json(target / 'manifest.json', {**artifact, 'source_version': source['version'], 'sha256': digest(output), 'parameters': parameters})
            self.db.execute('INSERT INTO artifacts VALUES(:id,:source_id,:kind,:title,:path,:created_at,:model,:run_id)', artifact)
            if artifact['run_id']:
                self.db.execute('INSERT OR IGNORE INTO runs(id,action,source_id,status,started_at,finished_at,metadata) VALUES(?,?,?,?,?,?,?)',
                    (artifact['run_id'],'generate',source_id,'completed',artifact['created_at'],artifact['created_at'],json.dumps(parameters,ensure_ascii=False)))
            if kind == 'markdown':
                preview = re.sub(r'[#*`>\[\]]', '', original.read_text())[:280].strip()
                self.db.execute('UPDATE sources SET summary=? WHERE id=?', (preview, source_id))
            if kind == 'image':
                from PIL import Image
                with Image.open(output) as image:
                    image.thumbnail((480,480))
                    image.convert('RGB').save(target/'preview.jpg','JPEG',quality=85)
                self.db.execute('UPDATE sources SET image_path=? WHERE id=?', (str((target/'preview.jpg').relative_to(self.root)), source_id))
            self.db.commit()
        artifact['path'] = str(output)
        return artifact

    def start_run(self, action: str, source_id: str | None, metadata: dict | None = None) -> str:
        run_id = uuid.uuid4().hex
        with self.lock():
            self.db.execute('INSERT INTO runs(id,action,source_id,status,started_at,metadata) VALUES(?,?,?,?,?,?)', (run_id, action, source_id, 'running', now(), json.dumps(metadata or {}, ensure_ascii=False)))
            self.db.commit()
        return run_id

    def finish_run(self, run_id: str, status: str, error: str | None = None, metadata: dict | None = None) -> None:
        with self.lock():
            details=metadata or {}
            self.db.execute('UPDATE runs SET status=?,finished_at=?,error=?,metadata=?,source_id=COALESCE(?,source_id) WHERE id=?', (status, now(), error, json.dumps(details,ensure_ascii=False), details.get('source_id'),run_id))
            self.db.commit()

    def snapshot(self) -> tuple[Path, dict[str, str]]:
        # One commit barrier covers database backup and immutable file manifest.
        with self.lock():
            staging = self.root / 'cache' / ('snapshot-' + uuid.uuid4().hex)
            staging.mkdir(parents=True)
            db_copy = staging / 'library.sqlite3'
            with sqlite3.connect(db_copy) as target:
                self.db.backup(target)
            files = {'library.sqlite3': digest(db_copy)}
            tasks = self.root / 'tasks.json'
            if tasks.is_file():
                # Native writers atomically replace the history outside the database lock.
                tasks_copy = staging / tasks.name
                with tasks.open('rb') as source, private_output(tasks_copy) as target:
                    shutil.copyfileobj(source, target)
                files[tasks.name] = digest(tasks_copy)
            # Agent checkpoints can still be written during a backup. Archive the
            # copied bytes, so each file agrees with the manifest; stage hashes
            # determine which complete prefix can be resumed after a restore.
            runs = self.root / 'runs'
            if runs.exists():
                for file in sorted(runs.rglob('*')):
                    if not file.is_file() or file.is_symlink() or any(part.startswith('.') for part in file.relative_to(runs).parts) or file.suffix == '.tmp':
                        continue
                    relative = str(file.relative_to(self.root))
                    copied = staging / relative
                    copied.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        with file.open('rb') as source, copied.open('xb') as target:
                            shutil.copyfileobj(source, target)
                    except FileNotFoundError:
                        continue
                    files[relative] = digest(copied)
            for directory in ('sources', 'artifacts', 'notes'):
                base = self.root / directory
                if base.exists():
                    for file in sorted(base.rglob('*')):
                        if file.is_file() and not file.is_symlink():
                            files[str(file.relative_to(self.root))] = digest(file)
            return staging, files

    def recycle_snapshot(self, staging: Path) -> None:
        trash=Path(os.environ.get('KNOWLAKE_TRASH',str(Path.home()/'.Trash')))
        try:
            trash.mkdir(parents=True,exist_ok=True)
            shutil.move(str(staging),str(trash/('KnowLake-'+staging.name)))
        except OSError as error:
            print(f'备份快照暂留缓存：{error}',file=sys.stderr)

    def backup(self, destination: str | None = None) -> dict:
        folder = Path(destination).expanduser().resolve() if destination else self.root / 'backups'
        folder.mkdir(parents=True, exist_ok=True)
        archive = folder / ('KnowLake-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6] + '.zip')
        staging, files = self.snapshot()
        with private_output(archive) as output, zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
            for relative in files:
                file = staging / relative if relative in ('library.sqlite3', 'tasks.json') or relative.startswith('runs/') else self.root / relative
                z.write(file, relative)
            z.writestr('backup-manifest.json', json.dumps({'format': 1, 'created_at': now(), 'files': files}, ensure_ascii=False))
        with self.lock():
            self.db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('last_backup',?)", (now(),))
            self.db.commit()
        self.recycle_snapshot(staging)
        return {'path': str(archive), 'files': len(files)}

    @staticmethod
    def restore(archive: str, destination: str) -> dict:
        target = Path(destination).expanduser().resolve()
        if target.exists() and any(target.iterdir()):
            raise ValueError('请选择空目录进行恢复')
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            manifest = json.loads(z.read('backup-manifest.json'))
            if manifest.get('format') != 1 or 'library.sqlite3' not in manifest.get('files', {}):
                raise ValueError('不支持的备份格式')
            for relative, expected in manifest['files'].items():
                path = PurePosixPath(relative)
                if path.is_absolute() or '..' in path.parts or '\\' in relative:
                    raise ValueError('备份包含无效路径')
                if path == PurePosixPath('config.json'):
                    # Old ZIPs may contain credentials. Restore the library without them.
                    continue
                output = target / relative
                if not output.resolve().is_relative_to(target):
                    raise ValueError('恢复路径超出目标目录')
                output.parent.mkdir(parents=True, exist_ok=True)
                with z.open(relative) as source, (private_output(output) if relative == 'tasks.json' else output.open('xb')) as dest:
                    shutil.copyfileobj(source, dest, length=1024 * 1024)
                if digest(output) != expected:
                    raise ValueError(f'备份校验失败：{relative}')
        with sqlite3.connect(target / 'library.sqlite3') as db:
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('恢复后的数据库校验失败')
        return {'root': str(target)}

    def migrate(self, destination: str) -> dict:
        target = Path(destination).expanduser().resolve()
        if target == self.root or target.is_relative_to(self.root) or self.root.is_relative_to(target):
            raise ValueError('迁移目标需要位于资料目录之外')
        if target.exists() and any(target.iterdir()):
            raise ValueError('请选择空目录进行迁移')
        staging, files = self.snapshot()
        target.mkdir(parents=True, exist_ok=True)
        for relative, expected in files.items():
            source = staging / relative if relative in ('library.sqlite3', 'tasks.json') or relative.startswith('runs/') else self.root / relative
            dest = target / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            if relative == 'tasks.json':
                with source.open('rb') as input_file, private_output(dest) as output:
                    shutil.copyfileobj(input_file, output)
            else:
                shutil.copy2(source, dest)
            if digest(dest) != expected:
                raise ValueError(f'迁移校验失败：{relative}')
        self.recycle_snapshot(staging)
        return {'root': str(target), 'previous_root': str(self.root), 'files': len(files)}

    def stats(self) -> dict:
        row = self.db.execute('SELECT count(*) total,sum(read=0) unread,sum(starred=1) starred FROM sources').fetchone()
        result = {k: row[k] or 0 for k in row.keys()}
        result['artifacts'] = self.db.execute('SELECT count(*) FROM artifacts').fetchone()[0]
        result['last_backup'] = (self.db.execute("SELECT value FROM settings WHERE key='last_backup'").fetchone() or [None])[0]
        return result
