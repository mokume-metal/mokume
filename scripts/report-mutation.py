#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""変異の定期の job (host-scheduled.yml の mutation) の結果を、追跡用の Issue に置く (#3221)。

    report-mutation.py --result <success|failure|cancelled> --bundle <束の結果.json> \\
                       [--range <範囲の結果.json> --range-since <前回の commit> --range-reason <理由>] \\
                       [--dry-run]

呼ぶのは host-scheduled.yml の mutation-report (GitHub ホストの ubuntu) で、**`issues: write` を持つのは
そのジョブだけ**である。変異を回す mutation には読む権限だけを渡す (読み手は scripts/mutation_state.py)。
**Issue を書くのは main の run だけ**で、他の ref の `workflow_dispatch` は `--dry-run` (job の要約に出すだけ) で
呼ぶ — 共有の追跡 Issue を枝の run が書き換えない。

## 置き場 (#3221 の条件 6)

固定タイトル (`mutation_state.TITLE`) の open な Issue を 1 本。無ければ立てる (`verify: triaged` は
付けない — 着手できる仕事ではなく、点数を読む場所である。ready-queue も stock も拾わない)。

- **本文の機械の区画を書き換える。** 最新の点数・帰属・生き残り・無効・履歴。本文の編集は通知されない
  ので、毎日の更新が通知を積まない。区画の外 (人が書いた説明) は触らない
- **コメントするのは 3 つだけ。** (1) 新しい生き残り — 前の回の束の生き残りに無い id と、範囲の生き残り全部。
  (2) 記録が読めない回に**変わったとき** (連続の 2 回目以降は区画の連続回数だけ書き換える)。
  (3) 区画の状態を読めず作り直したとき。立てた回は本文に全部あるので (1) は出さないが、(2) は出す
- **コメントを先に投稿し、成功してから本文を書き換える。** 逆だと、コメントが落ちた回に「既知」だけが
  本文に残って、その生き残りが永久に通知されない。コメントが成功して本文が失敗した回は、次の回に
  同じコメントが重なる (落とすより重ねる)
- **点数の低下では何もしない。** 赤にするのは job の側

## 読めない回 (#3221 の条件 6)

記録が無い・読めない・形が違う・中断した (`aborted`)・job の結論が success でない回は、「生き残り 0」と
は出さず `unreadable` と名乗る。**点数の表は前回のまま更新しない**(読めなかった側だけ。束と範囲は別々に
持つ)。

## 範囲の起点 (`range_head`) と評価済みのキー (`done`)

起点は 1 日で全部は回せない範囲を、**回しきるまで動かさない**。回した分のキーは `done` に残り、次の回の
`mutate.py run --exclude-file` が飛ばす — 毎回同じ先頭だけが回って末尾が永久に回らない形にしない。

    reason=first               束が読めれば起点を HEAD に置く (最初の回)
    reason=ok                  範囲が読めて unrun が 0 なら HEAD へ進めて done を空にする。unrun が残れば
                               起点を保ち、評価済みのキーを足す
    それ以外 (missing-commit・   起点を動かさない (理由は区画に名乗る)
      unreadable-issue・unreadable-state)

## 区画の状態を読めないとき

区画が 2 つある・メタが無い / 壊れている / 型が違う回は、最初の回に戻さず、区画を全部取り除いて作り直し、
コメントで名乗る (履歴・起点・既知の生き残りを失うことも書く)。人の文は残る。

## 本文の大きさ

GitHub の本文の上限は 65536 字。区画が上限に近づいたら表を件数だけにして収める。人の文だけで
収まらないときは、書かずに 1 で終わる (人の文を削らない)。

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
BODY_LIMIT = 60000  # GitHub の本文の上限 65536 字の手前

