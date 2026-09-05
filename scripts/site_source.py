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

## 引けなかったときの向き ([#865](https://github.com/mokume-metal/mokume/issues/865))

**「無い」と「引けなかった」は混ぜない。** 404 は `None`、それ以外は `Unreachable` を
投げる。混ぜると [#478](https://github.com/mokume-metal/mokume/issues/478) が塞いだ
「置いても出ない」の検出が緩む — 公開物が置かれていないことと、公開先が落ちている
ことは、直す人も直し方も違う。

**引けなかったことは 1 行で名乗る。** 呼び出し側はどちらも問題を 1 行ずつ並べる形なのに、
引けなかったときだけ Python の traceback が出ていた ([ADR-0027](../docs/decisions/0027-readable-surfaces.md)
の読める面と揃っていない)。`check-external-assets.py` の `reachable` は元から理由を
文字列で名乗っており、そちらが先例である。

**判定は赤のままにする。** この読み口を呼ぶ 3 経路 — `pages.yml` (公開の直後)・
`publication.yml` (日次)・`Makefile` (手元の `_site`) — は**どれも merge の条件では
ない**ので、赤が誰かの作業を止めない。`publication.yml` が「相手側の一時的な不調が
こちらの赤になる」と書いているのは**置き場の切り分け**であって (ネットワークを踏む検査を
merge の条件に混ぜない)、赤にしないという意味ではない — 同じ節が「赤くするだけで、
起票はしない」と続けている。
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


class Unreachable(Exception):
    """公開先を引けなかった。**「置いていない」とは混ぜない** (上の節)。

    受けるのは呼び出し側の `main` で、1 行に落として赤で返す。握り潰さないのは
    「引けなかった」を緑にすると、配信の事故が誰にも見られなくなるためである。
    """


class Source:
    """出力の読み口。ディレクトリでも URL でも同じ形で引けるようにする。"""

    def __init__(self, target: str) -> None:
        self.target = target.rstrip("/")
        self.is_url = self.target.startswith(("http://", "https://"))
        if not self.is_url:
            self.root = pathlib.Path(self.target)

    def read(self, relative: str) -> bytes | None:
        """無ければ None、引けなければ `Unreachable`。向きは冒頭の節が持つ。"""
        if self.is_url:
            url = f"{self.target}/{relative}"
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(url), timeout=FETCH_TIMEOUT_SECONDS
                ) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                # **例外そのものが応答なので閉じる。** 閉じないと ResourceWarning が
                # 残る (check-publication.py の read_stamp が同じ理由で閉じている)
                error.close()
                if error.code == 404:
                    return None
                raise Unreachable(f"{url} が引けない (HTTP {error.code})") from error
            except Exception as error:
                # 証明書・名前解決・接続断・待ち切れ。**HTTPError の後ろに置く**
                # (HTTPError は URLError の派生なので、上の枝で先に捕まる)
                raise Unreachable(f"{url} が引けない: {error}") from error
        path = self.root / relative
        return path.read_bytes() if path.is_file() else None

    def read_json(self, relative: str) -> dict | None:
        raw = self.read(relative)
        return json.loads(raw.decode("utf-8")) if raw is not None else None
