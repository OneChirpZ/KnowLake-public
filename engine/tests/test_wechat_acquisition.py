import hashlib
from pathlib import Path
from urllib.error import URLError

import pytest

from knowlake_engine.connectors import wechat
from knowlake_engine.store import Store, canonical_url
from knowlake_engine import worker


ORIGINAL = ('http://mp.weixin.qq.com/s?__biz=fixture==&mid=42&idx=1'
            '&sn=signature%2Bfixture&chksm=checksum%3Dfixture&scene=0#rd')
ARTICLE = '''<html><h1 id="activity-name">完整链接文章</h1>
<span id="js_name">示例作者</span><div id="js_content"><p>正文内容与来源引用。</p></div></html>'''


@pytest.fixture
def library(tmp_path, monkeypatch):
    monkeypatch.setenv('KNOWLAKE_TRASH', str(tmp_path / 'Trash'))
    store = Store(tmp_path / 'library')
    yield store
    store.close()


def progress_recorder():
    events = []

    def record(message, **details):
        events.append({'message': message, **details})

    record.structured_progress = True
    return events, record


def test_full_wechat_url_is_fetched_and_openable_while_identity_deduplicates(library, monkeypatch):
    fetched = []
    emitted = []
    monkeypatch.setattr(wechat, 'fetch', lambda url, headers: fetched.append(url) or ARTICLE.encode())
    monkeypatch.setattr(worker, 'emit', lambda event, data: emitted.append((event, data)))

    source = worker.dispatch(library, 'ingest', {'url': ORIGINAL})['source']
    identity = canonical_url(ORIGINAL)[1]
    assert fetched == [ORIGINAL]
    assert source['url'] == ORIGINAL
    assert source['id'] == hashlib.sha256(identity.encode()).hexdigest()[:24]
    assert f'[原文]({ORIGINAL})' in library.get(source['id'])['content']
    assert library.find_url(identity)['id'] == source['id']
    variant = ORIGINAL.replace('scene=0', 'scene=99&xtrack=1')
    reused = worker.dispatch(library, 'ingest', {'url': variant})
    assert reused['reused'] and reused['source']['id'] == source['id']
    assert fetched == [ORIGINAL]
    assert library.list({})['total'] == 1
    progress = [data for event, data in emitted if event == 'progress']
    stages = [(event['stage'], event['status']) for event in progress]
    assert stages[0] == ('fetch', 'started')
    assert ('fetch', 'completed') in stages
    assert stages.index(('fetch', 'completed')) < stages.index(('save', 'started'))
    assert any(event == 'source_ready' for event, _ in emitted)


def test_refresh_retains_old_identity_metadata_and_snapshot(library, monkeypatch):
    identity = canonical_url(ORIGINAL)[1]
    staging = library.root / 'cache' / 'legacy'
    staging.mkdir(parents=True)
    previous = library.insert_source(identity, 'wechat', '旧标题', '旧正文', [], staging, {})
    library.update({'id': previous['id'], 'read': True, 'starred': True, 'collection': '研究'})
    old_path = Path(previous['content_path'])
    fetched = []
    monkeypatch.setattr(wechat, 'fetch', lambda url, headers: fetched.append(url) or ARTICLE.encode())
    refreshed = worker.dispatch(library, 'ingest', {'url': ORIGINAL, 'refresh': True})['source']
    variant = ORIGINAL.replace('scene=0', 'scene=1')
    again = worker.dispatch(library, 'ingest', {'url': variant, 'refresh': True})['source']
    assert fetched == [ORIGINAL, variant]
    assert again['id'] == refreshed['id'] == previous['id']
    assert again['url'] == variant
    assert again['read'] and again['starred'] and again['collection'] == '研究'
    assert old_path.read_text() == '旧正文'
    assert library.find_url(identity)['id'] == previous['id']
    assert library.find_url(ORIGINAL)['id'] == previous['id']
    assert library.list({})['total'] == 1


def test_metadata_identity_alias_deduplicates_long_and_short_links(library, monkeypatch):
    short = 'https://mp.weixin.qq.com/s/short-fixture'
    html = ARTICLE.replace('<html>', f'<html><meta property="og:url" content="{short}">')
    monkeypatch.setattr(wechat, 'fetch', lambda *args: html.encode())
    first = worker.dispatch(library, 'ingest', {'url': ORIGINAL})['source']
    assert first['url'] == ORIGINAL
    assert library.find_url(short)['id'] == first['id']
    assert worker.dispatch(library, 'ingest', {'url': short})['reused']
    assert worker.dispatch(library, 'ingest', {'url': ORIGINAL.replace('scene=0', 'scene=2')})['reused']
    assert library.list({})['total'] == 1