INTRO = """定期の job (`.github/workflows/host-scheduled.yml` の `mutation`) が、**検査の検証力**を測った結果を置く追跡用の Issue (#3221・親 #3207)。下の機械の区画は job が毎回書き換える (本文の編集は通知されない)。区画の外は人が書いてよい。

## 読み方

- **点数** = 殺した ÷ (殺した + 生き残り)。実装を 1 か所壊したとき、関連の検査が赤になれば「殺した」、全部緑のままなら「生き残り」。無効 (build が通らない・記録が読めない・束の原文が当たらない)・時間切れ・未評価 (GPU が無い機械で飛んだ検査)・回しきれなかった分は分母に入れず、件数を名乗る
- **固定の束** (`Tests/mutation-bundle.json`) は同じ変異を毎回回す。点数の動きが検査の側の変化を表す (#3207 の K5)。GPU の suite を要る変異はホストでは `未評価` にしかならず、いまは取らない (2026-10-30 の決定)
- **範囲** は前回の点数の commit から HEAD までに変わった `Sources/` の行を候補にする。全体の期限で打ち切り、**回しきるまで起点を動かさない** (回した候補は次の回で飛ばす)。積み残しの数は範囲の表に出る
- **帰属** は、殺した検査の suite を `Tests/probe-catalog.tsv` で提案へ引いた数 (#3207 の K2)。「単独」はその提案の検査だけが殺した数

## 動き

- コメントが付くのは**新しい生き残り**と、**記録が読めなくなった回**と、**区画を作り直した回**だけ。読めない回は点数を前回のまま更新せず、範囲の起点も進めない
- 点数が下がっても job は赤にならない。赤になるのは記録が読めない回 (`unreadable`)
- **区画を読めなくなったら、区画ごと消せば次の回が作り直す。** この Issue は閉じない (閉じると次の回が新しく立て、前回の commit を失う)

"""


def now_text():
    override = os.environ.get("MUTATION_REPORT_NOW")
    if override:
        return override
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")


def load(path):
    """(結果, 読めなかった理由)。どちらか片方だけが None でない。中断した記録は点数に使わない。"""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "記録が無い"
    except (OSError, ValueError) as error:
        return None, f"読めない ({error})"
    problem = mutate.check_result(data)
    if problem:
        return None, problem
    if data.get("aborted"):
        return None, f"中断した ({data['aborted']})"
    return data, None


def run_url():
    run = os.environ.get("GITHUB_RUN_ID")
    if not run:
        return ""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    return f"{server}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{run}"


def demote(markdown):
    """summary_text の見出しを、区画の中の見出しの深さに下げる。"""
    return re.sub(r"(?m)^(#{3,4}) ", lambda m: "#" * (len(m.group(1)) + 1) + " ", markdown)


def block_text(title, data, when, compact):
    rows = 0 if compact else mutate.SUMMARY_ROWS
    return f"#### {title} ({when})\n\n" + demote(mutate.summary_text(data, rows)).split("\n", 2)[2]


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


RANGE_PROBLEMS = {
    "missing-commit": "前回の点数の commit が木に無いか HEAD の祖先でない (履歴の書き換えか、main 以外の枝の run)",
    "unreadable-issue": "追跡用の Issue から前回の commit を読めなかった",
    "unreadable-state": "区画の状態を読めなかった",
    "unknown": "起点を読む段が理由を出さずに終わった",
}


