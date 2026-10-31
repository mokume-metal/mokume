#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の job (host-scheduled.yml の mutation) の結果を、追跡用の Issue に置く (#3221)。

    report-mutation.py --result <success|failure|cancelled> --bundle <束の結果.json> \\
                       [--range <範囲の結果.json> --range-since <前回の commit>]

呼ぶのは host-scheduled.yml の mutation-report (GitHub ホストの ubuntu) で、**`issues: write` を持つのは
そのジョブだけ**である。変異を回す mutation には読む権限だけを渡す (読み手は scripts/mutation_state.py)。

## 置き場 (#3221 の条件 6)

固定タイトル (`mutation_state.TITLE`) の open な Issue を 1 本。無ければ立てる (`verify: triaged` は
付けない — 着手できる仕事ではなく、点数を読む場所である。ready-queue も stock も拾わない)。

- **本文の機械の区画を書き換える。** 最新の点数・帰属・生き残り・無効・履歴。本文の編集は通知されない
  ので、毎日の更新が通知を積まない。区画の外 (人が書いた説明) は触らない
- **コメントするのは 2 つだけ。** (1) 新しい生き残り — 前の回の束の生き残りに無い id と、範囲の生き残り全部
  (範囲は回ごとに別の行を見るので新しい)。(2) 記録が読めない回に**変わったとき** (連続の 2 回目以降は
  区画の連続回数だけ書き換える)。新しく立てた回は本文に全部あるのでコメントしない
- **点数の低下では何もしない。** 赤にするのは job の側 (`mutate.py summary` が `unreadable` を返す回)

## 読めない回 (#3221 の条件 6)

記録が無い・読めない・形が違う回は、「生き残り 0」とは出さず `unreadable` と名乗る。**点数の表は前回の
まま更新しない**(読めなかった側だけ。束と範囲は別々に持つ)。範囲の起点 (`range_head`) も進めない —
進めると、回しそこなった範囲が永久に飛ぶ。範囲を回すつもりが無かった回 (`--range-since` が空 =
前回の commit が無い最初の回) は、束が読めれば起点を HEAD に置く。

検査は scripts/tests/report_mutation_test.py (make hooks-test)。偽 gh で Issue の読み書きまで通す。
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import mutate  # noqa: E402
import mutation_state as state  # noqa: E402

HISTORY_LIMIT = 14
SURVIVOR_ROWS = 30

INTRO = """定期の job (`.github/workflows/host-scheduled.yml` の `mutation`) が、**検査の検証力**を測った結果を置く追跡用の Issue (#3221・親 #3207)。下の機械の区画は job が毎回書き換える (本文の編集は通知されない)。区画の外は人が書いてよい。

## 読み方

- **点数** = 殺した ÷ (殺した + 生き残り)。実装を 1 か所壊したとき、関連の検査が赤になれば「殺した」、全部緑のままなら「生き残り」。無効 (build が通らない・記録が読めない・束の原文が当たらない)・時間切れ・未評価 (GPU が無い機械で飛んだ検査)・回しきれなかった分は分母に入れず、件数を名乗る
- **固定の束** (`Tests/mutation-bundle.json`) は同じ変異を毎回回す。点数の動きが検査の側の変化を表す (#3207 の K5)。GPU の suite を要る変異はホストでは `未評価` にしかならず、いまは取らない (2026-10-30 の決定)
- **範囲** は前回の点数の commit から HEAD までに変わった `Sources/` の行を候補にする。全体の期限で打ち切るので、回しきれなかった数が残る
- **帰属** は、殺した検査の suite を `Tests/probe-catalog.tsv` で提案へ引いた数 (#3207 の K2)。「単独」はその提案の検査だけが殺した数

## 動き

- コメントが付くのは**新しい生き残り**と、**記録が読めなくなった回**だけ。後者は点数を前回のまま更新せず、範囲の起点も進めない
- 点数が下がっても job は赤にならない。赤になるのは記録が読めない回 (`unreadable`)
- **この Issue は閉じない。** 閉じると次の回が新しく立て、前回の commit を失う

"""


def now_text():
    override = os.environ.get("MUTATION_REPORT_NOW")
    if override:
        return override
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")


def load(path):
    """(結果, 読めなかった理由)。どちらか片方だけが None でない。"""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "記録が無い"
    except (OSError, ValueError) as error:
        return None, f"読めない ({error})"
    problem = mutate.check_result(data)
    return (None, problem) if problem else (data, None)