def test_add_only_skips_new_wechat_alias_before_downloading_images(library, monkeypatch):
    short = 'https://mp.weixin.qq.com/s/short-fixture'
    monkeypatch.setattr(wechat, 'fetch', lambda *args: ARTICLE.encode())
    first = worker.dispatch(library, 'ingest', {'url': short, 'collection': '原文件夹'})['source']
    html = ARTICLE.replace('<html>', f'<html><meta property="og:url" content="{short}">')
    html = html.replace('</p>', '</p><img src="https://example.invalid/image.jpg">')
    fetched = []
    monkeypatch.setattr(wechat, 'fetch', lambda url, headers: fetched.append(url) or html.encode())
    monkeypatch.setattr(wechat, 'save_image', lambda *args: pytest.fail('重复文章不应下载图片'))

    result = worker.dispatch(library, 'ingest', {'url': ORIGINAL, 'collection': '目标', 'skip_existing': True})
    assert fetched == [ORIGINAL]
    assert result['reused']
    assert result['source'] == first
    assert library.list({})['collections'] == ['原文件夹']
    tracked = ORIGINAL.replace('scene=0', 'scene=15&tracking=copy')
    assert worker.dispatch(library, 'check_imports', {'urls': [tracked]})['duplicates'] == [tracked]
    assert worker.dispatch(library, 'ingest', {'url': tracked, 'skip_existing': True})['reused']
    assert fetched == [ORIGINAL]


@pytest.mark.parametrize('http_fails', [False, True])
def test_browser_fallback_keeps_full_url_and_runs_once(tmp_path, monkeypatch, http_fails):
    requests = []

    def fetch(url, headers):
        requests.append(('http', url))
        if http_fails:
            raise URLError('controlled connection failure')
        return b'<html><script>renderArticle()</script></html>'

    async def browser(url, options):
        requests.append(('browser', url))
        return ARTICLE

    monkeypatch.setattr(wechat, 'fetch', fetch)
    monkeypatch.setattr(wechat, 'browser_html', browser)
    events, progress = progress_recorder()
    result = wechat.acquire(ORIGINAL, tmp_path, {}, progress)
    assert result['title'] == '完整链接文章'
    assert requests == [('http', ORIGINAL), ('browser', ORIGINAL)]
    assert events[0]['stage'] == events[-1]['stage'] == 'fetch'
    assert events[0]['status'] == 'started' and events[-1]['status'] == 'completed'
    assert not any(event['status'] == 'failed' for event in events)


@pytest.mark.parametrize(('html', 'message'), [
    ('<html><body>参数错误</body></html>', '完整文章链接'),
    ('<html><div id="js_verify">请完成安全验证</div></html>', '验证码验证'),
    ('<html><body>该内容已被发布者删除</body></html>', '文章已删除'),
    ('<html><body>请先登录后查看文章</body></html>', '登录后查看'),
])
@pytest.mark.parametrize('browser_response', [False, True])
def test_blocked_pages_report_specific_fetch_failure(tmp_path, monkeypatch, html, message, browser_response):
    monkeypatch.setattr(wechat, 'fetch', lambda *args: (b'<html>Loading</html>' if browser_response else html.encode()))
    browser_calls = []

    async def browser(url, options):
        browser_calls.append(url)
        return html

    monkeypatch.setattr(wechat, 'browser_html', browser)
    events, progress = progress_recorder()
    with pytest.raises(RuntimeError, match=message):
        wechat.acquire(ORIGINAL, tmp_path, {}, progress)
    assert browser_calls == ([ORIGINAL] if browser_response else [])
    assert events[0]['stage'] == events[-1]['stage'] == 'fetch'
    assert events[-1]['status'] == 'failed'
    assert not any(event['status'] == 'completed' for event in events)
    assert not (tmp_path / 'original.html').exists()


def test_unrecognized_empty_page_does_not_claim_deleted_or_login(tmp_path, monkeypatch):
    monkeypatch.setattr(wechat, 'fetch', lambda *args: b'<html>Loading</html>')

    async def browser(*args):
        return '<html><body>No recognizable article content</body></html>'

    monkeypatch.setattr(wechat, 'browser_html', browser)
    events, progress = progress_recorder()
    with pytest.raises(ValueError, match='未提供可解析') as failure:
        wechat.acquire(ORIGINAL, tmp_path, {}, progress)
    assert '已删除' not in str(failure.value) and '登录' not in str(failure.value)
    assert events[-1]['status'] == 'failed'


def test_error_words_in_valid_article_are_not_mistaken_for_block_page(tmp_path, monkeypatch):
    html = ARTICLE.replace('正文内容与来源引用。', '本文介绍参数错误和环境异常的排查方法。')
    monkeypatch.setattr(wechat, 'fetch', lambda *args: html.encode())
    result = wechat.acquire(ORIGINAL, tmp_path, {}, lambda _: None)
    assert result['title'] == '完整链接文章'


def test_partial_images_keep_original_referer_and_truthful_progress(tmp_path, monkeypatch):
    html = ARTICLE.replace('</div>', '<img data-src="https://example.invalid/cover.jpg"></div>')
    monkeypatch.setattr(wechat, 'fetch', lambda *args: html.encode())
    references = []

    def image(url, directory, name, referer):
        references.append(referer)
        raise OSError('controlled image failure')

    monkeypatch.setattr(wechat, 'save_image', image)
    events, progress = progress_recorder()
    result = wechat.acquire(ORIGINAL, tmp_path, {}, progress)
    assert references == [ORIGINAL]
    assert result['metadata']['status'] == 'partial'
    assert result['metadata']['warnings'] == ['图片 1 下载失败']
    assert events[-1]['status'] == 'completed'
    assert '部分图片未能保存' in events[-1]['message']
