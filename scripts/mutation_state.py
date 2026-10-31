#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の job (host-scheduled.yml の mutation) が点数を置く、追跡用 Issue の読み書き (#3221)。

追跡用の Issue は固定タイトルで 1 本だけ立ち、本文の**機械の区画**に最新の点数・帰属・生き残り・
履歴と、次の回が読む状態 (メタ: 前回の点数の commit・前回の生き残り・読めなかった回の連続回数・
履歴) を持つ。区画の外 (人が書いた説明) は触らない。区画の書き換えは通知されない
ので、毎日の更新が通知を積まない。

このファイルは**読む側と書く側が共有する部品**だけを持つ:

    python3 scripts/mutation_state.py previous [--github-output F] [--summary F]

`previous` は変異を回す job (`issues: read` だけを持つ) が呼ぶ。書き込む側は
`scripts/report-mutation.py` で、別のファイルにしてあるのは scripts/tests/workflow_permissions_test.py が
**スクリプト単位**で書き込みの権限を見るため — 同じファイルに gh issue edit を置くと、読むだけの job に
`issues: write` を渡さないと検査が赤になる。

## 状態の読み方 (`parse_state`)

本文は `\\r\\n` を `\\n` に直してから読む (web の編集で CRLF になっても、メタの行が黙って読めなくなって
最初の回に戻らない)。メタは**区画の中からだけ**読む (区画の外の同じ形の行は人の文で、読まない)。

    none     区画が無い。最初の回として扱う
    ok       区画が 1 つで、メタが 1 行あり、型が約束どおり
    broken   区画が 2 つ以上 / メタが無い・2 行ある・壊れた JSON / 型が違う (理由つき)

**broken を最初の回と読まない** — 起点・履歴・既知の生き残りが黙って消えるため。読む側 (`previous`) は
`unreadable-state` と名乗り、書く側 (report-mutation.py) は区画を作り直してコメントで名乗る。

## `previous` の結果 (`reason`)

    ok                前回の点数の commit が木にあり、HEAD の祖先である → 範囲を回す
    first             追跡用の Issue / 区画 / 起点が無い (最初の回) → 範囲は回さず、起点を置く
    missing-commit    起点が木に無い、または HEAD の祖先でない (履歴の書き換え・別の枝の run) → 範囲は回さず、
                      報告が名乗ったうえで起点を HEAD へ置き直す (自分では治らない状態を毎日赤にしない)
    unreadable-issue  gh が失敗した / 一覧の形が違う → 範囲は回さない
    unreadable-state  区画はあるが状態を読めない (broken) → 範囲は回さない

`ok` と `first` と `missing-commit` は終了コード 0、ほかは 1 (job を赤にする)。範囲は**標本**で、起点は
回した回の HEAD へ毎回進む (回しきれなかった数は報告が名乗る)。起点を動かさないのは、状態が読めない
`unreadable-*` と、理由が分からない回だけ。

## 追跡用 Issue の探し方 (`find_issue`)

題の完全一致に加え、**作者が job の発信者 (`app/github-actions`) の Issue だけ**を採る (同じ題の Issue を
誰かが立てても、書き込み先にしない)。検索の索引は起票の直後に追いつかないことがあるので、検索で
空なら索引に依らない一覧で確かめてから「無い」と言う (無いと読んで二重に立てない)。

