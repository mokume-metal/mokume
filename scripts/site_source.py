#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""公開物の読み口と、公開物を読むときの綴り (#815)。

面を検める検査は 3 本あり (`check-entry.py` / `check-published-reference.py` /
`check-external-assets.py`)、`pages.yml` と `publication.yml` から**必ず一緒に**
呼ばれる。以前はこの 3 本 + `check-publication.py` が、読み口・タイムアウト・
`<img>` の綴りをそれぞれ写しで持っていた。

**畳む理由は 3 本が揃って持っている設計意図である。** どれも「手元で組んだ `_site`
にも、公開された URL にも、同じ形で当てられる」ようにしてある — 配信の事故と
組み立ての事故を切り分けるためで、片方だけ直すとその切り分けが崩れる
([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。

**前例あり。** `check-external-assets.py` は `check-docs-links.py` の `mask_code` を
`importlib` で「写さずに借りて」おり、その理由 (「2 箇所に置くと片方だけが直る」) が
そのままここに当たる。こちらはハイフンを含まない名前なので素の import で足りる。

## ここに無いもの

**引けなかったときの向きは、まだ 1 つになっていない。** `Source.read` は 404 を
`None`、それ以外を `raise` にするが、`check-publication.py` の `read_stamp` は
理由を文字列で返して例外を投げない。向きを揃えるのは
[#820](https://github.com/mokume-metal/mokume/issues/820) で扱う — 502 を 1 回
引いただけで赤が立つかどうかという**振る舞いの変更**を含むので、写しを畳む話とは
分けてある。
"""

from __future__ import annotations

import json
import pathlib
import re
import urllib.error
import urllib.request

# 相手を待つ上限。**3 本で同じ値である必要がある** — 揃っていないと、同じ公開先に
# 対して「手元では通るが公開先だけ落ちる」が起きる
FETCH_TIMEOUT_SECONDS = 30

# HTML の絵 `<img src="https://…">`。
#
# **`src` の直前で属性の切れ目を要求する。** 要求しないと `data-src=` の末尾に
# 一致してしまい、絵として飾ってあるだけのものを本物と数える。
HTML_IMAGE = re.compile(
    r"""<img\s[^>]*?(?<![-\w])src=["'](https?://[^"']+)["']""",
    re.IGNORECASE,
)


class Source:
    """出力の読み口。ディレクトリでも URL でも同じ形で引けるようにする。"""

    def __init__(self, target: str) -> None:
        self.target = target.rstrip("/")
        self.is_url = self.target.startswith(("http://", "https://"))
        if not self.is_url:
            self.root = pathlib.Path(self.target)

    def read(self, relative: str) -> bytes | None:
        """無ければ None。**例外は握り潰さない** — 読めなかった理由は呼び出し側が言う。"""
        if self.is_url:
            request = urllib.request.Request(f"{self.target}/{relative}")
            try:
                with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                raise
        path = self.root / relative
        return path.read_bytes() if path.is_file() else None

    def read_json(self, relative: str) -> dict | None:
        raw = self.read(relative)
        return json.loads(raw.decode("utf-8")) if raw is not None else None
