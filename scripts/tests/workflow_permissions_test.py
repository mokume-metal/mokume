#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""workflow のジョブが持つ書き込み権限と、そのジョブが打つ書き込みの対応の検査 (#2675)。

#2614 では stall-watch.yml の当番が `contents: read` のまま `gh pr merge --auto` を打ち、
60 回に 60 回とも拒まれた。偽 gh は権限を見ないので、スクリプトの検査は緑のままだった。
権限の外の書き込みは **run を赤くせずに黙って失敗する** ことがある (stall-act は失敗を
名乗るだけで、当番の run は他の対処を続ける) ので、ここで全 workflow の対応を固定する:

  1. ジョブが打つ書き込みに要る権限を、ジョブが持っている
  2. ジョブが持つ書き込み権限は、どれかの書き込みが使っている (使わない権限を持たない)
  3. 表 (`WRITE_OPS` / `API_WRITES` / `USES_WRITES`) に無い書き込みは、黙って通さず赤で名乗る
  4. どの workflow もトップに `permissions:` を持つ (リポジトリの既定に委ねると判定できない)

ジョブが打つものは、`run:` の本文・そこから呼ぶ `scripts/` のスクリプト (スクリプトの中から
`$here/x.sh` などで呼ぶものも推移的に)・`uses:` の action から集める。コメントと
ヒアドキュメントの本文 (人へ返す説明の「gh pr merge …」) は読まない。

**書き込みと権限の対応はこの表にだけ置く。** render_workflow_test.py の 5・6 は
「専用機のジョブに権限を持たせない」「issues: write を持つのは GitHub ホストの後続ジョブだけ」
という置き場の方針で、対応とは別の約束なので向こうに残す。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import shlex
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"
SCRIPTS = REPO / "scripts"

# gh のサブコマンドと、それに要る GITHUB_TOKEN の書き込み権限。**gh pr merge (auto-merge の
# 予約) には contents: write も要る** — pull-requests: write だけでは
# enablePullRequestAutoMerge が FORBIDDEN になることを実物で確かめた (#2614 の probe、
# run 38541307087)。知らない書き込みは検査を赤にするので、増やすときはここへ足す
WRITE_OPS = {
    "pr merge": {"contents", "pull-requests"},
    **{f"pr {v}": {"pull-requests"} for v in ("comment", "edit", "close", "reopen", "ready", "review", "create")},
    **{f"issue {v}": {"issues"} for v in ("comment", "edit", "close", "reopen", "create")},
    "run rerun": {"actions"},
    "run cancel": {"actions"},
    "workflow run": {"actions"},
    **{f"release {v}": {"contents"} for v in ("create", "upload", "edit")},
}

# 書かない gh のサブコマンドの動詞。ここにも WRITE_OPS にも無いものは知らない書き込みとして赤
READ_VERBS = {"view", "list", "status", "diff", "checks", "download", "watch"}

# gh api の GET 以外の REST の行き先 (path の正規表現) と要る権限
# リポジトリは repos/o/r・repos/{owner}/{repo}・repos/$REPO のどれでも書かれる
_REPO = r"^/?repos/(?:\$\{?\w+\}?|[^/]+/[^/]+)/"
API_WRITES = (
    (re.compile(_REPO + "actions/"), {"actions"}),
    (re.compile(_REPO + "issues/"), {"issues"}),
    (re.compile(_REPO + "pulls/"), {"pull-requests"}),
)

# 書き込み権限を使う action
USES_WRITES = {
    "actions/deploy-pages": {"pages", "id-token"},
}

# git push (タグも) は contents: write を使う
GIT_PUSH = re.compile(r"(?:^|[;&|({]|\$\(|\brun:|\bthen|\belse|\bdo)\s*git\s+push\b")

