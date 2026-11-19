"""WeChat parsing adapted from the user's existing wechat-to-md archive skill."""
from __future__ import annotations
import asyncio
import contextlib
from http.client import HTTPException
import os
import sys
from pathlib import Path

from .web import fetch, save_image
from .wechat_parser import extract_metadata, process_content
from .wechat_converter import convert_html_to_markdown, replace_image_urls
from ..acquisition_support import report
from ..markdown_source import snapshot_segments
from ..store import DuplicateSource, canonical_url


async def browser_html(url: str, options: dict) -> str:
    try:
        from camoufox.async_api import AsyncCamoufox
    except ImportError as exc:
        raise RuntimeError('网页需要浏览器提取，请安装公众号浏览器组件（uv sync --extra wechat-browser），并在设置中选择 Camoufox。') from exc
    executable=options.get('browser_path') or os.environ.get('CAMOUFOX_EXECUTABLE_PATH')
    kwargs={'headless':True}
    if executable:
        kwargs['executable_path']=executable
        # Explicit macOS browser bundles keep application.ini under Resources.
        import configparser
        binary=Path(executable).expanduser().resolve()
        config=configparser.ConfigParser()
        config.read([str(binary.parent/'application.ini'),str(binary.parent.parent/'Resources'/'application.ini')])
        if config.has_option('App','Version'):
            kwargs['ff_version']=int(config['App']['Version'].split('.')[0])
    async with AsyncCamoufox(**kwargs) as browser:
        page=await browser.new_page()
        await page.goto(url,wait_until='domcontentloaded',timeout=45000)
        with contextlib.suppress(Exception):
            await page.wait_for_selector('#js_content',timeout=10000)
        return await page.content()


def page_error(soup, html: str) -> str | None:
    if soup.select_one('#js_content'):
        return None
    text = soup.get_text(' ', strip=True)
    if any(token in html for token in ('js_verify', 'wappoc_appmsgcaptcha', '环境异常', '请完成安全验证')):
        return '公众号需要验证码验证，请在浏览器完成验证后重试。'
    if '参数错误' in text:
        return '微信公众号返回“参数错误”，请重新复制完整文章链接后重试。'
    if any(token in text for token in ('该内容已被发布者删除', '该内容已被删除', '内容已删除', '此内容因违规无法查看', '该内容暂时无法查看')):
        return '微信公众号提示文章已删除或无法查看。'
    if any(token in text for token in ('请先登录', '登录后查看', '登录后访问')):
        return '该公众号文章需要登录后查看，请在浏览器确认访问权限。'
    return None


def acquire(url: str, directory: Path, options: dict, progress, *, check_duplicate=None) -> dict:
    report(progress, '正在获取公众号正文', 'fetch', 'started')
    try:
        result = _acquire(url, directory, options, progress, check_duplicate)
    except DuplicateSource:
        raise
    except Exception as exc:
        report(progress, str(exc), 'fetch', 'failed')
        raise
    message = '公众号正文已获取，部分图片未能保存' if result['metadata']['warnings'] else '公众号正文与图片已获取'
    report(progress, message, 'fetch', 'completed')
    return result


def _acquire(url: str, directory: Path, options: dict, progress, check_duplicate) -> dict:
    from bs4 import BeautifulSoup
    try:
        html=fetch(url,{'Referer':'https://mp.weixin.qq.com/'}).decode('utf-8',errors='replace')
    except (OSError, HTTPException):
        html = ''
        report(progress, '直接读取失败，正在使用浏览器读取文章', 'fetch')
    soup=BeautifulSoup(html,'html.parser')
    if error := page_error(soup, html):
        raise RuntimeError(error)
    if not soup.select_one('#js_content'):
        if html:
            report(progress, '正在使用浏览器读取文章', 'fetch')
        with contextlib.redirect_stdout(sys.stderr):
            html=asyncio.run(browser_html(url,options))
        soup=BeautifulSoup(html,'html.parser')
    if error := page_error(soup, html):
        raise RuntimeError(error)
    identity = canonical_url(url)[1]
    aliases = [identity]
    canonical=soup.select_one('meta[property="og:url"]')
    if canonical and canonical.get('content'):
        with contextlib.suppress(ValueError):
            platform, article_identity = canonical_url(str(canonical['content']))
            if platform == 'wechat':
                identity = article_identity
                aliases.append(identity)
    if check_duplicate:
        check_duplicate(*aliases)
    metadata=extract_metadata(soup,html,url)
    parsed=process_content(soup)
    content=convert_html_to_markdown(parsed.content_html,parsed.code_blocks)
    if not metadata.title or not content.strip():
        raise ValueError('公众号页面未提供可解析的文章标题或正文，请在浏览器检查页面后重试。')
    report(progress, '正在保存文章图片', 'fetch')
    mapping={}
    warnings=[]
    for index,image_url in enumerate(parsed.image_urls):
        try:
            mapping[image_url]=save_image(image_url,directory,f'image-{index+1}',url)
        except Exception as exc:
            warnings.append(f'图片 {index+1} 下载失败')
            print(str(exc),file=sys.stderr)
    content=replace_image_urls(content,mapping)
    if parsed.media_references:
        content+='\n\n## 音视频引用\n'+'\n'.join(f'- [{ref.name}]({ref.src})' if ref.src else f'- {ref.name}' for ref in parsed.media_references)
    # Source paragraph IDs are stable within this source snapshot.
    body, segments = snapshot_segments(content)
    content=f'# {metadata.title}\n\n[原文]({url})\n\n'+body
    (directory/'original.html').write_text(html,encoding='utf-8')
    first_image=next(iter(mapping.values()),None)
    thumbnail=str(Path(first_image).with_name(Path(first_image).stem+'-thumb.jpg')) if first_image else None
    return {'url':url,'title':metadata.title,'content':content,'segments':segments,
            'metadata':{'author':metadata.author,'published_at':metadata.publish_time,
                        'identity_url':identity,'aliases':list(dict.fromkeys(aliases)),
                        'image_path':thumbnail,'warnings':warnings,
                        'status':'partial' if warnings else 'ready'}}
