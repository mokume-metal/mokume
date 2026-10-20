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
リポジトリの規律で (AGENTS.md「場面別の入口」の「待ちを含む検査を書く」)、越えたら
`None` を返して呼び出し側に判断を委ねる。

## 別の書き手と取り合ったとき (#2857)

区画は要求も応答も 1 枚しか持たない。別の書き手が要求を置き換えると、**自分の識別子の応答は
二度と現れない**ことがある (応えた後に別の書き手の応答で上書きされた・読まれる前に置き換えられた)。
期限まで待って `None` を返すと、「応えなかった」と読め、走っていないと取り違える。

そこで、**request.json が自分の要求でなくなっていて、応答が「置く直前の応答」でも自分の応答でも
ない識別子を echo したら**、`Contested` を投げる (`Facets.exchange` と同じ規則)。当たったかは
分からない。呼び手は `place` が返した「置く直前の応答の識別子」を `answered` に渡す。
"""

from __future__ import annotations

import json
import os
import pathlib
import time

# 応答を見に行く間隔 (秒)。**呼び出し側で変えられる** — 要求を置き続けて圧をかける側は
# 短くしたい (measure-frame-rate) が、1 回ずつ数える側はこれで足りる
POLL_SECONDS = 0.01


class Contested(Exception):
    """別の書き手と区画を取り合い、自分の識別子の応答はもう来ない (#2857)。

    **当たったかどうかは分からない** — 応えた後に別の書き手の応答で上書きされたのか、読まれる前に
    置き換えられたのかは、応答だけからは見分けられない。走っていないという意味ではない。
    入力は送り直す前に状態を確かめ、`time` を添えない観測は撮り直してよい。
    """


def _read_json(path: pathlib.Path) -> dict | None:
    try:
        value = json.loads(path.read_text())
    except Exception:
        return None
    return value if isinstance(value, dict) else None


def _echo(facet: pathlib.Path) -> str | None:
    """`report.json` がいま echo している識別子。無い・読めなければ None。"""
    report = _read_json(facet / "report.json")
    identifier = report.get("id") if report else None
    return identifier if isinstance(identifier, str) else None


def _request_is_not_mine(facet: pathlib.Path, identifier: str) -> bool | None:
    """`request.json` が自分の要求でなくなっているか。

    **識別子が違っても、無くても、JSON として壊れていても True** (別の書き手が置き換えた)。
    自分の要求のままなら False。ファイルが無い・読めないときは None (判定を飛ばす)。
    """
    try:
        text = (facet / "request.json").read_text()
    except Exception:
        return None
    try:
        value = json.loads(text)
    except Exception:
        return True
    return not (isinstance(value, dict) and value.get("id") == identifier)


def place(facet: pathlib.Path, payload: dict) -> str | None:
    """要求を原子的に置く (ADR-0018 決定 3)。

    戻り値は、**置く直前に `report.json` が echo していた識別子** (無ければ None)。`answered` の
    `before` に渡すと、別の書き手との取り合いを見分けられる (#2857)。
    """
    before = _echo(facet)
    temporary = facet / ".request.json.tmp"
    temporary.write_text(json.dumps(payload))
    os.replace(temporary, facet / "request.json")
    return before


def answered(
    facet: pathlib.Path,
    identifier: str,
    deadline: float,
    poll: float = POLL_SECONDS,
    before: str | None = None,
) -> dict | None:
    """同じ識別子の応答が返るまで待つ。期限を越えたら None。

    **読めない `report.json` は「まだ来ていない」と読む。** 書き換えの途中を掴んだ場合と
    まだ存在しない場合を分ける意味が無い — どちらも次の周回で読み直せばよい。

    `request.json` が自分の要求でなくなり、応答が `before` (置く直前の応答・`place` の戻り値) でも
    自分のものでもない識別子を echo したら `Contested` を投げる。`request.json` が自分の要求の間は
    決着にしない (別の書き手へ応えている途中の応答は、その後に自分の要求へも応えうる)。
    """
    # 期限は眠っている間は進まない時計で測る。壁時計 (`time.time`) だと、待っている最中に
    # 眠ると起きた瞬間に期限を越え、応答を待たずに None を返す (#1940)。道具側の対
    # (`Facets.exchange`) も同じ種類の時計で測る
    limit = time.monotonic() + deadline
    while time.monotonic() < limit:
        report = _read_json(facet / "report.json")
        if report is not None:
            echoed = report.get("id")
            if echoed == identifier:
                return report
            if (
                isinstance(echoed, str)
                and echoed != before
                and _request_is_not_mine(facet, identifier) is True
            ):
                raise Contested(
                    f"区画を別の書き手と取り合った (自分は {identifier!r}・応答は {echoed!r})"
                )
        time.sleep(poll)
    return None
