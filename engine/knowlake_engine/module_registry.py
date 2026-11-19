"""Compose the engine from the source and operation modules shipped with it."""
from __future__ import annotations

import re
from dataclasses import dataclass
from importlib import import_module
from importlib.util import find_spec
from typing import Callable
from urllib.parse import SplitResult, parse_qs, urlencode, urlsplit


@dataclass(frozen=True)
class LinkSource:
    id: str
    hosts: frozenset[str]
    normalize: Callable[[SplitResult], str]
    connector: str
    allow_schemeless: bool = False
    preserve_request_url: bool = False
    make_cache: Callable | None = None

    def acquire(self, *args, **kwargs):
        return import_module(self.connector, package=__package__).acquire(*args, **kwargs)


def normalize_wechat(url: SplitResult) -> str:
    query = parse_qs(url.query)
    if re.fullmatch(r'/s/[A-Za-z0-9_-]+/?', url.path):
        return 'https://mp.weixin.qq.com' + url.path.rstrip('/')
    if url.path == '/s' and all(query.get(key) for key in ('__biz', 'mid')):
        identity = {key: query[key][0] for key in ('__biz', 'mid')}
        identity['idx'] = query.get('idx', ['1'])[0]
        return 'https://mp.weixin.qq.com/s?' + urlencode(identity)
    raise ValueError('链接缺少微信公众号文章标识')


WECHAT = LinkSource(
    'wechat', frozenset({'mp.weixin.qq.com'}), normalize_wechat,
    '.connectors.wechat', preserve_request_url=True,
)

SOURCES = [WECHAT]
OPERATIONS = {}
PRIVATE_MODULES = find_spec(f'{__package__}.private_modules') is not None
if PRIVATE_MODULES:
    from . import private_modules
    SOURCES.extend(private_modules.sources(LinkSource))
    OPERATIONS.update(private_modules.OPERATIONS)

BY_HOST = {host: source for source in SOURCES for host in source.hosts}


def resolve_link(value: str) -> tuple[LinkSource, str]:
    value = value.strip()
    if '://' not in value:
        host = re.split(r'[/?#]', value, maxsplit=1)[0].lower()
        source = BY_HOST.get(host)
        if source and source.allow_schemeless:
            value = 'https://' + value
    parsed = urlsplit(value)
    if parsed.scheme not in ('http', 'https') or parsed.username or parsed.password:
        raise ValueError('请输入有效的采集链接')
    source = BY_HOST.get(parsed.hostname or '')
    if source is None:
        raise ValueError('此版本不支持该链接来源')
    return source, source.normalize(parsed)


def canonical_url(url: str) -> tuple[str, str]:
    source, normalized = resolve_link(url)
    return source.id, normalized