def build(previous_body, args, compact=False):
    """(区画の文字列, 新しい生き残りの行, 読めなかった回の理由の並び, 新しい状態, 作り直した理由か None)。"""
    kind, value = state.parse_state(previous_body)
    reset = value if kind == "broken" else None
    meta = value if kind == "ok" else {}
    when, url = now_text(), run_url()
    reason = args.range_reason or ("ok" if args.range_since else "first")
    expected = reason == "ok" and bool(args.range_since)

    bundle, bundle_problem = load(args.bundle)
    ranged, range_problem = (None, None)
    if expected:
        ranged, range_problem = load(args.range) if args.range else (None, "範囲の結果の置き場が渡されていない")

    problems = []
    if bundle is None:
        problems.append(f"固定の束: {bundle_problem}")
    if expected and ranged is None:
        problems.append(f"範囲 (since {args.range_since[:12]}): {range_problem}")
    if reason not in ("ok", "first"):
        problems.append(f"範囲: {RANGE_PROBLEMS.get(reason, '起点の状態が分からない')} (`{reason}`)。起点は動かさない")
    if args.result != "success":
        problems.append(f"job の結論が `{args.result}`")

    blocks = {name: state.read_block(previous_body, name) if kind == "ok" else "" for name in state.BLOCKS}
    if bundle is not None:
        blocks["bundle"] = block_text("固定の束", bundle, when, compact)
    elif not blocks["bundle"]:
        blocks["bundle"] = "#### 固定の束\n\nまだ読めた回が無い。"

    range_head = meta.get("range_head")
    done = list(meta.get("done") or [])
    if reason == "first":
        if bundle is not None:
            range_head, done = bundle.get("head"), []
        if not blocks["range"]:
            blocks["range"] = ("#### 範囲\n\nまだ回していない (前回の点数の commit が無い最初の回は、束だけを回して"
                               "起点を置く)。")
    if ranged is not None:
        text = block_text(f"範囲 (since {args.range_since[:12]})", ranged, when, compact)
        unrun = ranged["counts"]["unrun"]
        if unrun == 0:
            range_head, done = ranged.get("head"), []
            text += f"\n範囲を回しきった。起点を `{str(range_head)[:12]}` へ進めた。\n"
        else:
            evaluated = [m["key"] for m in ranged["mutants"] if m.get("outcome") != "unrun" and m.get("key")]
            done = (done + [k for k in evaluated if k not in done])[-state.DONE_LIMIT:]
            text += (f"\n**積み残し {unrun} 件。** 起点は前回のまま (`{args.range_since[:12]}`) にし、評価済みの"
                     f" {len(done)} 件は次の回で飛ばす。回しきるまで起点を進めない。\n")
        blocks["range"] = text
    elif not blocks["range"]:
        blocks["range"] = "#### 範囲\n\nまだ読めた回が無い。"

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
    new_meta = {"range_head": range_head, "survivors": survivors, "unreadable": streak, "history": history,
                "done": done}

    if problems:
        label = "unreadable" if any(not p.startswith("job の結論") for p in problems) else "job が success で終わらなかった"
        status = (f"**{label}** (連続 {streak} 回・{when} UTC・job の結論 `{args.result}`)"
                  f" ・ 読めなかった側の点数は前回のまま更新していない: " + " / ".join(problems))
    else:
        status = f"最終の回: {when} UTC ・ job の結論 `{args.result}` ・ 記録は読めた"
    if url:
        status += f" ・ [run]({url})"

    parts = [state.BEGIN, status, "", state.wrap_block("bundle", blocks["bundle"]), "",
             state.wrap_block("range", blocks["range"]), "", history_table(history) if history else "",
             state.encode_meta(new_meta), state.END]
    return "\n".join(parts), fresh, problems, new_meta, reset


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
    lines = [f"**unreadable**: 変異の検査の回に異常があった (連続 {streak} 回目)。読めなかった側の点数は前回のまま更新して"
             "おらず、範囲の起点も進めていない。", ""]
    lines += [f"- {p}" for p in problems]
    lines += ["", "「生き残り 0」ではない。run の artifact `mutation-record` と、job の要約を読む。"
              "連続の 2 回目以降はコメントせず、本文の区画の連続回数だけを書き換える。"]
    if url:
        lines += ["", f"run: {url}"]
    return "\n".join(lines)


def reset_comment(reason):
    return (f"**区画の状態を読めなかった**: {reason}。区画を全部取り除いて作り直した (人が書いた文は残した)。"
            "履歴・範囲の起点・評価済みの候補・既知の生き残りを失ったので、次の回は最初の回として起点を置き直し、"
            "束の生き残りは全部新しい扱いで通知される。")