# 実行される gh (コマンドの位置にあるもの)。`run: gh …` の 1 行の形も拾う
GH_COMMAND = re.compile(r"(?:^|[;&|({]|\$\(|\brun:|\bif\s+!?|\bthen|\belse|\bdo|!)\s*(gh)\s+")

# スクリプトの呼び出し。workflow からは scripts/x、スクリプトの中からは $here/x と
# $(dirname "${BASH_SOURCE[0]}")/x の形で呼ぶ (syphon-check-pr.sh の ${…:-$here/x} も)
INVOKE = re.compile(
    r'(?:\b(?:bash|source|python3|exec)\s+|(?:^|[;&|({]|\$\(|\brun:)\s*\.\s+|:-)"?'
    r'(?:scripts/|\$here/|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/)([\w.-]+\.(?:sh|py))'
)

HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
PY_GH = re.compile(r'\[\s*"gh"\s*,([^\]]*)\]')
PY_STR = re.compile(r'f?"([^"]*)"')


def code_lines(text):
    """コメント・ヒアドキュメントの本文を落とし、行の継続 (\\) を畳んだ論理行。"""
    out, pending, tag = [], "", None
    for raw in text.splitlines():
        if tag is not None:
            if raw.strip() == tag:
                tag = None
            continue
        if raw.lstrip().startswith("#"):
            continue
        line = pending + raw.strip()
        if line.endswith("\\"):
            pending = line[:-1] + " "
            continue
        pending = ""
        m = HEREDOC.search(line)
        if m:
            tag = m.group(2)
        out.append(line)
    return out


def in_code(line):
    """各位置がコードの文脈 (引用の外か、引用の中の $( … ) の中) にあるか。"""
    stack, flags, i = ["code"], [], 0
    while i < len(line):
        ch, top = line[i], stack[-1]
        flags.append(top == "code")
        step = 1
        if top == "sq":
            if ch == "'":
                stack.pop()
        elif top == "dq":
            if ch == "\\":
                flags.append(False)
                step = 2
            elif ch == '"':
                stack.pop()
            elif line.startswith("$(", i):
                flags.append(False)
                stack.append("code")
                step = 2
        else:
            if ch == "'":
                stack.append("sq")
            elif ch == '"':
                stack.append("dq")
            elif ch == "(":
                stack.append("code")
            elif ch == ")" and len(stack) > 1:
                stack.pop()
        i += step
    return flags


def cut(rest):
    """gh の後ろを、引用の外の | ; && ) で切る (同じ行の次のコマンドの旗を混ぜない)。"""
    quote, depth = None, 0
    for i, ch in enumerate(rest):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                return rest[:i]
            depth -= 1
        elif ch in "|;&" and depth == 0:
            return rest[:i]
    return rest


def tokens_of(cmd):
    try:
        toks = shlex.split(cmd)
    except ValueError:
        toks = cmd.split()
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if t in ("--repo", "-R"):
            skip = True
            continue
        out.append(t)
    return out


def classify(cmd):
    """gh の引数 (gh を除く) → None (読み) / 要る権限の集合 / "unknown"。"""
    toks = tokens_of(cmd)
    if not toks:
        return None
    if toks[0] == "api":
        method, path, args = "GET", None, toks[1:]
        has_fields = False
        i = 0
        while i < len(args):
            t = args[i]
            if t in ("-X", "--method"):
                method = args[i + 1].upper() if i + 1 < len(args) else method
                i += 2
                continue
            if t in ("-f", "-F", "--field", "--raw-field", "--input"):
                has_fields = True
                i += 2
                continue
            if t in ("-H", "--header", "-q", "--jq", "-t", "--template", "--cache", "-p", "--preview", "--hostname"):
                i += 2
                continue
            if not t.startswith("-") and path is None:
                path = t
            i += 1
        if path == "graphql":
            return "unknown" if "mutation" in cmd else None
        if method == "GET" and has_fields:
            method = "POST"
        if method == "GET":
            return None
        return next((need for pat, need in API_WRITES if path and pat.search(path)), "unknown")
    if len(toks) < 2:
        return None
    op = f"{toks[0]} {toks[1]}"
    if op in WRITE_OPS:
        return WRITE_OPS[op]
    if toks[1] in READ_VERBS:
        return None
    return "unknown"


