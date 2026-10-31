#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の job (host-scheduled.yml の mutation) が点数を置く、追跡用 Issue の読み書き (#3221)。

追跡用の Issue は固定タイトルで 1 本だけ立ち、本文の**機械の区画**に最新の点数・帰属・生き残り・
履歴と、次の回が読む状態 (前回の点数の commit・前回の生き残り・読めなかった回の連続回数) を持つ。
区画の外 (人が書いた説明) は触らない。区画の書き換えは通知されないので、毎日の更新が通知を
積まない。

このファイルは**読む側と書く側が共有する部品**だけを持つ:

    python3 scripts/mutation_state.py previous     前回の点数の commit (range_head) を出す

`previous` は変異を回す job (`issues: read` だけを持つ) が呼ぶ。書き込む側は
`scripts/report-mutation.py` で、別のファイルにしてあるのは scripts/tests/workflow_permissions_test.py が
**スクリプト単位**で書き込みの権限を見るため — 同じファイルに gh issue edit を置くと、読むだけの job に
`issues: write` を渡さないと検査が赤になる。

`previous` は**読めなかったことと、無いことを分ける**: 追跡用の Issue が無い・区画が無いときは何も
出さず 0 で終わる (最初の回)。gh が失敗した・区画の状態が読めないときは 1 で終わる。呼び手は 1 を
「前回を知らない」として範囲を回さず、そう名乗る。

検査は scripts/tests/report_mutation_test.py (make hooks-test)。
"""

import json
import re
import subprocess
import sys

# 重複起票を防ぐ固定タイトル。変えると、変える前に立った Issue が見つからず二重に立つ。
# 接頭辞が `chore(` なので triage.sh が Task を付ける
TITLE = "chore(test): 変異の検査の点数と帰属 (定期の job が自動更新する追跡用)"

BEGIN = "<!-- mutation-state:begin (機械の区画。scripts/report-mutation.py が書き換える。ここは直さない) -->"
END = "<!-- mutation-state:end -->"

# 区画の中の名前つきの塊 (固定の束の表・範囲の表)。読めなかった回に、前の回の表を残すため別々に持つ
BLOCKS = ("bundle", "range")

META = re.compile(r"^<!-- mutation-state meta=(\{.*\}) -->$", re.M)
SHA = re.compile(r"^[0-9a-f]{40}$")


def encode_meta(meta):
    """状態を 1 行の HTML コメントにする。`--` は HTML コメントを閉じかねないので JSON の escape に置く。"""
    text = json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "<!-- mutation-state meta=" + text.replace("--", "-\\u002d") + " -->"


def read_meta(body):
    """本文の区画の状態。区画が無い・状態が読めないときは None。"""
    found = META.findall(body or "")
    if not found:
        return None
    try:
        meta = json.loads(found[-1])
    except ValueError:
        return None
    return meta if isinstance(meta, dict) else None


def section_bounds(body):
    """区画 (begin から end の行まで) の (始まり, 終わり) の文字位置。begin と end が揃わなければ None。"""
    start = body.find(BEGIN)
    if start < 0:
        return None
    end = body.find(END, start)
    if end < 0:
        return None
    return start, end + len(END)


def replace_section(body, section):
    """本文の区画を差し替える。無ければ末尾に足す (片方だけある壊れた区画で人の文を巻き込まない)。"""
    bounds = section_bounds(body)
    if bounds is None:
        return body.rstrip("\n") + "\n\n" + section + "\n"
    return body[: bounds[0]] + section + body[bounds[1]:]


def block_markers(name):
    return f"<!-- mutation-state:{name} -->", f"<!-- mutation-state:{name}-end -->"


def wrap_block(name, text):
    begin, end = block_markers(name)
    return f"{begin}\n{text.strip(chr(10))}\n{end}"


def read_block(body, name):
    """区画の中の名前つきの塊 (最後に読めた回のもの)。無ければ空。"""
    bounds = section_bounds(body)
    if bounds is None:
        return ""
    inner = body[bounds[0]: bounds[1]]
    begin, end = block_markers(name)
    start, stop = inner.find(begin), inner.find(end)
    if start < 0 or stop < start:
        return ""
    return inner[start + len(begin): stop].strip("\n")


def gh_json(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout or "null")


def find_issue():
    """open な追跡用 Issue の番号。無ければ None。タイトルは完全一致で絞る (検索は前方一致を含む)。"""
    rows = gh_json("issue", "list", "--state", "open", "--search", f'"{TITLE}" in:title',
                   "--json", "number,title")
    for row in rows or []:
        if row.get("title") == TITLE:
            return row["number"]
    return None


def issue_body(number):
    return (gh_json("issue", "view", str(number), "--json", "body") or {}).get("body") or ""


def previous():
    """前回の点数の commit。(commit か None, 読めなかった理由か None)。"""
    try:
        number = find_issue()
        if number is None:
            return None, None
        meta = read_meta(issue_body(number))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        return None, f"追跡用の Issue を読めなかった ({error})"
    if meta is None:
        return None, None
    head = meta.get("range_head")
    if head is None:
        return None, None
    if not isinstance(head, str) or not SHA.match(head):
        return None, f"区画の range_head が commit に読めない ({head!r})"
    return head, None


def main(argv):
    if argv[1:] != ["previous"]:
        print("使い方: mutation_state.py previous", file=sys.stderr)
        return 64
    head, problem = previous()
    if problem:
        print(f"mutation_state: {problem}", file=sys.stderr)
        return 1
    if head:
        print(head)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
