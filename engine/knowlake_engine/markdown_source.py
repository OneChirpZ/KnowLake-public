"""Archive text submitted by the user as an independent local source."""
import re
import uuid

from .acquisition_support import recycle


def snapshot_segments(markdown: str) -> tuple[str, list[dict]]:
    segments = [
        {"start": 0.0, "end": 0.0, "text": block}
        for block in split_blocks(markdown) if block.strip()
    ]
    body = "\n\n".join(
        f'<a id="segment-{index}"></a>\n\n{segment["text"]}'
        for index, segment in enumerate(segments, 1)
    )
    return body, segments


def import_markdown(store, params: dict) -> dict:
    markdown = params["markdown"].strip()
    if not markdown:
        raise ValueError("请输入 Markdown 正文")
    title = params.get("title", "").strip()
    if not title:
        heading = re.match(r"^#{1,6}[ \t]+([^\n]+)", markdown)
        title = heading[1].strip() if heading else "Markdown 资料"
    body, segments = snapshot_segments(markdown)
    identifier = uuid.uuid4().hex
    work = store.root / "cache" / ("import-" + identifier)
    work.mkdir(parents=True)
    try:
        return store.insert_source(
            "knowlake-local://" + identifier, "markdown", title, body,
            segments, work, {}, collection=params.get("collection"),
        )
    finally:
        if work.exists():
            recycle(work)


def split_blocks(markdown: str) -> list[str]:
    blocks=[]
    current=[]
    fence=None
    for line in markdown.splitlines():
        stripped=line.lstrip()
        marker='```' if stripped.startswith('```') else '~~~' if stripped.startswith('~~~') else None
        if marker:
            fence=None if fence==marker else marker if fence is None else fence
        if not line.strip() and fence is None:
            if current:
                blocks.append('\n'.join(current));current=[]
        else:
            current.append(line)
    if current:
        blocks.append('\n'.join(current))
    return blocks