def run_url():
    run = os.environ.get("GITHUB_RUN_ID")
    if not run:
        return ""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    return f"{server}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{run}"


def demote(markdown):
    """summary_text の見出しを、区画の中の見出しの深さに下げる。"""
    return re.sub(r"(?m)^(#{3,4}) ", lambda m: "#" * (len(m.group(1)) + 1) + " ", markdown)


def block_text(title, data, when):
    return f"#### {title} ({when})\n\n" + demote(mutate.summary_text(data)).split("\n", 2)[2]


def score_percent(score):
    return "なし" if score is None else "%.1f%%" % (score * 100)


def history_entry(data, when):
    counts = data["counts"]
    return {"when": when, "head": str(data.get("head"))[:12], "score": data.get("score"),
            **{k: counts[k] for k in mutate.OUTCOMES}}


def history_table(history):
    lines = ["#### 履歴 (束の点数・新しい順)", "",
             "| 日 | commit | 点数 | 殺した | 生き残り | 無効 | 時間切れ | 未評価 | 回しきれず |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for e in reversed(history):
        lines.append(f"| {e['when']} | `{e['head']}` | {score_percent(e.get('score'))} | {e['killed']} | "
                     f"{e['survived']} | {e['invalid']} | {e['timeout']} | {e['unevaluated']} | {e['unrun']} |")
    return "\n".join(lines)


def survivors_of(data, source):
    return [{"source": source, "id": m["id"], "where": f"{m['file']}:{m.get('line')}",
             "change": str(m.get("operator") or m.get("note") or "")}
            for m in data["mutants"] if m.get("outcome") == "survived"]


def build(previous_body, args):
    """(区画の文字列, 新しい生き残りの行, 読めなかった回の理由の並び, 新しい状態)。"""
    meta = state.read_meta(previous_body) or {}
    when, url = now_text(), run_url()
    bundle, bundle_problem = load(args.bundle)
    expected = bool(args.range_since)
    ranged, range_problem = load(args.range) if expected and args.range else (None, None)
    if expected and not args.range:
        range_problem = "範囲の結果の置き場が渡されていない"
    if expected and ranged is None and range_problem is None:
        range_problem = "記録が無い"

    problems = []
    if bundle is None:
        problems.append(f"固定の束: {bundle_problem}")
    if expected and ranged is None:
        problems.append(f"範囲 (since {args.range_since[:12]}): {range_problem}")

    blocks = {name: state.read_block(previous_body, name) for name in state.BLOCKS}
    if bundle is not None:
        blocks["bundle"] = block_text("固定の束", bundle, when)
    elif not blocks["bundle"]:
        blocks["bundle"] = "#### 固定の束\n\nまだ読めた回が無い。"
    if ranged is not None:
        blocks["range"] = block_text(f"範囲 (since {args.range_since[:12]})", ranged, when)
    elif not blocks["range"]:
        blocks["range"] = ("#### 範囲\n\nまだ回していない (前回の点数の commit が無い最初の回は、束だけを回して"
                           "起点を置く)。")

    # 起点は、範囲を回すつもりだった回に読めたときと、回すつもりが無かった回に束が読めたときだけ進める
    range_head = meta.get("range_head")
    if expected and ranged is not None:
        range_head = ranged.get("head")
    elif not expected and bundle is not None:
        range_head = bundle.get("head")

    history = list(meta.get("history") or [])
    if bundle is not None:
        history.append(history_entry(bundle, when))
    history = history[-HISTORY_LIMIT:]

    previous_survivors = set(meta.get("survivors") or [])
    survivors = sorted(m["id"] for m in (bundle["mutants"] if bundle else []) if m.get("outcome") == "survived")
    if bundle is None:
        survivors = sorted(previous_survivors)
    fresh = []
    if bundle is not None:
        fresh += [s for s in survivors_of(bundle, "束") if s["id"] not in previous_survivors]
    if ranged is not None:
        fresh += survivors_of(ranged, f"範囲 since {args.range_since[:12]}")

    streak = int(meta.get("unreadable") or 0) + 1 if problems else 0
    new_meta = {"range_head": range_head, "survivors": survivors, "unreadable": streak, "history": history}

    if problems:
        status = (f"**unreadable** (連続 {streak} 回・{when} UTC・job の結果 `{args.result}`)"
                  f" ・ 点数は前回のまま更新していない: " + " / ".join(problems))
    else:
        status = f"最終の回: {when} UTC ・ job の結果 `{args.result}` ・ 記録は読めた"
    if url:
        status += f" ・ [run]({url})"

    parts = [state.BEGIN, status, "", state.wrap_block("bundle", blocks["bundle"]), "",
             state.wrap_block("range", blocks["range"]), "", history_table(history) if history else "",
             state.encode_meta(new_meta), state.END]
    return "\n".join(parts), fresh, problems, new_meta


def survivors_comment(fresh):
    lines = [f"新しい生き残りが {len(fresh)} 件ある: 実装を壊しても、関連の検査が赤にならなかった。", "",
             "| 出所 | id | 位置 | 変異 |", "| --- | --- | --- | --- |"]
    for s in fresh[:SURVIVOR_ROWS]:
        lines.append(f"| {s['source']} | {s['id']} | `{s['where']}` | {s['change']} |")
    if len(fresh) > SURVIVOR_ROWS:
        lines.append(f"| ほか {len(fresh) - SURVIVOR_ROWS} 件 | | | |")
    url = run_url()
    lines += ["", "束の生き残りは検査の穴の候補、範囲の生き残りは今日の変更に対する検査の穴の候補である。"
              "意図した生き残り (等価な変異) なら、束の側は `Tests/mutation-bundle.json` から外す。"]
    if url:
        lines += ["", f"run: {url}"]
    return "\n".join(lines)


def unreadable_comment(problems, streak):
    url = run_url()
    lines = [f"**unreadable**: 変異の検査の記録が読めない回があった (連続 {streak} 回目)。点数は前回のまま更新しておらず、"
             "範囲の起点も進めていない。", ""]
    lines += [f"- {p}" for p in problems]
    lines += ["", "「生き残り 0」ではない。run の artifact `mutation-record` と、job の要約を読む。"
              "連続の 2 回目以降はコメントせず、本文の区画の連続回数だけを書き換える。"]
    if url:
        lines += ["", f"run: {url}"]
    return "\n".join(lines)


def write_temp(text, name):
    path = Path(os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp") / name
    path.write_text(text, encoding="utf-8")
    return str(path)


def main(argv):
    parser = argparse.ArgumentParser(description="変異の定期の結果を追跡用の Issue に置く (#3221)")
    parser.add_argument("--result", required=True, help="mutation job の結論 (needs.mutation.result)")
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--range", default=None)
    parser.add_argument("--range-since", default="", help="範囲を回すつもりだった回の起点 (空なら回さない回)")
    args = parser.parse_args(argv[1:])

    number = state.find_issue()
    previous_body = state.issue_body(number) if number is not None else ""
    section, fresh, problems, meta = build(previous_body, args)

    if number is None:
        text = INTRO + section + "\n"
        url = subprocess.run(["gh", "issue", "create", "--title", state.TITLE,
                              "--body-file", write_temp(text, "mutation-issue.md")],
                             capture_output=True, text=True, check=True).stdout.strip()
        created = url.rsplit("/", 1)[-1]
        if not created.isdigit():
            print(f"report: 起票の応答から Issue 番号を取れなかった: {url}", file=sys.stderr)
            return 1
        print(f"report: 起票した {url}")
        # GITHUB_TOKEN が作った Issue には triage.yml が発火しない。型は自分で付ける
        subprocess.run(["bash", str(HERE / "triage.sh"), created, state.TITLE], check=True)
        return 0

    updated = state.replace_section(previous_body, section)
    subprocess.run(["gh", "issue", "edit", str(number), "--body-file", write_temp(updated, "mutation-issue.md")],
                   capture_output=True, text=True, check=True)
    print(f"report: #{number} の区画を書き換えた (通知しない)")

    previous_streak = int((state.read_meta(previous_body) or {}).get("unreadable") or 0)
    comments = []
    if fresh:
        comments.append(survivors_comment(fresh))
    if problems and previous_streak == 0:
        comments.append(unreadable_comment(problems, meta["unreadable"]))
    for text in comments:
        subprocess.run(["gh", "issue", "comment", str(number), "--body-file", write_temp(text, "mutation-comment.md")],
                       capture_output=True, text=True, check=True)
        print(f"report: #{number} にコメントした")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
