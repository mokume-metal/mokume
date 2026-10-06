#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""gh issue create / edit の断片から、Issue の本文を取り出す (#2195)。

    python3 scripts/gh_issue_body.py <断片> <chdir の列> <cwd>

読み手は scripts/issue-evidence-guard.sh で、断片と列の意味は guard-lib.sh の
gh_invocations が持つ。本文を標準出力へ出して 0、取り出せなければ 1 (フックは素通し)。

- `--body-file` / `-F <パス>`: ファイルを読む。相対パスは cwd から。宛先を cwd から決め
  られない呼び出し (chdir が 1)・`-`・読めないパスは取り出せない
- `--body` / `-b <本文>`: 断片の語から取る。引用の中の空白・改行は \\002 に伏せて届くので
  空白に戻す (改行は戻らない)。語は 4096 バイトで切られて届くので、それ以上は取り出せない
"""

from __future__ import annotations

import os
import shlex
import sys

WORD_CAP = 4096
FLAGS = {"-b": "body", "--body": "body", "-F": "file", "--body-file": "file"}


def options(fragment: str) -> dict[str, str]:
    """断片の中の本文の旗を {"body" | "file": 値} で返す (後勝ち)。"""
    words = shlex.split(fragment.replace("\x02", " "), posix=True)
    found: dict[str, str] = {}
    for i, word in enumerate(words):
        name, eq, value = word.partition("=")
        if eq and name in ("--body", "--body-file"):
            found[FLAGS[name]] = value
        elif word in FLAGS and i + 1 < len(words):
            found[FLAGS[word]] = words[i + 1]
    return found


def body_of(fragment: str, chdir: str, cwd: str) -> str | None:
    try:
        found = options(fragment)
    except ValueError:
        return None
    if "file" in found:
        path = found["file"]
        if path == "-" or (chdir == "1" and not os.path.isabs(path)):
            return None
        try:
            with open(os.path.join(cwd, path), encoding="utf-8") as f:
                return f.read()
        except (OSError, UnicodeDecodeError):
            return None
    body = found.get("body")
    if body is None or len(body.encode("utf-8")) >= WORD_CAP:
        return None
    return body


def main(argv: list[str]) -> int:
    body = body_of(*argv[1:4])
    if body is None:
        return 1
    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
