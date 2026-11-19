from pathlib import Path
import sqlite3

import pytest

from knowlake_engine.store import Store, digest
from knowlake_engine.worker import dispatch


@pytest.fixture
def store(tmp_path, monkeypatch):
    monkeypatch.setenv('KNOWLAKE_TRASH', str(tmp_path / 'Trash'))
    value = Store(tmp_path / 'library')
    yield value
    value.close()


def add(store, suffix='fixture'):
    staged = store.root / 'cache' / suffix
    staged.mkdir(parents=True)
    return store.insert_source('https://mp.weixin.qq.com/s/folder-' + suffix, 'wechat',
                               '文件夹测试', '正文保持原位置', [], staged, {})


def test_empty_folder_creation_is_persistent_and_idempotent(store):
    assert dispatch(store, 'create_folder', {'name': '  研究资料  '}) == {
        'name': '研究资料', 'created': True}
    assert store.create_folder('研究资料') == {'name': '研究资料', 'created': False}
    assert store.list({})['collections'] == ['研究资料']
    assert store.list({'collection': '研究资料'})['total'] == 0
    reopened = Store(store.root)
    try:
        assert reopened.list({})['collections'] == ['研究资料']
    finally:
        reopened.close()
    with pytest.raises(ValueError, match='文件夹名称'):
        store.create_folder(' \n ')


def test_existing_collections_become_folders_and_remain_after_moving_source(store):
    source = add(store)
    content = Path(source['content_path'])
    original_hash = digest(content)
    # Simulate a library written before the folders table existed.
    store.db.execute('UPDATE sources SET collection=? WHERE id=?', ('旧集合', source['id']))
    store.db.commit()
    assert store.list({})['collections'] == ['旧集合']
    reopened = Store(store.root)
    try:
        moved = reopened.update({'id': source['id'], 'collection': '新文件夹'})
        assert moved['collection'] == '新文件夹'
        assert reopened.list({'collection': '新文件夹'})['items'][0]['id'] == source['id']
        assert reopened.list({'collection': '旧集合'})['total'] == 0
        assert reopened.list({})['collections'] == ['新文件夹', '旧集合']
        reopened.update({'id': source['id'], 'collection': ''})
        assert reopened.list({'collection': '新文件夹'})['total'] == 0
        assert reopened.list({})['collections'] == ['新文件夹', '旧集合']
        assert Path(moved['content_path']) == content
        assert digest(content) == original_hash
    finally:
        reopened.close()


def test_tag_updates_accept_one_tag_per_value_and_remove_individually(store):
    source = add(store)
    updated = store.update({'id': source['id'], 'tags': [' Swift ', 'Swift', 'AI, Safety', '', '论文']})
    assert updated['tags'] == ['Swift', 'AI, Safety', '论文']
    assert store.list({'tag': 'AI, Safety'})['total'] == 1
    updated = store.update({'id': source['id'], 'tags': ['AI, Safety', '论文']})
    assert updated['tags'] == ['AI, Safety', '论文']
    assert store.list({'tag': 'Swift'})['total'] == 0


@pytest.mark.parametrize('operation', ['restore', 'migrate'])
def test_empty_folders_travel_with_the_library(store, tmp_path, operation):
    store.create_folder('空文件夹/子目录/孙目录')
    target = tmp_path / operation
    if operation == 'restore':
        Store.restore(store.backup()['path'], str(target))
    else:
        store.migrate(str(target))
    with sqlite3.connect(target / 'library.sqlite3') as database:
        assert database.execute('SELECT name FROM folders ORDER BY name').fetchall() == [
            ('空文件夹',), ('空文件夹/子目录',), ('空文件夹/子目录/孙目录',)]


def test_nested_folder_creation_keeps_empty_ancestors_after_reopening(store):
    assert dispatch(store, 'create_folder', {'name': '  静态分析  ', 'parent': '研究 / 论文'}) == {
        'name': '研究/论文/静态分析', 'created': True}
    assert store.create_folder('研究/论文/静态分析') == {
        'name': '研究/论文/静态分析', 'created': False}
    assert store.create_folder('静态分析', parent='开发') == {
        'name': '开发/静态分析', 'created': True}
    expected = ['开发', '开发/静态分析', '研究', '研究/论文', '研究/论文/静态分析']
    assert store.list({})['collections'] == expected
    reopened = Store(store.root)
    try:
        assert reopened.list({})['collections'] == expected
        assert reopened.list({'collection': '研究'})['total'] == 0
    finally:
        reopened.close()


