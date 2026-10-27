#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""実装を 1 か所ずつ壊し、関連の検査が赤くなるかを測る (変異の検査・#3221)。

**測るのは検査の検証力である。** 緑の検査が「壊れた実装を捕まえられるか」は、緑を見ても
分からない。#2278 は使い捨ての worktree で 49 回、手で 1 か所ずつ壊して suite を回し、
壊しても緑のままの検査を 15 本見つけた (`MokumeCLITests` 381 件が全部緑、など)。その手順を
道具にして、#3207 の提案 1〜5 が効いたかを測る物差しにする (提案 6)。

    python3 scripts/mutate.py candidates --since <commit>          候補を JSON で出す (回さない)
    python3 scripts/mutate.py run --since <commit> --out <結果.json>  変更された行の候補を回す
    python3 scripts/mutate.py run --bundle Tests/mutation-bundle.json --out <結果.json>
    python3 scripts/mutate.py summary <結果.json>                    job の要約の Markdown

## 候補 (`--since`)

`git diff -U0 <commit> HEAD` で **足された・変わった `Sources/` の `.swift` の行だけ**を候補に
する。コメントと文字列の中は `scripts/check-tool-language.py` の `blank_comments` で塗った写しの
上で演算子を探すので、候補にならない (字句の読みは写さず取り込む)。演算子は `OPERATORS`:
比較の境界 (`>=`↔`>`・`<=`↔`<`)・`==`↔`!=`・`&&`↔`||`・`+`↔`-`・`true`↔`false`・条件を外す
(`guard` / `if` / `while` の `,` で区切った比較の節を `true` にする — #2278 の「`>= 0` を外す」)。
2 項の演算子は両側に空白があるものだけを取る (Swift は 2 項の演算子に左右同じ空白を要るので、
総称の `<T>`・`->`・単項の `-1` を拾わない)。候補はファイルを順に 1 件ずつ取る並び (round
robin) にする — 全体の期限で打ち切ったとき、先頭のファイルだけが回る形にしないため。

## 固定の束 (`--bundle`)

`Tests/mutation-bundle.json`。位置は行番号でなく「ファイルと、そこにちょうど 1 回現れる原文
(`find`)」で持つ。行は毎日動くが、原文は直しを入れるまで動かない。当たらない・2 回以上当たる
変異は `invalid` (`anchor`) と名乗る — 黙って飛ばすと、束の点数の分母が知らないうちに変わる。
各 sub-issue の merge の前後の commit で同じ束を回し、点数を比べる (#3207 の K5)。

## 1 件の回し方

置換 → `swift build --build-tests` → 関連の suite を `swift test --skip-build --filter` →
**原文へ書き戻す**。書き戻しは `finally` と SIGTERM / SIGINT の両方で行う。始める前に `Sources/`
に手元の変更が無いことを見る (書き戻しで人の変更を消さないため)。build と test を合わせて
1 件ごとに期限 (`--timeout`) を持ち、越えたらプロセスグループごと殺して `timeout` と数える —
ループの終わりの条件を反転した変異が、全体の期限を食い潰さないため。

**関連の suite は 2 段で選ぶ。** (1) 変異したファイルのモジュールの test target
(`swift package dump-package` の依存から)、(2) 変異を囲む宣言 (型・関数) の名前を、その test
target の原文から語で grep して当たったファイルの suite。`--since` の候補はまず (2) に絞って
回し、殺せなければ (1) の target 全体と (2) へ広げてから `survived` と言う (狭い集合だけで
生き残りと言わない)。束は帰属を正しく数えるため、最初から広い集合で回す。選んだ target・名前・
suite・段は JSON に残す。

**変異の前に、同じ集合を変異なしで 1 度回す** (集合ごとに 1 回)。もとから赤い検査を「殺した」に
数えないためで、殺した検査はその回の失敗から差し引く。変異なしの build が通らない回は、
1 件も回さず 2 で終わる。

## 結末

    killed       変異なしでは緑の検査が赤になった。その検査の ID を全部残す
    survived     関連の suite が走りきって、どれも赤にならなかった
    timeout      1 件の期限を越えた (殺した)
    invalid      build が通らない / 記録が無い・読めない (abort や配列の範囲外でプロセスごと
                 落ちた — #2278 でも判定に使わなかった) / 束の原文が当たらない
    unevaluated  生き残ったが、関連の suite に飛ばされた検査か `Test.cancel` で取り消した検査がある
                 (GPU の無い機械では `RenderDevice.isAvailable` の suite が飛ぶ。取り消しは xunit の
                 上で passed と同じに見えるので、事象の記録から読む・#3348)。「殺せなかった」とは言わない
    unrun        全体の期限 (`--budget`) で回さなかった

点数は `killed / (killed + survived)`。ほかは分母に入れず、件数を名乗る。

## 帰属 (#3207 の K2)

殺した検査の suite を `Tests/probe-catalog.tsv` (列は suite の型名・提案の名・sub-issue の
番号。`#` で始まる行と空行は読まない) で提案へ引き、提案ごとに「殺した件数」と「その提案の検査
だけが殺した件数」(単独) を出す。表に無い suite は `-` (例の検査) に数える。殺した検査は
`swift test` が最初の赤で止まらないので 1 回の実行の xunit から全部引ける — 提案の数だけ回し
直さない。表が無い・読めない回は、帰属を空にせず `catalog.state` でそう名乗る。

## 要約 (`summary`)

記録が無い・読めない・形が違うときは `unreadable` を名乗って 1 で終わる。**「生き残り 0」とは
出さない** — 読めない回を緑に読ませると、検査の検証力が落ちても誰も気付かない。

検査は scripts/tests/mutate_test.py (make hooks-test)。`swift` は `MOKUME_MUTATE_SWIFT` で
差し替えられる (検査が偽の実行ファイルで全体を通すため)。
"""

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

VERSION = 1
OUTCOMES = ("killed", "survived", "timeout", "invalid", "unevaluated", "unrun")
DEFAULT_TIMEOUT = 900
DEFAULT_CATALOG = "Tests/probe-catalog.tsv"
NOT_IN_CATALOG = "-"


def _read_test_record():
    """read-test-record.py の読みを取り込む (ファイル名にハイフンがあるので importlib)。"""
    path = Path(__file__).resolve().parent / "read-test-record.py"
    spec = importlib.util.spec_from_file_location("read_test_record", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _blank_comments():
    """check-tool-language.py の字句の読みを取り込む (ファイル名にハイフンがあるので importlib)。"""
    path = Path(__file__).resolve().parent / "check-tool-language.py"
    spec = importlib.util.spec_from_file_location("check_tool_language", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.blank_comments


blank_comments = _blank_comments()


# ------------------------------------------------------------------ 候補

BINARY = re.compile(r"(?<=\s)(>=|<=|==|!=|&&|\|\||>|<|\+|-)(?=\s)")
SWAPS = {">=": ">", ">": ">=", "<=": "<", "<": "<=", "==": "!=", "!=": "==",
         "&&": "||", "||": "&&", "+": "-", "-": "+"}
COMPARISONS = {">=", ">", "<=", "<", "==", "!="}
LITERAL = re.compile(r"\b(true|false)\b")
CONDITION_KEYWORD = re.compile(r"(?<![\w.])(?:guard|if|while)\s+")
NOT_A_CONDITION = re.compile(r"(?<![=!<>])=(?!=)|\b(?:let|var|case)\b|[?:]")


def clause_bounds(line, start, end, previous_code):
    """比較 `start:end` を含む条件の節の (始まり, 終わり)。節でなければ None。

    左は `,`・`&&`・`||` の直後、`guard` / `if` / `while` の直後、または前の行が `,`・`&&`・`||`
    で終わるときの行頭。右は `,`・`{`・`else`・`&&`・`||`・行末。括弧の深さが 0 の所でだけ区切り、
    閉じていない括弧の中 (引数や配列の中の比較) は節と読まない。束縛 (`let`)・代入・三項は除く。
    """
    depth, i = 0, start - 1
    while i >= 0:
        char = line[i]
        if char in ")]":
            depth += 1
        elif char in "([":
            if depth == 0:
                return None
            depth -= 1
        elif depth == 0 and (char == "," or (i >= 1 and line[i - 1:i + 1] in ("&&", "||"))):
            break
        i -= 1
    if i >= 0:
        left = i + 1
    else:
        keywords = list(CONDITION_KEYWORD.finditer(line, 0, start))
        indent = len(line) - len(line.lstrip())
        if keywords:
            left = keywords[-1].end()
        elif previous_code.rstrip().endswith((",", "&&", "||")):
            left = indent
        else:
            return None
    while left < start and line[left] == " ":
        left += 1
    depth, j = 0, end
    while j < len(line):
        char = line[j]
        if char in "([":
            depth += 1
        elif char in ")]":
            if depth == 0:
                return None
            depth -= 1
        elif depth == 0 and (char in ",{" or line.startswith(("&&", "||"), j)
                             or (line.startswith("else", j) and line[j - 1] == " ")):
            break
        j += 1
    right = len(line[:j].rstrip())
    if right <= end or NOT_A_CONDITION.search(line[left:right]):
        return None
    return left, right


def line_candidates(path, number, original, blanked, previous_code):
    """1 行の候補 (演算子ごと)。位置は塗った写しで探し、置換は原文に当てる。"""
    found = []

    def add(operator, column, mutated):
        found.append({"file": path, "line": number, "column": column + 1, "operator": operator,
                      "original": original, "mutated": mutated})

    for match in BINARY.finditer(blanked):
        token, start, end = match.group(1), match.start(), match.end()
        add(f"{token} -> {SWAPS[token]}", start, original[:start] + SWAPS[token] + original[end:])
        if token in COMPARISONS:
            bounds = clause_bounds(blanked, start, end, previous_code)
            if bounds:
                left, right = bounds
                add("condition -> true", left, original[:left] + "true" + original[right:])
    for match in LITERAL.finditer(blanked):
        word = match.group(1)
        other = "false" if word == "true" else "true"
        add(f"{word} -> {other}", match.start(), original[:match.start()] + other + original[match.end():])
    return found


def file_candidates(path, text, lines):
    """ファイルの中の、指定した行の候補。"""
    blanked = blank_comments(text, strings=True).split("\n")
    original = text.split("\n")
    found = []
    for number in sorted(lines):
        if not 1 <= number <= len(original):
            continue
        previous = next((blanked[k] for k in range(number - 2, -1, -1) if blanked[k].strip()), "")
        found += line_candidates(path, number, original[number - 1], blanked[number - 1], previous)
    return found


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_lines(diff_text):
    """`git diff -U0` の出力から {パス: 足された行番号の集合}。"""
    changed, path = {}, None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            name = line[4:]
            path = name[2:] if name.startswith("b/") else None
            continue
        match = HUNK.match(line)
        if match and path:
            start, count = int(match.group(1)), int(match.group(2) or "1")
            changed.setdefault(path, set()).update(range(start, start + count))
    return {p: lines for p, lines in changed.items() if lines}


def round_robin(groups):
    """ファイルごとの列を 1 件ずつ交互に並べる。"""
    order, index = [], 0
    while any(index < len(g) for g in groups):
        order += [g[index] for g in groups if index < len(g)]
        index += 1
    return order


def range_candidates(repo, since):
    diff = git(repo, "diff", "-U0", "--no-color", "--diff-filter=AM", since, "HEAD", "--",
               "Sources/*.swift", "Sources/**/*.swift")
    groups = []
    for path, lines in sorted(changed_lines(diff).items()):
        text = (repo / path).read_text(encoding="utf-8")
        groups.append(file_candidates(path, text, lines))
    mutants = round_robin(groups)
    for index, mutant in enumerate(mutants, 1):
        mutant["id"] = f"m{index:04d}"
    return mutants


def load_bundle(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("version") != VERSION or not isinstance(data.get("mutants"), list):
        raise ValueError(f"{path}: version {VERSION} と mutants の列を持たない")
    for entry in data["mutants"]:
        for key in ("id", "file", "find", "replace"):
            if not isinstance(entry.get(key), str):
                raise ValueError(f"{path}: {entry.get('id', '?')} に {key} が無い")
    return data["mutants"]


def apply(text, mutant):
    """変異を当てた全文。当たらなければ (None, 理由)。"""
    if "find" in mutant:
        count = text.count(mutant["find"])
        if count != 1:
            return None, f"anchor: 原文が {count} 回当たる (1 回でなければ当てない)"
        return text.replace(mutant["find"], mutant["replace"]), None
    lines = text.split("\n")
    number = mutant["line"]
    if not 1 <= number <= len(lines) or lines[number - 1] != mutant["original"]:
        return None, "anchor: 行が候補を作ったときと違う"
    lines[number - 1] = mutant["mutated"]
    return "\n".join(lines), None


# ------------------------------------------------------------------ 関連の suite

TYPE_DECLARATION = re.compile(r"\b(?:struct|class|enum|actor|extension|protocol)\s+([A-Za-z_]\w*)")
FUNCTION_DECLARATION = re.compile(r"\bfunc\s+([A-Za-z_]\w*)")
TOP_LEVEL_SUITE = re.compile(r"^(?:@\w+(?:\([^)\n]*\))?\s+|(?:final|public|internal|private|fileprivate)\s+)*"
                             r"(?:struct|class|enum|actor|extension)\s+([A-Za-z_]\w*)", re.M)
GENERIC_NAMES = {"init", "body", "run", "main", "make", "draw", "setup", "update", "value", "text",
                 "parse", "load", "read", "write", "start", "stop", "description"}


def enclosing_names(text, number):
    """行 `number` を囲む関数と型の名前 (近い順・重複なし)。"""
    blanked = blank_comments(text, strings=True).split("\n")
    names, function = [], None
    for k in range(min(number, len(blanked)) - 1, -1, -1):
        line = blanked[k]
        if function is None:
            match = FUNCTION_DECLARATION.search(line)
            if match:
                function = match.group(1)
                names.append(function)
        match = TYPE_DECLARATION.search(line)
        if match and match.group(1) not in names:
            names.append(match.group(1))
            if len(line) - len(line.lstrip()) == 0:
                break
    return [n for n in names if len(n) >= 4 and n not in GENERIC_NAMES]


def module_of(path):
    parts = Path(path).parts
    return parts[1] if len(parts) > 2 and parts[0] == "Sources" else None


def test_targets(package, module):
    """モジュールの test target。`<モジュール>Tests` が在ればそれ、無ければ直に依存する test target、
    それも無ければ (MokumeDiagnostics のような下の層) 推移的に依存する test target。"""
    targets = {t["name"]: t for t in package.get("targets", [])}
    tests = sorted(name for name, t in targets.items() if t.get("type") == "test")
    if module + "Tests" in tests:
        return [module + "Tests"]

    def dependencies(name):
        for dependency in targets.get(name, {}).get("dependencies", []):
            for value in dependency.values():
                if isinstance(value, list) and value and isinstance(value[0], str):
                    yield value[0]

    def reaches(name, seen):
        for dependency in dependencies(name):
            if dependency == module or (dependency not in seen and reaches(dependency, seen | {dependency})):
                return True
        return False

    direct = [name for name in tests if module in dependencies(name)]
    return direct or [name for name in tests if reaches(name, {name})]


def suites_mentioning(repo, targets, names):
    """test target の原文で、名前のどれかを語として含むファイルの suite (型の名前)。"""
    if not names:
        return []
    word = re.compile(r"\b(?:" + "|".join(map(re.escape, names)) + r")\b")
    found = set()
    for target in targets:
        for path in sorted((repo / "Tests" / target).rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            if word.search(blank_comments(text)):
                found.update(f"{target}.{name}" for name in TOP_LEVEL_SUITE.findall(text))
    return sorted(found)


def filter_for(targets, suites):
    """`swift test --filter` の正規表現。suite があれば suite に、無ければ target に絞る。"""
    if suites:
        return "|".join(re.escape(s) + r"\b" for s in suites)
    return "|".join(re.escape(t) + r"\." for t in targets)


# ------------------------------------------------------------------ 記録と結末

def read_record(path):
    """(状態, 検査の列)。状態は ok / missing / unreadable。検査は (ID, 結末)。"""
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        return "missing", []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return "unreadable", []
    cases = []
    for case in root.iter("testcase"):
        ident = f"{case.get('classname', '')}/{case.get('name', '')}"
        if case.find("failure") is not None or case.find("error") is not None:
            cases.append((ident, "failed"))
        elif case.find("skipped") is not None:
            cases.append((ident, "skipped"))
        else:
            cases.append((ident, "passed"))
    if not cases:
        return "unreadable", []
    return "ok", cases


# 取り消しの testID が読めないときの ident。どの suite にも結べないので、関連の suite の
# 取り消しとして数える (評価できなかった側へ倒す)
UNKEYED_IDENT = "(testID が読めない)"
LOCATION = re.compile(r"/[^/]*:\d+:\d+$")


def read_cancelled(path):
    """(問題, 取り消しの列)。問題は None か読めない理由。取り消しは (ident, "cancelled")。

    読みは read-test-record.py と共有する。事象の記録が無い・読めない回は、取り消しが無いと
    読ませずに問題として返す (取り消しを見落として「生き残り」に数えない)。ident は xunit の
    `<classname>/<name>` と同じ綴りで、testID の末尾の `/<file>:<line>:<column>` を落としたもの。
    """
    reason, items, _, _ = _read_test_record().read_cancellations(path)
    if reason is not None:
        return f"事象の記録: {reason}", []
    return None, [(UNKEYED_IDENT if tid is None else LOCATION.sub("", tid), "cancelled")
                  for tid, _, _, _ in items]


def suite_of(ident):
    """`MokumeCoreTests.Outer/Inner/test()` → `MokumeCoreTests.Outer`。"""
    return ident.split("/", 1)[0]


def classify(build, test, record_state, cases, baseline_failed, related, gpu_hint=False):
    """1 回の実行の結末。(結末, 理由, 殺した検査)。

    build / test は "ok" / "failed" / "timeout"。related は関連の suite (`<target>.<型>`)。
    """
    if build == "timeout" or test == "timeout":
        return "timeout", "1 件の期限を越えた", []
    if build == "failed":
        return "invalid", "build: 変異を当てると組めない", []
    if record_state in ("missing", "unreadable"):
        return "invalid", f"abort: 記録が {record_state} (プロセスごと落ちた)", []
    if record_state != "ok":
        return "invalid", f"abort: {record_state}", []
    killers = sorted(ident for ident, result in cases
                     if result == "failed" and ident not in baseline_failed)
    if killers:
        return "killed", None, killers
    if test == "failed" and not any(result == "failed" for _, result in cases):
        return "invalid", "abort: 失敗の無い記録のまま非 0 で終わった", []
    skipped = [ident for ident, result in cases if result == "skipped"]
    related_skipped = [i for i in skipped if suite_of(i) in related]
    cancelled = [ident for ident, result in cases if result == "cancelled"]
    related_cancelled = [i for i in cancelled if i == UNKEYED_IDENT or suite_of(i) in related]
    if related_skipped or related_cancelled or (gpu_hint and (skipped or cancelled)):
        parts = []
        if related_skipped or (gpu_hint and skipped):
            parts.append(f"関連の suite で {len(related_skipped) or len(skipped)} 件が飛んだ")
        if related_cancelled or (gpu_hint and cancelled):
            parts.append(f"関連の suite で {len(related_cancelled) or len(cancelled)} 件が Test.cancel で取り消された")
        return "unevaluated", "・".join(parts), []
    return "survived", None, []


# ------------------------------------------------------------------ 帰属

def read_catalog(path):
    """(状態, {suite の型名: (提案, Issue)})。状態は present / missing / unreadable。"""
    path = Path(path)
    if not path.is_file():
        return "missing", {}
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) < 3 or not columns[0].strip() or not columns[1].strip():
            return "unreadable", {}
        if columns[0].strip() == "suite":
            continue
        rows[columns[0].strip()] = (columns[1].strip(), columns[2].strip())
    return "present", rows


def proposal_of(ident, catalog):
    """検査の ID の suite (入れ子なら内側から) を表で引く。無ければ `-`。"""
    head = ident.split("/")
    names = [head[0].split(".", 1)[-1]] + head[1:-1]
    for name in reversed(names):
        if name in catalog:
            return catalog[name][0]
    return NOT_IN_CATALOG


def attribute(mutants, catalog_state, catalog):
    """提案ごとの {killed, sole}。表が無い回は空 (catalog.state が理由を名乗る)。"""
    totals = {}
    for mutant in mutants:
        if mutant.get("outcome") != "killed":
            continue
        if catalog_state != "present":
            mutant["proposals"], mutant["sole"] = [], None
            continue
        proposals = sorted({proposal_of(k, catalog) for k in mutant["killers"]})
        mutant["proposals"] = proposals
        mutant["sole"] = proposals[0] if len(proposals) == 1 else None
        for proposal in proposals:
            entry = totals.setdefault(proposal, {"killed": 0, "sole": 0})
            entry["killed"] += 1
            if mutant["sole"] == proposal:
                entry["sole"] += 1
    return totals


def counts_of(mutants):
    counts = {name: 0 for name in OUTCOMES}
    for mutant in mutants:
        counts[mutant["outcome"]] += 1
    scored = counts["killed"] + counts["survived"]
    return counts, (round(counts["killed"] / scored, 4) if scored else None)


# ------------------------------------------------------------------ 実行

class Interrupted(Exception):
    pass


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout


def run_limited(command, cwd, seconds, log):
    """期限つきで走らせる。"ok" / "failed" / "timeout"。越えたらプロセスグループごと殺す。"""
    if seconds <= 0:
        return "timeout"
    with open(log, "ab") as out:
        process = subprocess.Popen(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return "timeout"
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    return "ok" if code == 0 else "failed"


class Runner:
    def __init__(self, repo, work, timeout, gpu_slot):
        self.repo, self.work, self.timeout = repo, Path(work), timeout
        self.swift = os.environ.get("MOKUME_MUTATE_SWIFT", "swift")
        self.wrap = ["python3", str(repo / "scripts" / "gpu-slot.py"), "--"] if gpu_slot else []
        self.log = self.work / "mutate-log.txt"
        self.baselines = {}
        self.runs = 0

    def once(self, pattern, deadline):
        """build と test を 1 回。(build, test, 記録の状態, 検査)。"""
        self.runs += 1
        record_base = self.work / f"run-{self.runs}.xml"
        record = self.work / f"run-{self.runs}-swift-testing.xml"
        events = self.work / f"run-{self.runs}-events.jsonl"
        build = run_limited([self.swift, "build", "--build-tests"], self.repo,
                            deadline - time.monotonic(), self.log)
        if build != "ok":
            return build, "skipped", "missing", []
        test = run_limited(self.wrap + [self.swift, "test", "--skip-build", "--filter", pattern,
                                        "--xunit-output", str(record_base),
                                        "--event-stream-output-path", str(events),
                                        "--event-stream-version", "0"],
                           self.repo, deadline - time.monotonic(), self.log)
        if test == "timeout":
            return build, test, "missing", []
        state, cases = read_record(record)
        if state == "ok":
            # 取り消しは xunit で passed と同じに見える。事象の記録から足す (#3348)
            problem, cancelled = read_cancelled(events)
            if problem is not None:
                return build, test, problem, cases
            cases = cases + cancelled
        return build, test, state, cases

    def baseline(self, pattern):
        """変異なしで同じ集合を回し、もとから赤い検査を覚える。組めなければ None。"""
        if pattern not in self.baselines:
            build, test, state, cases = self.once(pattern, time.monotonic() + self.timeout)
            if build != "ok" or state != "ok":
                self.baselines[pattern] = None
            else:
                self.baselines[pattern] = {i for i, r in cases if r == "failed"}
        return self.baselines[pattern]


def stage(runner, path, original, mutated, pattern, related, gpu_hint, scope):
    baseline = runner.baseline(pattern)
    if baseline is None:
        raise SystemExit(f"mutate: 変異なしの build か test の記録が成り立たない (--filter {pattern})。"
                         f" 材料は {runner.log}")
    started = time.monotonic()
    path.write_text(mutated, encoding="utf-8")
    try:
        build, test, state, cases = runner.once(pattern, started + runner.timeout)
    finally:
        path.write_text(original, encoding="utf-8")
    outcome, reason, killers = classify(build, test, state, cases, baseline, set(related), gpu_hint)
    return {"scope": scope, "filter": pattern, "outcome": outcome, "reason": reason,
            "killers": killers, "skipped": sum(1 for _, r in cases if r == "skipped"),
            "cancelled": sum(1 for _, r in cases if r == "cancelled"),
            "seconds": round(time.monotonic() - started, 1)}


def evaluate(runner, package, mutant, wide_only):
    repo = runner.repo
    path = repo / mutant["file"]
    original = path.read_text(encoding="utf-8")
    mutated, reason = apply(original, mutant)
    module = module_of(mutant["file"])
    targets = test_targets(package, module) if module else []
    line = mutant.get("line") or (original[: original.find(mutant["find"])].count("\n") + 1
                                  if mutated is not None else 1)
    names = enclosing_names(original, line)
    related = suites_mentioning(repo, targets, names)
    mutant.update({"line": line, "targets": targets, "symbols": names, "suites": related, "stages": []})
    if mutated is None:
        mutant.update({"outcome": "invalid", "reason": reason, "killers": []})
        return
    if not targets:
        mutant.update({"outcome": "invalid", "reason": f"範囲外: {mutant['file']} の test target が無い",
                       "killers": []})
        return
    gpu_hint = bool(mutant.get("gpu"))
    plans = []
    if related and not wide_only:
        plans.append(("suites", filter_for(targets, related)))
    plans.append(("targets", filter_for(targets, [])))  # 関連の suite は target の中から選ぶので含まれる
    for scope, pattern in plans:
        result = stage(runner, path, original, mutated, pattern, related, gpu_hint, scope)
        mutant["stages"].append(result)
        if result["outcome"] not in ("survived", "unevaluated"):
            break
    last = mutant["stages"][-1]
    mutant.update({"outcome": last["outcome"], "reason": last["reason"], "killers": last["killers"]})


def dirty_sources(repo):
    return git(repo, "status", "--porcelain", "--", "Sources").strip()


def run(args):
    repo = Path(args.repo).resolve()
    if dirty_sources(repo):
        print("mutate: Sources/ に手元の変更がある。書き戻しで消さないよう、commit か退避してから回す",
              file=sys.stderr)
        return 2
    if args.bundle:
        mutants, wide_only = load_bundle(repo / args.bundle), True
    else:
        mutants, wide_only = range_candidates(repo, args.since), False
    if args.limit is not None:
        mutants = mutants[: args.limit]
    package = json.loads(subprocess.run([os.environ.get("MOKUME_MUTATE_SWIFT", "swift"), "package",
                                         "dump-package"], cwd=repo, check=True,
                                        capture_output=True, text=True).stdout)
    work = Path(args.work or tempfile.mkdtemp(prefix="mutate-"))
    work.mkdir(parents=True, exist_ok=True)
    runner = Runner(repo, work, args.timeout, not args.no_gpu_slot)
    started = time.monotonic()
    deadline = started + args.budget if args.budget is not None else None

    def interrupt(signum, frame):
        raise Interrupted(signum)

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    interrupted = False
    try:
        for mutant in mutants:
            if interrupted or (deadline is not None and time.monotonic() >= deadline):
                mutant.update({"outcome": "unrun", "reason": "全体の期限", "killers": []})
                continue
            begun = time.monotonic()
            try:
                evaluate(runner, package, mutant, wide_only)
            except Interrupted:
                interrupted = True
                mutant.update({"outcome": "unrun", "reason": "止められた", "killers": []})
            mutant["seconds"] = round(time.monotonic() - begun, 1)
            print(f"mutate: {mutant['id']} {mutant['file']}:{mutant.get('line')} {mutant['outcome']}",
                  file=sys.stderr)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.signal(signal.SIGINT, signal.SIG_DFL)
    catalog_path = repo / args.catalog
    catalog_state, catalog = read_catalog(catalog_path)
    attribution = attribute(mutants, catalog_state, catalog)
    counts, score = counts_of(mutants)
    result = {
        "version": VERSION,
        "head": git(repo, "rev-parse", "HEAD").strip(),
        "since": None if args.bundle else args.since,
        "bundle": args.bundle,
        "catalog": {"path": args.catalog, "state": catalog_state, "rows": len(catalog)},
        "seconds": round(time.monotonic() - started, 1),
        "budget": args.budget,
        "timeout": args.timeout,
        "counts": counts,
        "score": score,
        "attribution": attribution,
        "mutants": mutants,
    }
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"mutate: 結果を {args.out} へ書いた。材料は {runner.log}", file=sys.stderr)
    return 130 if interrupted else 0


def candidates(args):
    repo = Path(args.repo).resolve()
    if args.bundle:
        found = load_bundle(repo / args.bundle)
    else:
        found = range_candidates(repo, args.since)
    print(json.dumps(found, ensure_ascii=False, indent=2))
    return 0


# ------------------------------------------------------------------ 要約

def check_result(data):
    """形が約束どおりか。違えば理由の文字列。"""
    if not isinstance(data, dict) or data.get("version") != VERSION:
        return f"version {VERSION} の結果ではない"
    counts = data.get("counts")
    if not isinstance(counts, dict) or any(not isinstance(counts.get(k), int) for k in OUTCOMES):
        return "counts に結末の件数が揃っていない"
    mutants = data.get("mutants")
    if not isinstance(mutants, list):
        return "mutants が無い"
    if sum(counts.values()) != len(mutants):
        return f"counts の合計 {sum(counts.values())} が mutants の {len(mutants)} 件と合わない"
    if not mutants:
        return "変異が 1 件も無い (回す候補が無かったのか、読めなかったのかを記録から分けられない)"
    return None


def summary_text(data):
    counts, score = data["counts"], data.get("score")
    evaluated = counts["killed"] + counts["survived"] + counts["invalid"]
    lines = [
        f"### 変異の検査 (`{data.get('bundle') or 'since ' + str(data.get('since'))}` @ `{str(data.get('head'))[:12]}`)",
        "",
        f"評価 {evaluated}・殺した {counts['killed']}・生き残り {counts['survived']}・無効 {counts['invalid']}"
        f"・時間切れ {counts['timeout']}・未評価 (GPU が無い・Test.cancel) {counts['unevaluated']}・回しきれず {counts['unrun']}",
        "",
        f"点数: {'%.1f%%' % (score * 100) if score is not None else 'なし (殺した + 生き残りが 0)'}"
        f" (所要 {data.get('seconds')} 秒)",
        "",
    ]
    catalog = data.get("catalog") or {}
    if catalog.get("state") != "present":
        lines += [f"帰属: `{catalog.get('path')}` が {catalog.get('state')} なので、提案へ引いていない", ""]
    elif data.get("attribution"):
        lines += ["| 提案 | 殺した | 単独で殺した |", "| --- | --- | --- |"]
        for proposal, entry in sorted(data["attribution"].items()):
            lines.append(f"| {proposal} | {entry['killed']} | {entry['sole']} |")
        lines.append("")
    survivors = [m for m in data["mutants"] if m.get("outcome") == "survived"]
    if survivors:
        lines += ["#### 生き残り", "", "| id | 位置 | 変異 |", "| --- | --- | --- |"]
        for m in survivors:
            change = m.get("operator") or m.get("note") or ""
            lines.append(f"| {m['id']} | `{m['file']}:{m.get('line')}` | {change} |")
        lines.append("")
    return "\n".join(lines)


def summary(args):
    path = Path(args.result)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        problem = check_result(data)
    except FileNotFoundError:
        problem = "記録が無い"
    except (OSError, ValueError) as error:
        problem = f"読めない ({error})"
    if problem:
        text = (f"### 変異の検査\n\nunreadable: `{path}` — {problem}。"
                "検査の検証力の記録として読まない。点数は前回のまま更新しない\n")
        print(text)
        append_step_summary(text)
        return 1
    text = summary_text(data)
    print(text)
    append_step_summary(text)
    return 0


def append_step_summary(text):
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as out:
            out.write(text + "\n")


def main(argv):
    parser = argparse.ArgumentParser(prog="mutate.py", description="変異の検査 (#3221)。詳細は冒頭")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("candidates", "run"):
        sub = commands.add_parser(name)
        source = sub.add_mutually_exclusive_group(required=True)
        source.add_argument("--since", help="この commit から HEAD までに変わった行を候補にする")
        source.add_argument("--bundle", help="固定の束 (JSON) を回す")
        sub.add_argument("--repo", default=".")
        if name == "run":
            sub.add_argument("--out", required=True)
            sub.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="1 件の期限 (秒)")
            sub.add_argument("--budget", type=float, default=None, help="全体の期限 (秒)")
            sub.add_argument("--limit", type=int, default=None)
            sub.add_argument("--catalog", default=DEFAULT_CATALOG)
            sub.add_argument("--work", default=None, help="記録と材料の置き場 (既定は一時ディレクトリ)")
            sub.add_argument("--no-gpu-slot", action="store_true", help="scripts/gpu-slot.py を通さない")
    sub = commands.add_parser("summary")
    sub.add_argument("result")
    args = parser.parse_args(argv[1:])
    return {"candidates": candidates, "run": run, "summary": summary}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
