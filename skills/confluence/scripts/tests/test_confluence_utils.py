# -*- coding: utf-8 -*-
"""Tests for the builder / preview / diff helpers in confluence_utils.
Run: python -m pytest test_confluence_utils.py
or:  python test_confluence_utils.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import confluence_utils as cu


def _run(name, fn):
    fn()
    print(f'PASS  {name}')


def test_code_block_no_lang():
    out = cu.code_block('SELECT 1')
    assert '<ac:structured-macro ac:name="code"' in out
    assert '<ac:plain-text-body><![CDATA[SELECT 1]]></ac:plain-text-body>' in out
    assert '<ac:parameter ac:name="language">' not in out


def test_code_block_emits_valid_macro_tag():
    """Regression: schema-version attribute must close its quote before the
    space before ac:macro-id. Earlier the f-string was split mid-quote, so
    Confluence's xerces parser rejected the page with HTTP 400.
    """
    out = cu.code_block('SELECT 1')
    assert 'ac:schema-version="1" ac:macro-id=' in out, out
    assert 'ac:schema-version="1 ac:' not in out, out


def test_macro_emits_valid_macro_tag():
    """Regression: same split-quote bug as code_block."""
    out = cu.macro('warning', '<p>x</p>')
    assert 'ac:schema-version="1" ac:macro-id=' in out, out
    assert 'ac:schema-version="1 ac:' not in out, out


def test_code_block_with_lang():
    out = cu.code_block('var x = 1;', 'javascript')
    assert '<ac:parameter ac:name="language">javascript</ac:parameter>' in out
    assert '<![CDATA[var x = 1;]]>' in out
    assert cu.check_xhtml_balance(out) == []


def test_table():
    out = cu.table(['A', 'B'], [['1', '2'], ['3', '4']])
    assert out.startswith('<table class="wrapped">')
    assert '<th' in out and '<td>2</td>' in out and '<td>4</td>' in out
    assert cu.check_xhtml_balance(out) == []


def test_macro_warning():
    out = cu.macro('warning', '<p>小心</p>')
    assert 'ac:name="warning"' in out
    assert '<ac:rich-text-body><p>小心</p></ac:rich-text-body>' in out
    assert cu.check_xhtml_balance(out) == []


def test_image_and_heading_and_bullets():
    img = cu.image_attachment('x.png', height=250)
    assert 'ac:height="250"' in img and 'ri:filename="x.png"' in img
    h = cu.heading(2, 'Заголовок')
    assert h == '<h2><span>Заголовок</span></h2>'
    assert cu.heading(1, 'X').startswith('<h1>')
    b = cu.bullet('item')
    assert b.startswith('<li>') and 'item' in b
    li = cu.li('uuid-1', '<p>inner</p>')
    assert li == '<li data-uuid="uuid-1"><p>inner</p></li>'


def test_xhtml_detects_extra_close_with_location():
    bad = '<ul><li>a</li></li></ul>'  # extra </li>
    w = cu.check_xhtml_balance(bad)
    assert len(w) == 1
    assert 'extra close' in w[0]
    assert 'char' in w[0]  # location present


def test_xhtml_detects_unclosed_with_location():
    bad = '<p><strong>oops</p>'  # unclosed <strong>
    w = cu.check_xhtml_balance(bad)
    assert any('unclosed' in x and 'strong' in x and 'char' in x for x in w)


def test_xhtml_cdata_aware():
    # HTML-like content inside a code block must NOT be counted as tags
    body = cu.code_block('<div><span>not real html</span></div>', 'html')
    assert cu.check_xhtml_balance(body) == []


def test_xhtml_balanced_passes():
    body = '<ul><li>1</li><li>2</li></ul>'
    assert cu.check_xhtml_balance(body) == []


def test_storage_to_markdown_basics():
    body = (
        cu.heading(2, 'Title')
        + '<p>Plain <strong>bold</strong> and <code>code</code>.</p>'
        + '<ul><li>one</li><li>two</li></ul>'
        + cu.code_block('SELECT 1', 'sql')
    )
    md = cu.storage_to_markdown(body)
    assert '## Title' in md
    assert '**bold**' in md
    assert '`code`' in md
    assert '- one' in md and '- two' in md
    assert '```sql' in md and 'SELECT 1' in md


def test_storage_to_markdown_table_and_link_and_image():
    body = (
        '<p><a href="https://x.by">link</a></p>'
        + cu.image_attachment('pic.png')
        + cu.table(['k', 'v'], [['a', '1']])
    )
    md = cu.storage_to_markdown(body)
    assert '[link](https://x.by)' in md
    assert 'pic.png' in md  # image referenced
    assert '| k | v |' in md and '| a | 1 |' in md


def test_storage_to_markdown_warning_macro():
    body = cu.macro('warning', '<p>storm limit</p>')
    md = cu.storage_to_markdown(body)
    assert 'storm limit' in md
    assert 'warning' in md.lower()


def test_diff_bodies_changes():
    old = '<p>a</p><p>b</p>'
    new = '<p>a</p><p>c</p>'
    d = cu.diff_bodies(old, new)
    assert d != 'no changes'
    assert 'c' in d


def test_diff_bodies_equal():
    assert cu.diff_bodies('<p>a</p>', '<p>a</p>') == 'no changes'


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            _run(name, fn)
    print('\nALL TESTS PASSED')


if __name__ == '__main__':
    main()