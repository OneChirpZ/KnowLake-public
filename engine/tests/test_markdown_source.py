import pytest

from knowlake_engine.store import Store
from knowlake_engine.worker import dispatch


def test_local_markdown_import_archives_body_and_citation_anchors(tmp_path):
    store = Store(tmp_path / "library")
    source = dispatch(store, "import_markdown", {
        "markdown": "# Fixture\n\nA paragraph.\n\n```text\nLine\n\nLine\n```",
        "collection": "Notes",
    })["source"]
    detail = store.get(source["id"])
    assert source["title"] == "Fixture"
    assert source["platform"] == "markdown"
    assert source["url"].startswith("knowlake-local://")
    assert source["collection"] == "Notes"
    assert detail["content"].count('<a id="segment-') == 3
    assert detail["segments"][2]["text"] == "```text\nLine\n\nLine\n```"
    assert len(dispatch(store, "list", {"query": "paragraph"})["items"]) == 1
    with pytest.raises(ValueError, match="Markdown"):
        dispatch(store, "import_markdown", {"markdown": "  "})
    store.close()
