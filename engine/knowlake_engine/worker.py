from __future__ import annotations
import json
import os
import signal
import sys
import uuid
from pathlib import Path

from .acquisition_support import recycle, report
from .markdown_source import import_markdown
from .module_registry import OPERATIONS, canonical_url, resolve_link
from .store import DuplicateSource, Store


def emit(event: str, data) -> None:
    print(json.dumps({'event':event,'data':data},ensure_ascii=False),flush=True)


def progress(message: str, **details) -> None:
    emit('progress', {'message':message, **details})


progress.structured_progress = True


def duplicate_import_urls(store: Store, urls: list[str], pending: list[str]) -> list[str]:
    def identity(url):
        try:
            return canonical_url(url)[1]
        except ValueError:
            return None

    seen = {key for url in pending if (key := identity(url))}
    duplicates = []
    for url in dict.fromkeys(urls):
        key = identity(url)
        if key is None:
            continue
        if key in seen or store.find_url(key) or (url != key and store.find_url(url)):
            duplicates.append(url)
        seen.add(key)
    return duplicates


def dispatch(store: Store, action: str, params: dict, run_id: str | None = None) -> dict:
    if action in OPERATIONS:
        return OPERATIONS[action](store, params, progress, run_id)
    if action == 'import_markdown':
        return {'source': import_markdown(store, params)}
    if action=='list':
        return store.list(params)
    if action=='check_imports':
        return {'duplicates': duplicate_import_urls(store, params['urls'], params.get('pending', []))}
    if action=='get':
        return store.get(params['id'])
    if action=='stats':
        return store.stats()
    if action=='update':
        return store.update(params)
    if action=='create_folder':
        return store.create_folder(params['name'], params.get('parent', ''))
    if action=='delete_folder':
        return store.delete_folder(params['name'], params.get('move_to_root', False))
    if action=='register_artifact':
        return {'artifact':store.register_artifact(params)}
    if action=='export':
        from .exporting import export
        return export(store,params)
    if action=='backup':
        progress('正在创建一致性备份')
        return store.backup(params.get('destination'))
    if action=='restore':
        progress('正在校验并恢复资料库')
        return Store.restore(params['archive'],params['destination'])
    if action=='migrate':
        progress('正在复制与校验资料库')
        return store.migrate(params['destination'])
    if action=='ingest':
        module, url = resolve_link(params['url'])
        collection = store.resolve_folder(params['collection']) if 'collection' in params else None
        # Article identity omits sharing fields, but WeChat may require sn/chksm
        # and the original query encoding when serving the page.
        request_url = params['url'].strip() if module.preserve_request_url else url
        retry = params.get('retry_from')
        if retry and retry not in ('fetch', 'subtitles', 'download', 'transcribe', 'save'):
            raise ValueError('不支持的采集重试阶段：' + str(retry))
        skip_existing = bool(params.get('skip_existing')) and not (params.get('refresh') or retry)
        existing=store.find_url(url)
        if skip_existing:
            existing = existing or (store.find_url(request_url) if request_url != url else None)
            if existing:
                report(progress, '资料已存在，已跳过添加', 'save', 'reused')
                return {'source':existing,'reused':True}
        cache = module.make_cache(store.root) if module.make_cache else None
        resume = bool(cache and cache.incomplete(url))
        if existing and not params.get('refresh') and not retry and not resume:
            if collection is not None:
                existing = store.update({'id': existing['id'], 'collection': collection})
            report(progress, '资料已存在，复用归档', 'save', 'reused')
            return {'source':existing,'reused':True}
        work=store.root/'cache'/('ingest-'+uuid.uuid4().hex)
        work.mkdir(parents=True)
        if cache:
            cache.cleanup()
        def check_duplicate(*identities):
            store.require_new_source(*identities, url, request_url)

        try:
            options = {'check_duplicate': check_duplicate} if skip_existing else {}
            if cache:
                options['cache'] = cache
            result = module.acquire(request_url, work, params, progress, **options)
            report(progress, '正在保存来源', 'save')
            metadata = result['metadata']
            metadata['aliases'] = list(dict.fromkeys([*metadata.get('aliases', []), url, request_url]))
            identity = metadata.get('identity_url', url) if module.preserve_request_url else None
            source=store.insert_source(result['url'],module.id,result['title'],result['content'],result['segments'],work,metadata,refresh=bool(params.get('refresh') or retry or resume),identity_url=identity,collection=collection,skip_existing=skip_existing)
            if cache:
                with cache.entry(result['_acquisition_url']) as entry:
                    entry.complete('save', {'source_id': source['id'], 'version': source['version']})
            report(progress, '来源已保存', 'save', 'completed',
                   [str(Path(source['content_path']).relative_to(store.root)), str(Path(source['segments_path']).relative_to(store.root))])
            emit('source_ready',{'source':source})
            return {'source':source,'reused':False}
        except DuplicateSource as duplicate:
            store.remember_source_aliases(duplicate.source['id'], duplicate.aliases)
            report(progress, '资料已存在，已跳过添加', 'save', 'reused')
            return {'source':duplicate.source, 'reused':True}
        finally:
            # Only archive-ready files enter work. Media and ASR temporary files
            # live in acquisition entries and survive failed/cancelled attempts.
            if work.exists():
                recycle(work)
            if cache:
                cache.cleanup()
    if action=='runs':
        rows=store.db.execute('SELECT * FROM runs ORDER BY started_at DESC LIMIT 100').fetchall()
        return {'items':[dict(r) for r in rows]}
    raise ValueError('未知操作：'+action)


def main() -> None:
    store=None
    run_id=None
    try:
        request=json.loads(sys.stdin.readline())
        action=request['action']
        params=request.get('params',{})
        if params.get('proxy'):
            for name in ('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy'):
                os.environ[name]=params['proxy']
        store=Store(request['root'])
        if action in ('ingest','generate'):
            run_id=store.start_run(action,params.get('id'),{'model':params.get('model'),'mode':params.get('mode')})
        def cancelled(signum,frame):
            # Unwind active transactions/locks before writing the final state.
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM,cancelled)
        signal.signal(signal.SIGINT,cancelled)
        result=dispatch(store,action,params,run_id)
        if run_id:
            store.finish_run(run_id,'completed',metadata={'usage':result.get('usage',{}),'model':params.get('model'),'source_id':result.get('source',{}).get('id') or result.get('artifact',{}).get('source_id'),'source_version':result.get('source',{}).get('version')})
        emit('result',result)
    except KeyboardInterrupt:
        if store and run_id:
            store.finish_run(run_id,'cancelled')
        emit('error',{'message':'任务已取消','type':'Cancelled'})
        raise SystemExit(130)
    except Exception as exc:
        if store and run_id:
            store.finish_run(run_id,'failed',error=str(exc))
        emit('error',{'message':str(exc),'type':type(exc).__name__})
        raise SystemExit(1)
    finally:
        if store:
            store.close()


if __name__=='__main__':
    main()