@pytest.mark.parametrize('name', ['研究//论文', '/研究', '研究/', '研究/../论文', '研究/./论文'])
def test_invalid_folder_segments_do_not_create_partial_folders(store, name):
    with pytest.raises(ValueError, match='文件夹名称'):
        store.create_folder(name)
    assert store.list({})['collections'] == []


def test_legacy_nested_collections_keep_their_content_and_gain_parents(store):
    source = add(store)
    store.db.execute('UPDATE sources SET collection=? WHERE id=?', ('研究/论文/静态分析', source['id']))
    store.db.commit()
    reopened = Store(store.root)
    try:
        assert reopened.list({})['collections'] == ['研究', '研究/论文', '研究/论文/静态分析']
        assert reopened.list({'collection': '研究'})['total'] == 0
        assert reopened.list({'collection': '研究/论文/静态分析'})['items'][0]['id'] == source['id']
        assert reopened.get(source['id'])['content_path'] == source['content_path']
        assert reopened.get(source['id'])['content'] == '正文保持原位置'
    finally:
        reopened.close()


@pytest.mark.parametrize('legacy', [
    '研究 / 论文', '研究//论文', '研究/./论文', '研究/../论文', '.', '研究/', '/研究',
])
def test_legacy_folder_identifiers_remain_distinct_and_usable(store, monkeypatch, legacy):
    original = add(store)
    other = add(store, 'other')
    store.update({'id': other['id'], 'collection': '研究/论文'})
    # Both names were valid in the old single-level folder implementation.
    store.db.execute('UPDATE sources SET collection=? WHERE id=?', (legacy, original['id']))
    store.db.commit()
    def acquire(url, work, params, progress):
        return {'url': url, 'title': '新资料', 'content': '旧目录中的新内容',
                'segments': [], 'metadata': {}}
    monkeypatch.setattr('knowlake_engine.connectors.wechat.acquire', acquire)
    reopened = Store(store.root)
    try:
        assert legacy in reopened.list({})['collections']
        assert '' not in reopened.list({})['collections']
        assert reopened.list({'collection': legacy})['items'][0]['id'] == original['id']
        assert reopened.list({'collection': '研究/论文'})['items'][0]['id'] == other['id']
        assert reopened.create_folder(legacy) == {'name': legacy, 'created': False}
        child = reopened.create_folder('  子目录  ', parent=legacy)['name']
        assert child == legacy + '/子目录'
        moved = reopened.update({'id': original['id'], 'collection': child})
        assert moved['collection'] == child
        assert reopened.list({'collection': legacy})['total'] == 0
        assert reopened.list({'collection': child})['items'][0]['id'] == original['id']
        moved = reopened.update({'id': original['id'], 'collection': legacy})
        assert moved['collection'] == legacy
        assert moved['content_path'] == original['content_path']
        reused = dispatch(reopened, 'ingest', {'url': original['url'], 'collection': legacy})
        assert reused['reused'] is True
        assert reused['source']['collection'] == legacy
        imported = dispatch(reopened, 'ingest', {
            'url': 'https://mp.weixin.qq.com/s/legacy-destination', 'collection': legacy})
        assert imported['source']['collection'] == legacy
        assert reopened.list({'collection': legacy})['total'] == 2
    finally:
        reopened.close()


def test_legacy_empty_folder_with_spaces_keeps_exact_parent(store):
    store.db.execute('INSERT INTO folders VALUES(?,?)', ('研究 / 论文', '2026-01-01'))
    store.db.commit()
    reopened = Store(store.root)
    try:
        assert reopened.create_folder('摘录', parent='研究 / 论文')['name'] == '研究 / 论文/摘录'
        assert reopened.create_folder('新资料', parent='研究 ')['name'] == '研究 /新资料'
        assert '研究/论文' not in reopened.list({})['collections']
        assert reopened.create_folder(' 新建 / 目录 ')['name'] == '新建/目录'
    finally:
        reopened.close()


