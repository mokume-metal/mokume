#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""公開の起動条件が、面の入力を覆っているかを見る (#478)。

**塞ぐのは「ビルドは緑のまま、公開だけが古い」である。** 公開のワークフローに
`paths` の絞りを書くと、それは公開に使う入力の**写し**になる — 入力が増えたときに
絞りを直し忘れると、その入力だけを変えた push でサイトが更新されない。ビルドは
緑・PR も緑で、気付く手掛かりは公開物を人が見たときにしか無い
([ADR-0027](../docs/decisions/0027-readable-surfaces.md) 決定 3)。

**だから「絞りと入力を突き合わせる」ではなく「絞りを持たせない」を検査する。**
突き合わせる形にすると、入力の一覧という 2 つ目の写しが要る。持たせなければ
`main` への push はすべて公開を通るので、覆っていることが構造で決まり、
照合そのものが要らなくなる ([ADR-0001](../docs/decisions/0001-founding-principles.md)
原則 8 の「規約でなく構造で保証する」)。

**公開のワークフローは名前で決め打ちしない。** 面を組み立てる `make` の的を
呼んでいるものを探す。ファイル名を書くと、名前を変えた瞬間に検査は「対象が無い」
ではなく「見つからないので緑」に倒れうる — 0 件は必ず落とす。

YAML の読み取りは ruby に任せる (`scripts/check-github-yaml.sh` と同じ理由で、
macOS / ubuntu のランナー双方に既在で追加の依存が要らない)。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

# 面を組み立てる的。これを呼ぶワークフローが「公開のワークフロー」である
PUBLISH_TARGET = "make reference"
# 覆っていなければならない起動条件
REQUIRED_BRANCH = "main"
NARROWING_KEYS = ("paths", "paths-ignore")


def load_yaml(path: pathlib.Path) -> dict:
    """YAML を JSON 経由で読む。パスは ARGV で渡す (コードに埋めるとクォートが壊れる)。"""
    completed = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts YAML.load_file(ARGV[0]).to_json", "--", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


def triggers_of(document: dict) -> dict:
    """`on:` の中身。

    **鍵が `on` とは限らない。** YAML 1.1 は裸の `on` を真偽値として読むので、
    ruby を通した時点で鍵は `true` になる (JSON へ写すと文字列 `"true"`)。
    引用符付きで書かれていれば `on` のまま来るので、両方を見る。
    """
    for key in ("on", "true", True):
        if key in document:
            value = document[key]
            return value if isinstance(value, dict) else {}
    return {}


def problems_of(path: pathlib.Path, document: dict) -> list[str]:
    triggers = triggers_of(document)
    if not triggers:
        return [f"{path}: 起動条件 (on:) が読み取れない"]

    problems: list[str] = []
    push = triggers.get("push")
    if not isinstance(push, dict):
        problems.append(f"{path}: push の起動条件が無い — main への push で公開が起きない")
    else:
        branches = push.get("branches") or []
        if REQUIRED_BRANCH not in branches:
            problems.append(f"{path}: push の branches に {REQUIRED_BRANCH} が無い ({branches})")

    for event, condition in triggers.items():
        if not isinstance(condition, dict):
            continue
        for key in NARROWING_KEYS:
            if key in condition:
                problems.append(
                    f"{path}: {event} に {key} の絞りがある — "
                    "公開の入力の写しになり、増えた入力を取り逃す"
                )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workflows",
        type=pathlib.Path,
        default=pathlib.Path(".github/workflows"),
        help="ワークフローの置き場 (既定: .github/workflows)",
    )
    arguments = parser.parse_args()

    candidates = sorted(
        [
            path
            for path in list(arguments.workflows.glob("*.yml"))
            + list(arguments.workflows.glob("*.yaml"))
            if PUBLISH_TARGET in path.read_text(encoding="utf-8")
        ]
    )

    # 0 件を緑にしない。公開のワークフローが消えた・的の名前が変わったのを
    # 「検査対象が無いので通った」で見逃すと、この検査は何も守らなくなる
    if not candidates:
        print(
            f"`{PUBLISH_TARGET}` を呼ぶワークフローが {arguments.workflows} に無い — "
            "公開の経路が存在しないか、的の名前が変わっている",
            file=sys.stderr,
        )
        return 1

    problems: list[str] = []
    for path in candidates:
        problems += problems_of(path, load_yaml(path))

    if problems:
        print("公開の起動条件が面の入力を覆っていない:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\n`paths` で絞らず、main への push すべてで公開を通す。"
            "絞りは公開の入力の写しになり、写しは必ず古くなる。",
            file=sys.stderr,
        )
        return 1

    names = ", ".join(path.name for path in candidates)
    print(f"ok: {names} は main への push すべてで走り、入力を絞っていない")
    return 0


if __name__ == "__main__":
    sys.exit(main())