def writes_in(text, python=False):
    """(行, 要る権限 or "unknown") の並び。"""
    found = []
    if python:
        for m in PY_GH.finditer(text):
            cmd = " ".join(shlex.quote(s) for s in PY_STR.findall(m.group(1)))
            need = classify(cmd)
            if need is not None:
                found.append((f"gh {cmd}", need))
        return found
    for line in code_lines(text):
        code = in_code(line)
        for m in GH_COMMAND.finditer(line):
            if not code[m.start(1)]:
                continue  # 引用の中の説明文の「(gh run rerun …」
            need = classify(cut(line[m.end() :]))
            if need is not None:
                found.append((line, need))
        if GIT_PUSH.search(line):
            found.append((line, {"contents"}))
    return found


def scripts_from(text, seen):
    """text が呼ぶスクリプトを推移的に集める (scripts/ からの相対の名前)。"""
    for line in code_lines(text):
        for name in INVOKE.findall(line):
            path = SCRIPTS / name
            if name in seen or not path.is_file():
                continue
            seen.add(name)
            scripts_from(path.read_text(encoding="utf-8"), seen)
    return seen


def permissions(block):
    """`permissions:` の本文 → {スコープ: read|write}。読めなければ None。"""
    granted = {}
    for line in block.splitlines():
        if not line.strip():
            continue
        m = re.match(r"^\s+([a-z-]+):\s*(read|write|none)\b", line)
        if not m:
            return None
        granted[m.group(1)] = m.group(2)
    return granted


def job_permissions(body):
    m = re.search(r"(?m)^    permissions:[ \t]*(\S.*)?$", body)
    if not m:
        return None
    if m.group(1):
        return {} if m.group(1).strip() == "{}" else None
    rest = body[m.end() :].splitlines()[1:]
    block = []
    for ln in rest:
        if ln.strip() and not ln.startswith("      "):
            break
        block.append(ln)
    return permissions("\n".join(block)) or {}


class Job:
    def __init__(self, wf, name, body, top_granted):
        self.label = f"{wf.name}:{name}"
        own = job_permissions(body)
        self.granted = top_granted if own is None else own
        self.write_scopes = {k for k, v in (self.granted or {}).items() if v == "write"}
        self.ops = [("run:", line, need) for line, need in writes_in(body)]
        for name_ in sorted(scripts_from(body, set())):
            text = (SCRIPTS / name_).read_text(encoding="utf-8")
            self.ops += [(f"scripts/{name_}", line, need) for line, need in writes_in(text, python=name_.endswith(".py"))]
        for action in re.findall(r"(?m)^\s+(?:- )?uses:\s*([\w.-]+/[\w.-]+)@", body):
            if action in USES_WRITES:
                self.ops.append(("uses:", action, USES_WRITES[action]))


def load_jobs():
    jobs = []
    for wf in sorted(WORKFLOWS.glob("*.yml")):
        top, bodies = workflow.split(wf.read_text(encoding="utf-8"))
        top_granted = permissions(top["permissions"]) if "permissions" in top else None
        for name, body in bodies.items():
            jobs.append(Job(wf, name, body, top_granted))
    return jobs


class WorkflowPermissionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = load_jobs()
        cls.by_label = {j.label: j for j in cls.jobs}

    def test_どの_workflow_もトップに_permissions_を持つ(self):
        for wf in sorted(WORKFLOWS.glob("*.yml")):
            top, _ = workflow.split(wf.read_text(encoding="utf-8"))
            self.assertIn("permissions", top, f"{wf.name}: トップに permissions: が無い (リポジトリの既定に委ねない)")
            self.assertIsNotNone(permissions(top["permissions"]), f"{wf.name}: トップの permissions: を読めない")

    def test_走査が空振りしていない(self):
        # 推移の呼び出し・ヒアドキュメントの外の gh・run: の 1 行・git push・uses: を、それぞれ拾えている
        expect = {
            "stall-watch.yml:watch": ("scripts/stall-act.sh", {"actions"}),
            "queue-sweep.yml:sweep": ("scripts/queue-sweep.sh", {"actions"}),
            "close-cleanup.yml:drop-in-progress": ("run:", {"issues"}),
            "release.yml:release": ("run:", {"contents"}),
            "pages.yml:publish": ("uses:", {"pages", "id-token"}),
            "ruleset-drift.yml:drift": ("scripts/triage.sh", {"issues"}),
            "render.yml:scheduled-report": ("scripts/report-check-failure.sh", {"issues"}),
        }
        for label, (source, need) in expect.items():
            ops = self.by_label[label].ops
            self.assertTrue(any(s == source and n == need for s, _, n in ops), f"{label}: {source} の {sorted(need)} を拾えない: {ops}")
        # ヒアドキュメントの説明文 (report-runner-environment.sh の「gh pr merge …」) は拾わない
        env = self.by_label["render.yml:render-environment-report"].ops
        self.assertFalse(any("pr merge" in line for _, line, _ in env), env)

    def test_表に無い書き込みを打たない(self):
        for job in self.jobs:
            for source, line, need in job.ops:
                self.assertNotEqual(need, "unknown", f"{job.label}: {source} の書き込みの権限を表が知らない (WRITE_OPS / API_WRITES へ足す): {line}")

    def test_打つ書き込みに要る権限を_job_が持つ(self):
        for job in self.jobs:
            for source, line, need in job.ops:
                if need == "unknown":
                    continue
                self.assertLessEqual(
                    need,
                    job.write_scopes,
                    f"{job.label}: {source} の書き込みには {sorted(need - job.write_scopes)}: write が要る"
                    f" (持つ書き込み {sorted(job.write_scopes)}): {line}",
                )

    def test_使わない書き込みの権限を持たない(self):
        for job in self.jobs:
            used = set().union(*(n for _, _, n in job.ops if n != "unknown"))
            self.assertLessEqual(job.write_scopes, used, f"{job.label}: 使わない書き込みの権限を持つ: {sorted(job.write_scopes - used)}")


class ClassifyTest(unittest.TestCase):
    """表の読み方そのものの境界。"""

    def test_読みは書き込みに数えない(self):
        for cmd in ('pr view 1 --json title', 'api "repos/o/r/pulls/1" --jq .title', "api graphql -f query='{ x }'", "issue list -R o/r"):
            self.assertIsNone(classify(cmd), cmd)

    def test_書き込みは表の権限を返す(self):
        self.assertEqual(classify('pr merge 1 --auto --squash'), {"contents", "pull-requests"})
        self.assertEqual(classify('issue edit "$N" -R "$REPO" --remove-label x'), {"issues"})
        self.assertEqual(classify('api -X POST "repos/$REPO/actions/runs/1/cancel"'), {"actions"})
        self.assertEqual(classify('api "repos/$REPO/actions/jobs/1/rerun" -X POST --silent'), {"actions"})

    def test_知らない書き込みは_unknown(self):
        for cmd in ("label create x", "api graphql -f query='mutation { x }'", 'api "repos/o/r/labels" -f name=x', "cache delete 1"):
            self.assertEqual(classify(cmd), "unknown", cmd)

    def test_ヒアドキュメントとコメントは読まない(self):
        text = "cat <<EOF\n  gh pr merge 1 --auto\nEOF\n# gh issue create\ngh issue comment 1 \\\n  --body x\n"
        self.assertEqual([n for _, n in writes_in(text)], [{"issues"}])


if __name__ == "__main__":
    unittest.main()
