from __future__ import annotations
import base64
import html
import mimetypes
import re
import shutil
from pathlib import Path
from urllib.parse import unquote, urlsplit


def local_path(reference: str, base: Path) -> Path | None:
    parsed=urlsplit(reference)
    if parsed.scheme in ('http','https','data','knowlake-source','mailto','javascript') or not parsed.path:
        return None
    if parsed.scheme=='file':
        candidate=Path(unquote(parsed.path)).resolve()
    elif parsed.scheme:
        return None
    else:
        candidate=(base/unquote(parsed.path)).resolve()
    if not candidate.is_relative_to(base.resolve()) or not candidate.is_file():
        return None
    return candidate


def data_url(path: Path) -> str:
    mime=mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
    return 'data:'+mime+';base64,'+base64.b64encode(path.read_bytes()).decode()


def inline_css(css: str, base: Path) -> str:
    def replacement(match):
        value=match.group(1).strip().strip('\"\'')
        path=local_path(value,base)
        return 'url("'+data_url(path)+'")' if path else match.group(0)
    return re.sub(r'url\(([^)]+)\)',replacement,css)


def standalone_html(content: str, base: Path, source: dict, segments: list) -> str:
    from bs4 import BeautifulSoup
    soup=BeautifulSoup(content,'html.parser')
    for tag in soup.find_all(['img','source','video','audio']):
        for attr in ('src','poster'):
            if tag.get(attr):
                path=local_path(str(tag[attr]),base)
                if path:
                    tag[attr]=data_url(path)
        if tag.has_attr('srcset'):
            # Prefer the already-inlined src rather than alternate local/network candidates.
            del tag['srcset']
    for link in soup.select('link[rel="stylesheet"][href]'):
        path=local_path(str(link['href']),base)
        if path:
            style=soup.new_tag('style')
            style.string=inline_css(path.read_text(),path.parent)
            link.replace_with(style)
    for script in soup.select('script[src]'):
        path=local_path(str(script['src']),base)
        if path:
            script.string=path.read_text().replace('</script','<\\/script')
            del script['src']
    for style in soup.find_all('style'):
        if style.string:
            style.string=inline_css(str(style.string),base)
    for tag in soup.select('[style]'):
        tag['style']=inline_css(str(tag['style']),base)
    for link in soup.select('a[href]'):
        value=str(link['href'])
        parsed=urlsplit(value)
        is_material = not parsed.scheme and parsed.path in ('source.md','./source.md')
        is_segment = not parsed.scheme and not parsed.path and parsed.fragment.startswith('segment-')
        if value.startswith('knowlake-source://') or is_material or is_segment:
            link['href']=source_reference(value,source,segments)
    return str(soup)


def source_reference(value: str, source: dict, segments: list) -> str:
    match=re.search(r'segment-(\d+)',value)
    url=source['url']
    if match and source['platform']=='bilibili':
        index=int(match.group(1))-1
        if 0<=index<len(segments):
            segment=segments[index]
            if segment.get('start',0)>=0 and segment.get('end',0)>segment.get('start',0):
                url+=('&' if '?' in url else '?')+'t='+str(int(segment['start']))
    return url


def export(store, params: dict) -> dict:
    details=store.get(params['id'])
    source=details['source']
    artifact_id=params.get('artifact_id')
    if artifact_id:
        candidates=[a for a in details['artifacts'] if a['id']==artifact_id]
        if not candidates:
            raise ValueError('未找到要导出的笔记')
        item=candidates[0]
        path=Path(item['path']);kind=item['kind']
    else:
        path=Path(details['content_path']);kind='markdown'
    output=Path(params['destination']).expanduser()
    output.parent.mkdir(parents=True,exist_ok=True)
    format=params.get('format','html')
    if kind=='image':
        raise ValueError('图片请使用 PNG 导出')
    content=path.read_text()
    if format in ('md','markdown'):
        if kind=='html':
            import markdownify
            content=markdownify.markdownify(content,heading_style='ATX')
        asset_dir=output.parent/(output.stem+'_assets')
        def replace(match):
            candidate=local_path(match.group(2),path.parent)
            if not candidate:
                return match.group(0)
            asset_dir.mkdir(exist_ok=True)
            destination=asset_dir/candidate.name
            if destination.exists() and destination.read_bytes()!=candidate.read_bytes():
                from .store import digest
                destination=asset_dir/(candidate.stem+'-'+digest(candidate)[:8]+candidate.suffix)
            shutil.copy2(candidate,destination)
            return '!['+match.group(1)+']('+asset_dir.name+'/'+destination.name+')'
        content=re.sub(r'!\[([^\]]*)\]\(([^)]+)\)',replace,content)
        content=re.sub(r'\]\((knowlake-source://[^)]+|(?:\./)?source\.md(?:#[^)]+)?|#segment-\d+)\)',lambda match:']('+source_reference(match.group(1),source,details['segments'])+')',content)
    elif format=='html':
        if kind=='markdown':
            from markdown_it import MarkdownIt
            # Source HTML is data; controlled segment anchors are added by the app reader.
            content=re.sub(r'<a id="segment-\d+"></a>\s*','',content)
            content=MarkdownIt('commonmark',{'html':False}).enable('table').render(content)
            content='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+html.escape(source['title'])+'</title><style>body{max-width:850px;margin:48px auto;padding:0 24px;font:17px/1.8 system-ui,sans-serif;color:#26302c;background:#fafbf8}img{max-width:100%;height:auto}pre{white-space:pre-wrap;padding:20px;background:#edf0e9}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:8px}a{color:#267a60}</style></head><body>'+content+'</body></html>'
        content=standalone_html(content,path.parent,source,details['segments'])
    else:
        raise ValueError('请选择 HTML 或 Markdown 格式')
    output.write_text(content,encoding='utf-8')
    return {'path':str(output.resolve())}