def write_temp(text, name):
    path = Path(os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp") / name
    path.write_text(text, encoding="utf-8")
    return str(path)


# gh の書き込みは、workflow_permissions_test が走査できるよう、動詞を字面で書く (`["gh", "issue", …]`)
def gh_create(title, body_file):
    return subprocess.run(["gh", "issue", "create", "--title", title, "--body-file", body_file],
                          capture_output=True, text=True, check=True).stdout


def gh_comment(number, body_file):
    subprocess.run(["gh", "issue", "comment", str(number), "--body-file", body_file],
                   capture_output=True, text=True, check=True)


def gh_edit(number, body_file):
    subprocess.run(["gh", "issue", "edit", str(number), "--body-file", body_file],
                   capture_output=True, text=True, check=True)


def fit(previous_body, args, make_body):
    """本文を上限に収める。(本文か None, 区画の組み立ての結果)。収まらなければ None。"""
    for compact in (False, True):
        built = build(previous_body, args, compact)
        body = make_body(built[0])
        if len(body) <= BODY_LIMIT:
            return body, built
    return None, built


def main(argv):
    parser = argparse.ArgumentParser(description="変異の定期の結果を追跡用の Issue に置く (#3221)")
    parser.add_argument("--result", required=True, help="mutation job の結論 (needs.mutation.result)")
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--range", default=None)
    parser.add_argument("--range-since", default="", help="範囲を回すつもりだった回の起点 (空なら回さない回)")
    parser.add_argument("--range-reason", default="", help="mutation_state.py previous の reason (空なら since から読む)")
    parser.add_argument("--dry-run", action="store_true", help="Issue に書かず、区画を job の要約に出す (main 以外の run)")
    args = parser.parse_args(argv[1:])

    try:
        number = state.find_issue()
        previous_body = state.issue_body(number) if number is not None else ""
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"report: 追跡用の Issue を読めなかった。書かずに終わる ({error})", file=sys.stderr)
        return 1

    reset_needed = state.parse_state(previous_body)[0] == "broken"
    if number is None:
        make_body = lambda section: INTRO + section + "\n"  # noqa: E731
    else:
        make_body = lambda section: state.replace_section(  # noqa: E731
            state.remove_sections(previous_body) if reset_needed else previous_body, section)
    body, built = fit(previous_body, args, make_body)
    section, fresh, problems, meta, reset = built
    if body is None:
        print(f"report: 本文が {BODY_LIMIT} 字に収まらない (区画を件数だけにしても、人の文が長い)。書かずに終わる",
              file=sys.stderr)
        return 1

    if args.dry_run:
        text = f"### 変異の検査の報告 (dry-run・main 以外の run は Issue に書かない)\n\n{section}\n"
        print(text)
        target = os.environ.get("GITHUB_STEP_SUMMARY")
        if target:
            with open(target, "a", encoding="utf-8") as out:
                out.write(text)
        return 0

    kind, previous_meta = state.parse_state(previous_body)
    previous_streak = int(previous_meta.get("unreadable") or 0) if kind == "ok" else 0
    comments = []
    if reset:
        comments.append(reset_comment(reset))
    if fresh and number is not None:
        comments.append(survivors_comment(fresh))
    if problems and previous_streak == 0:
        comments.append(unreadable_comment(problems, meta["unreadable"]))

    def post(target):
        for text in comments:
            gh_comment(target, write_temp(text, "mutation-comment.md"))
            print(f"report: #{target} にコメントした")

    if number is None:
        url = gh_create(state.TITLE, write_temp(body, "mutation-issue.md")).strip()
        created = url.rsplit("/", 1)[-1]
        if not created.isdigit():
            print(f"report: 起票の応答から Issue 番号を取れなかった: {url}", file=sys.stderr)
            return 1
        print(f"report: 起票した {url}")
        # GITHUB_TOKEN が作った Issue には triage.yml が発火しない。型は自分で付ける
        subprocess.run(["bash", str(HERE / "triage.sh"), created, state.TITLE], check=True)
        post(created)  # 立てた回でも、読めなかった回は名乗る
        return 0

    # コメントが先: 落ちた回に、本文だけが「既知」を覚えて通知が永久に落ちる形にしない
    post(number)
    gh_edit(number, write_temp(body, "mutation-issue.md"))
    print(f"report: #{number} の区画を書き換えた (通知しない)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
