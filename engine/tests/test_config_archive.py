import json
import stat
import zipfile
from pathlib import Path

import pytest

from knowlake_engine.store import Store, digest


@pytest.mark.parametrize('operation', ['backup', 'migrate'])
def test_library_copy_excludes_application_credentials(tmp_path, monkeypatch, operation):
    monkeypatch.setenv('KNOWLAKE_TRASH', str(tmp_path / 'Trash'))
    store = Store(tmp_path / 'library')
    config = store.root / 'config.json'
    original = b'{"credentials":{"model-api":"fixture-secret"}}'
    config.write_bytes(original)
    (store.root / 'tasks.json').write_text('{"version":1,"jobs":[]}')
    target = tmp_path / 'destination'
    try:
        if operation == 'backup':
            archive = Path(store.backup()['path'])
            assert stat.S_IMODE(archive.stat().st_mode) == 0o600
            with zipfile.ZipFile(archive) as zipped:
                assert 'config.json' not in zipped.namelist()
                manifest = json.loads(zipped.read('backup-manifest.json'))
                assert 'config.json' not in manifest['files']
            Store.restore(str(archive), str(target))
        else:
            store.migrate(str(target))

        assert not (target / 'config.json').exists()
        assert (target / 'tasks.json').is_file()
        assert config.read_bytes() == original
    finally:
        store.close()


def test_legacy_zip_restores_data_without_importing_credentials(tmp_path):
    store = Store(tmp_path / 'old-library')
    store.close()
    database = store.root / 'library.sqlite3'
    archive = tmp_path / 'legacy.zip'
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.write(database, 'library.sqlite3')
        zipped.writestr('config.json', '{"credentials":{"model-api":"fixture-secret"}}')
        zipped.writestr('backup-manifest.json', json.dumps({
            'format': 1, 'files': {'config.json': 'legacy-hash', 'library.sqlite3': digest(database)},
        }))
    target = tmp_path / 'restored'
    Store.restore(str(archive), str(target))
    assert (target / 'library.sqlite3').is_file()
    assert not (target / 'config.json').exists()