def test_folder_filter_shows_only_direct_members_with_exact_counts_and_pagination(store):
    locations = ['', '', '', '研究%_', '研究%_', '研究%_/论文',
                 '研究%_/论文/静态分析', '研究%_补充', '研究AB/论文']
    sources = []
    for index, location in enumerate(locations):
        source = add(store, str(index))
        source = store.update({'id': source['id'], 'collection': location})
        sources.append(source)
    page = store.list({'collection': '', 'limit': 2})
    assert page['total'] == 3
    assert len(page['items']) == 2
    next_page = store.list({'collection': '', 'limit': 2, 'offset': 2})
    assert next_page['total'] == 3
    assert len(next_page['items']) == 1
    assert {item['id'] for item in page['items'] + next_page['items']} == {
        source['id'] for source in sources[:3]}
    parent = store.list({'collection': '研究%_', 'limit': 1})
    next_parent = store.list({'collection': '研究%_', 'limit': 1, 'offset': 1})
    assert parent['total'] == next_parent['total'] == 2
    assert {item['id'] for item in parent['items'] + next_parent['items']} == {
        source['id'] for source in sources[3:5]}
    assert store.list({'collection': '研究%_/论文'})['total'] == 1
    assert store.list({'collection': '研究%_/论文/静态分析'})['total'] == 1
    assert store.list({})['total'] == len(locations)
    assert store.list({'collection': '', 'query': '正文'})['total'] == 3
    assert store.list({'query': '正文'})['total'] == len(locations)


def test_move_replaces_the_single_folder_without_changing_source_or_artifacts(store, tmp_path):
    source = add(store)
    store.update({'id': source['id'], 'read': True, 'starred': True, 'tags': ['论文']})
    note = tmp_path / 'note.md'
    note.write_text('已有图文笔记', encoding='utf-8')
    artifact = store.register_artifact({'source_id': source['id'], 'kind': 'markdown', 'path': str(note)})
    before = store.get(source['id'])
    for destination in ['研究', '研究/论文', '开发/工具', '']:
        moved = store.update({'id': source['id'], 'collection': destination})
        assert moved['id'] == source['id']
        assert moved['collection'] == destination
        assert moved['read'] and moved['starred'] and moved['tags'] == ['论文']
        after = store.get(source['id'])
        assert after['content_path'] == before['content_path']
        assert after['content'] == before['content']
        assert after['artifacts'] == [artifact]
        for folder in ['', '研究', '研究/论文', '开发', '开发/工具']:
            page = store.list({'collection': folder})
            assert page['total'] == (1 if folder == destination else 0)
            assert [item['id'] for item in page['items']] == ([source['id']] if folder == destination else [])
        assert store.list({})['total'] == 1
        assert store.list({'filter': 'starred'})['total'] == 1
        assert store.list({'filter': 'unread'})['total'] == 0
    assert '开发/工具' in store.list({'collection': ''})['collections']


def test_ingest_selects_folder_before_source_ready_and_preserves_it_on_refresh(store, monkeypatch):
    events = []
    acquisitions = []
    def acquire(url, work, params, progress):
        acquisitions.append(url)
        return {'url': url, 'title': '资料', 'content': '第' + str(len(acquisitions)) + '次获取',
                'segments': [], 'metadata': {}}
    monkeypatch.setattr('knowlake_engine.connectors.wechat.acquire', acquire)
    monkeypatch.setattr('knowlake_engine.worker.emit', lambda event, data: events.append((event, data)))
    url = 'https://mp.weixin.qq.com/s/import-folder'
    first = dispatch(store, 'ingest', {'url': url, 'collection': '研究/论文/静态分析'})
    assert first['source']['collection'] == '研究/论文/静态分析'
    assert [data['source']['collection'] for event, data in events if event == 'source_ready'] == [
        '研究/论文/静态分析']
    assert store.list({'collection': '研究'})['total'] == 0
    assert store.list({'collection': ''})['total'] == 0
    assert store.list({'collection': '研究/论文/静态分析'})['total'] == 1
    assert store.list({})['collections'] == ['研究', '研究/论文', '研究/论文/静态分析']
    reused = dispatch(store, 'ingest', {'url': url})
    assert reused['reused'] is True
    assert reused['source']['collection'] == '研究/论文/静态分析'
    assert len(acquisitions) == 1
    moved = dispatch(store, 'ingest', {'url': url, 'collection': '开发/工具'})
    assert moved['source']['collection'] == '开发/工具'
    assert moved['source']['content_path'] == first['source']['content_path']
    assert len(acquisitions) == 1
    refreshed = dispatch(store, 'ingest', {'url': url, 'refresh': True})
    assert refreshed['source']['collection'] == '开发/工具'
    assert store.get(first['source']['id'])['content'] == '第2次获取'
    cleared = dispatch(store, 'ingest', {'url': url, 'collection': ''})
    assert cleared['source']['collection'] == ''
    assert store.list({'collection': '开发'})['total'] == 0
    assert store.list({})['total'] == 1


