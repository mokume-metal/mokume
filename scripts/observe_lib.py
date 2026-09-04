#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""観測面へ要求を置き、応答を待つ (#817)。

[ADR-0018](../docs/decisions/0018-observation-and-control-surface.md) 決定 3 が定める
やりとりの**唯一の実装**である。以前はこの手順が 2 か所にあり、しかも
`measure-frame-rate.sh` のコメント自身が「`check-observation-roundtrip.sh` と同じ形に
してある」と写しであることを自白していた
([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。

## 置き方

**tmp へ書いてから `os.replace` で名前を付け替える。** 直に `request.json` へ書くと、
読む側が書き途中の JSON を掴む。`os.replace` は同じファイルシステムの上で原子的なので、
読む側が見るのは「前の要求」か「新しい要求」のどちらかに必ずなる。

## 待ち方

**壁時計ではなく識別子の一致で完了を知る。** 「0.5 秒待ったから返ったはず」は、
遅い応答を取り違え、速い応答を待ちすぎる。`report.json` の `id` が置いた識別子に
一致した時点が完了である。

期限は呼び出し側が渡す。**固まりうる待ちには待つ側が期限を持たせる**のがこの
リポジトリの規律で (AGENTS.md「検査の『待たない』は待つ側が持つ」)、越えたら
`None` を返して呼び出し側に判断を委ねる。
"""

from __future__ import annotations

import json
import os
import pathlib
import time

# 応答を見に行く間隔 (秒)。**呼び出し側で変えられる** — 要求を置き続けて圧をかける側は
# 短くしたい (measure-frame-rate) が、1 回ずつ数える側はこれで足りる
POLL_SECONDS = 0.01


def place(facet: pathlib.Path, payload: dict) -> None:
    """要求を原子的に置く (ADR-0018 決定 3)。"""
    temporary = facet / ".request.json.tmp"
    temporary.write_text(json.dumps(payload))
    os.replace(temporary, facet / "request.json")


def answered(
    facet: pathlib.Path,
    identifier: str,
    deadline: float,
    poll: float = POLL_SECONDS,
) -> dict | None:
    """同じ識別子の応答が返るまで待つ。期限を越えたら None。

    **読めない `report.json` は「まだ来ていない」と読む。** 書き換えの途中を掴んだ場合と
    まだ存在しない場合を分ける意味が無い — どちらも次の周回で読み直せばよい。
    """
    limit = time.time() + deadline
    while time.time() < limit:
        try:
            report = json.loads((facet / "report.json").read_text())
            if report.get("id") == identifier:
                return report
        except Exception:
            pass
        time.sleep(poll)
    return None
