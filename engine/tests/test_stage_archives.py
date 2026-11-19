import json
import stat
import zipfile
from pathlib import Path

from knowlake_engine.store import Store


def test_register_repeated_save_is_idempotent(tmp_path, monkeypatch):
    monkeypatch.setenv('KNOWLAKE_TRASH', str(tmp_path / 'trash'))
    with_store = Store(tmp_path / 'library')
    try:
        work = tmp_path / 'source'
        work.mkdir()
        source = with_store.insert_source('https://mp.weixin.qq.com/s/stage-fixture', 'wechat',
                                         'Stage fixture', '# Source\n\nFacts.', [], work, {})
        run = with_store.root / 'runs' / 'attempt'
        run.mkdir(parents=True)
        output = run / 'note.md'
        output.write_text('# Note\n\nPreserved draft facts.')
        params = {'source_id': source['id'], 'kind': 'markdown', 'path': str(output), 'run_id': 'same-turn'}
        first = with_store.register_artifact(params)
        again = with_store.register_artifact(params)
        assert again['id'] == first['id']
        assert with_store.db.execute('SELECT count(*) FROM artifacts').fetchone()[0] == 1
        output.write_text('# Note\n\nA genuinely new result.')
        assert with_store.register_artifact({**params, 'run_id': 'another-turn'})['id'] != first['id']
    finally:
        with_store.close()


def test_task_history_and_run_snapshots_survive_backup_and_migration(tmp_path, monkeypatch):
    monkeypatch.setenv('KNOWLAKE_TRASH', str(tmp_path / 'trash'))
    store = Store(tmp_path / 'library')
    try:
        tasks = store.root / 'tasks.json'
        tasks.write_text(json.dumps({'version': 1, 'jobs': [{'id': 'fixture'}]}))
        tasks.chmod(0o600)
        run = store.root / 'runs' / 'attempt'
        (run / 'checkpoints').mkdir(parents=True)
        draft = run / 'draft.md'
        draft.write_text('Stable checkpoint bytes')
        (run / 'checkpoints' / 'draft.json').write_text('{"version":2}')
        (run / '.draft.tmp').write_text('Not a completed write')
        (store.root / 'cache' / 'acquisition').mkdir(parents=True)
        (store.root / 'cache' / 'acquisition' / 'audio.m4a').write_bytes(b'temporary media')
        original_snapshot = store.snapshot
        def snapshot_then_update():
            result = original_snapshot()
            tasks.write_text('{"version":1,"jobs":[]}')
            draft.write_text('Later active edits')
            return result
        monkeypatch.setattr(store, 'snapshot', snapshot_then_update)
        archive = store.backup()['path']
        with zipfile.ZipFile(archive) as zipped:
            assert zipped.read('runs/attempt/draft.md') == b'Stable checkpoint bytes'
            assert json.loads(zipped.read('tasks.json'))['jobs'] == [{'id': 'fixture'}]
            assert 'runs/attempt/.draft.tmp' not in zipped.namelist()
            assert not any(name.startswith('cache/') for name in zipped.namelist())
        restored = tmp_path / 'restored'
        Store.restore(archive, str(restored))
        assert (restored / 'runs/attempt/draft.md').read_text() == 'Stable checkpoint bytes'
        assert stat.S_IMODE((restored / 'tasks.json').stat().st_mode) == 0o600
        monkeypatch.setattr(store, 'snapshot', original_snapshot)
        migrated = tmp_path / 'migrated'
        store.migrate(str(migrated))
        assert (migrated / 'runs/attempt/draft.md').read_text() == 'Later active edits'
        assert (migrated / 'tasks.json').is_file()
        assert stat.S_IMODE((migrated / 'tasks.json').stat().st_mode) == 0o600
    finally:
        store.close()