検査は scripts/tests/report_mutation_test.py (make hooks-test)。
"""

import argparse
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

OUTCOMES = ("killed", "survived", "timeout", "invalid", "unevaluated", "unrun")
META = re.compile(r"^<!-- mutation-state meta=(.*) -->$", re.M)
SHA = re.compile(r"^[0-9a-f]{40}$")
# 追跡用 Issue を立てる job の発信者。GITHUB_TOKEN が作った Issue の作者は `app/github-actions`
BOT_AUTHORS = ("app/github-actions", "github-actions")


def normalize(text):
    """CRLF を LF へ。web で直した本文はメタの行末が \\r になり、`$` で当たらなくなる。"""
    return (text or "").replace("\r\n", "\n")


def encode_meta(meta):
    """状態を 1 行の HTML コメントにする。`--` は HTML コメントを閉じかねないので JSON の escape に置く。"""
    text = json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "<!-- mutation-state meta=" + text.replace("--", "-\\u002d") + " -->"


def is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def validate_meta(meta):
    """メタの型を 1 か所で見る。違えば理由の文字列、約束どおりなら None。"""
    if not isinstance(meta, dict):
        return "メタが JSON の object ではない"
    head = meta.get("range_head")
    if head is not None and not (isinstance(head, str) and SHA.match(head)):
        return f"range_head が commit に読めない ({head!r})"
    survivors = meta.get("survivors")
    if not isinstance(survivors, list) or any(not isinstance(s, str) for s in survivors):
        return "survivors が文字列の配列ではない"
    if not is_count(meta.get("unreadable")):
        return "unreadable が 0 以上の整数ではない"
    history = meta.get("history")
    if not isinstance(history, list):
        return "history が配列ではない"
    for entry in history:
        if not isinstance(entry, dict) or not all(isinstance(entry.get(k), str) for k in ("when", "head")):
            return "history の行に when / head が無い"
        if any(not is_count(entry.get(k)) for k in OUTCOMES):
            return "history の行の件数が 0 以上の整数ではない"
        score = entry.get("score")
        if score is not None and (isinstance(score, bool) or not isinstance(score, (int, float))):
            return "history の行の点数が数ではない"
    return None


def sections(body):
    """区画 (begin から end の行まで) の (始まり, 終わり) の文字位置の並び。begin だけ・end だけは数えない。"""
    found, position = [], 0
    while True:
        start = body.find(BEGIN, position)
        if start < 0:
            return found
        end = body.find(END, start)
        if end < 0:
            return found
        found.append((start, end + len(END)))
        position = end + len(END)


def parse_state(body):
    """(種類, 値)。("none", None) / ("ok", メタ) / ("broken", 理由)。"""
    body = normalize(body)
    found = sections(body)
    if not found:
        return "none", None
    if len(found) > 1:
        return "broken", f"区画が {len(found)} つある"
    inner = body[found[0][0]: found[0][1]]
    metas = META.findall(inner)
    if len(metas) != 1:
        return "broken", f"区画の中のメタの行が {len(metas)} 行ある (1 行でなければ読まない)"
    try:
        meta = json.loads(metas[0])
    except ValueError as error:
        return "broken", f"メタが JSON に読めない ({error})"
    problem = validate_meta(meta)
    if problem:
        return "broken", problem
    return "ok", meta


def remove_sections(body):
    """区画を全部取り除く (壊れた区画を作り直す前に。人の文は残す)。"""
    body = normalize(body)
    for start, end in reversed(sections(body)):
        body = body[:start].rstrip("\n") + "\n" + body[end:].lstrip("\n")
    return body


def replace_section(body, section):
    """本文の区画を差し替える。無ければ末尾に足す (片方だけある壊れた区画で人の文を巻き込まない)。"""
    body = normalize(body)
    found = sections(body)
    if not found:
        return body.rstrip("\n") + "\n\n" + section + "\n"
    start, end = found[0]
    return body[:start] + section + body[end:]


def block_markers(name):
    return f"<!-- mutation-state:{name} -->", f"<!-- mutation-state:{name}-end -->"


def wrap_block(name, text):
    begin, end = block_markers(name)
    return f"{begin}\n{text.strip(chr(10))}\n{end}"


def read_block(body, name):
    """区画の中の名前つきの塊 (最後に読めた回のもの)。無ければ空。"""
    body = normalize(body)
    found = sections(body)
    if not found:
        return ""
    inner = body[found[0][0]: found[0][1]]
    begin, end = block_markers(name)
    start, stop = inner.find(begin), inner.find(end)
    if start < 0 or stop < start:
        return ""
    return inner[start + len(begin): stop].strip("\n")


def gh_json(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout or "null")


def matching(rows):
    """題が完全一致し、作者が job の発信者の Issue の番号の並び (小さい順)。"""
    if not isinstance(rows, list):
        raise ValueError(f"issue list の応答が配列ではない ({rows!r})")
    return sorted(row["number"] for row in rows
                  if isinstance(row, dict) and row.get("title") == TITLE
                  and (row.get("author") or {}).get("login") in BOT_AUTHORS)


def find_issue():
    """open な追跡用 Issue の番号。無ければ None。

    **gh の失敗や形の違う応答は「無い」とせず例外にする** (無いと読むと、既にある Issue の隣に二重に立つ)。
    検索は前方一致を含み、索引が遅れるので、完全一致・作者で絞り、検索で空なら索引に依らない一覧でも
    確かめる。複数あれば番号の小さい方 (先に立った方)。
    """
    found = matching(gh_json("issue", "list", "--state", "open", "--limit", "100", "--search",
                             f'"{TITLE}" in:title', "--json", "number,title,author"))
    if not found:
        found = matching(gh_json("issue", "list", "--state", "open", "--limit", "100",
                                 "--json", "number,title,author"))
    return found[0] if found else None


def issue_body(number):
    return normalize((gh_json("issue", "view", str(number), "--json", "body") or {}).get("body"))


def is_ancestor(head, repo_dir="."):
    """head が木にあり、HEAD の祖先か。別の枝の run や履歴の書き換えで外れる。"""
    have = subprocess.run(["git", "-C", repo_dir, "cat-file", "-e", f"{head}^{{commit}}"], capture_output=True)
    if have.returncode != 0:
        return False
    ancestor = subprocess.run(["git", "-C", repo_dir, "merge-base", "--is-ancestor", head, "HEAD"],
                              capture_output=True)
    return ancestor.returncode == 0


def previous(repo_dir="."):
    """(reason, 起点か None, 詳細)。reason は冒頭の表。"""
    try:
        number = find_issue()
        body = issue_body(number) if number is not None else ""
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        return "unreadable-issue", None, f"追跡用の Issue を読めなかった ({error})"
    kind, value = parse_state(body)
    if kind == "broken":
        return "unreadable-state", None, f"区画の状態を読めない: {value}"
    if kind == "none" or value.get("range_head") is None:
        return "first", None, "追跡用の Issue / 区画 / 起点が無い (最初の回)"
    head = value["range_head"]
    if not is_ancestor(head, repo_dir):
        return "missing-commit", None, f"起点 {head[:12]} がこの木に無いか、HEAD の祖先でない"
    return "ok", head, f"範囲の起点は前回の点数の commit {head[:12]}"


NOTES = {
    "ok": "{detail}",
    "first": "{detail}。範囲は回さず、束を回して起点を置く",
    "missing-commit": "{detail} (履歴の書き換えか、main 以外の枝の run)。範囲は回さない。報告が名乗って起点を置き直す",
    "unreadable-issue": "{detail}。範囲は回さず、起点も動かさない",
    "unreadable-state": "{detail}。範囲は回さない。次の報告が区画を作り直してコメントで名乗る",
}


def main(argv):
    parser = argparse.ArgumentParser(description="前回の点数の commit を追跡用の Issue から読む (#3221)")
    commands = parser.add_subparsers(dest="command", required=True)
    sub = commands.add_parser("previous")
    sub.add_argument("--repo-dir", default=".")
    sub.add_argument("--github-output", default=None, help="since= と reason= を足す先 ($GITHUB_OUTPUT)")
    sub.add_argument("--summary", default=None, help="job の要約に足す先 ($GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv[1:])
    reason, head, detail = previous(args.repo_dir)
    note = NOTES[reason].format(detail=detail)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"since={head or ''}\nreason={reason}\n")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as out:
            out.write(f"### 変異の検査の範囲\n\n`{reason}`: {note}\n\n")
    print(head or "")
    print(f"mutation_state: {reason}: {note}", file=sys.stderr)
    return 0 if reason in ("ok", "first", "missing-commit") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