def test_resolved_alias_reuses_source_and_applies_selected_folder(store, monkeypatch):
    original = add(store)
    store.update({'id': original['id'], 'collection': '旧目录'})
    def acquire(url, work, params, progress):
        return {'url': original['url'], 'title': '不覆盖', 'content': '不覆盖正文',
                'segments': [], 'metadata': {}}
    monkeypatch.setattr('knowlake_engine.connectors.wechat.acquire', acquire)
    result = dispatch(store, 'ingest', {
        'url': 'https://mp.weixin.qq.com/s/resolved-folder', 'collection': '新目录/子目录'})
    assert result['source']['id'] == original['id']
    assert result['source']['collection'] == '新目录/子目录'
    assert result['source']['content_path'] == original['content_path']
    assert store.get(original['id'])['content'] == '正文保持原位置'
    assert store.list({})['total'] == 1


def test_invalid_ingest_destination_fails_before_acquiring(store, monkeypatch):
    def acquire(*args):
        pytest.fail('Invalid folder should be rejected before acquisition')
    monkeypatch.setattr('knowlake_engine.connectors.wechat.acquire', acquire)
    with pytest.raises(ValueError, match='文件夹名称'):
        dispatch(store, 'ingest', {'url': 'https://mp.weixin.qq.com/s/import-folder',
                                 'collection': '研究//论文'})
    assert store.list({})['total'] == 0


@pytest.mark.parametrize('move_to_root,destination', [(False, '研究'), (True, '')])
def test_delete_folder_rehomes_subtree_sources_without_touching_archives(
        store, tmp_path, move_to_root, destination):
    folder = '研究/资料%_'
    locations = [folder, folder + '/笔记', '研究/资料%_备份', '研究/资料AB/同名笔记']
    sources = [store.update({'id': add(store, str(i))['id'], 'collection': path,
                             'read': True, 'starred': True, 'tags': ['保留']})
               for i, path in enumerate(locations)]
    store.create_folder('空目录', parent=folder)
    note = tmp_path / 'note.md'
    note.write_text('已有笔记', encoding='utf-8')
    artifact = store.register_artifact({'source_id': sources[0]['id'], 'kind': 'markdown',
                                        'path': str(note)})

    params = {'name': folder}
    if move_to_root:
        params['move_to_root'] = True
    assert dispatch(store, 'delete_folder', params) == {'destination': destination, 'moved': 2}

    reopened = Store(store.root)
    try:
        assert reopened.list({})['collections'] == [
            '研究', '研究/资料%_备份', '研究/资料AB', '研究/资料AB/同名笔记']
        for i, source in enumerate(sources):
            result = reopened.get(source['id'])
            assert result['source']['collection'] == (destination if i < 2 else locations[i])
            assert result['source']['read'] and result['source']['starred']
            assert result['source']['tags'] == ['保留']
            assert result['content_path'] == source['content_path']
            assert result['content'] == '正文保持原位置'
            assert result['artifacts'] == ([artifact] if i == 0 else [])
    finally:
        reopened.close()


def test_delete_empty_folder_leaves_library_root_intact(store):
    store.create_folder('空目录')
    assert store.delete_folder('空目录') == {'destination': '', 'moved': 0}
    assert store.list({})['collections'] == []
    with pytest.raises(ValueError, match='根目录'):
        store.delete_folder('')
