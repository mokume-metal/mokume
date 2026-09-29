#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-agents-md-size.py の検査 (#737 / #1668)。

固定したいのは 5 つ:

- **全体は合流先との分岐点との差で見る** — 増やした PR だけに宣言を求め、縮めた PR と
  変えていない PR は宣言なしで通す。宣言と実測が 1 字でも違えば赤
- **宣言は行全体の 1 形だけを読み、揺れは名指しで赤にする** — 全角コロン・「字」付き・
  バッククォート・2 行。黙って「宣言なし」と読むと、書いた人が理由に辿り着けない
- **範囲の重ならない 2 本は衝突せず、後の 1 本の増分は自分の分だけと数えられる** —
  記録値の 1 行を共有していた頃は、ここで merge queue から外れていた (#1668 の完了条件 2。
  一時リポジトリで `git merge-tree` を実際に走らせて固定する)
- **数え方がロケールに依らない** — `LC_ALL=C` でも日本語をバイトではなく文字で数える
  (#737 の起票はここを踏んで単位を取り違えた)
- **節はコードフェンスの中の `## ` で割れない**

review-gate がこれを呼ぶときの材料の取り方 (merge-base・HTML コメント・CRLF) は
review_gate_test.py が見る。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-agents-md-size.py"


def _load():
    spec = importlib.util.spec_from_file_location("check_agents_md_size", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


size = _load()

DOC = "# AGENTS.md\n\n冒頭。\n\n## 進め方\n\n規律。\n\n## 描画\n\n```bash\n## これは見出しではない\n```\n"


class GrowthTest(unittest.TestCase):
    def test_unchanged_length_needs_no_declaration(self):
        self.assertEqual(size.growth_problems(DOC, DOC, None), [])

    def test_one_more_character_without_a_declaration_is_red(self):
        problems = size.growth_problems(DOC, DOC + "あ", None)
        self.assertEqual(len(problems), 1)
        self.assertIn("1 字増えている", problems[0])
        # 書くべき 1 行と降ろし先を名乗る (完了条件 4)
        self.assertIn("AGENTS.md の増分: +1", problems[0])
        self.assertIn("経緯と実測は Issue / PR", problems[0])

    def test_shrinking_is_green_without_touching_anything(self):
        # 記録値を下げる手作業はもう無い (完了条件 3)
        shorter = DOC.replace("規律。\n\n", "")
        self.assertEqual(size.growth_problems(DOC, shorter, None), [])

    def test_matching_declaration_is_green(self):
        self.assertEqual(size.growth_problems(DOC, DOC + "足した。\n", 5), [])

    def test_declaration_off_by_one_is_red(self):
        problems = size.growth_problems(DOC, DOC + "足した。\n", 4)
        self.assertEqual(len(problems), 1)
        self.assertIn("(+4) が実測 (+5) と違う", problems[0])
        self.assertIn("「AGENTS.md の増分: +5」に直す", problems[0])

    def test_declaration_without_growth_is_red(self):
        problems = size.growth_problems(DOC, DOC, 5)
        self.assertEqual(len(problems), 1)
        self.assertIn("宣言の行を消す", problems[0])

    def test_matching_negative_declaration_is_green(self):
        shorter = DOC.replace("規律。\n\n", "")
        self.assertEqual(size.growth_problems(DOC, shorter, len(shorter) - len(DOC)), [])


class DeclarationTest(unittest.TestCase):
    def test_reads_the_declaration(self):
        for line, value in (("AGENTS.md の増分: +129", 129), ("AGENTS.md の増分: 7", 7),
                            ("AGENTS.md の増分: -3", -3), ("AGENTS.md の増分: +0", 0)):
            with self.subTest(line=line):
                self.assertEqual(size.parse_declaration(f"本文\n\n{line}\n\n続き\n"), (value, []))

    def test_no_declaration(self):
        self.assertEqual(size.parse_declaration("本文だけ\n"), (None, []))

    def test_a_mention_in_prose_is_not_a_declaration(self):
        # 文中で触れただけの行は宣言でも、形の違う宣言でもない
        body = "この PR は AGENTS.md の増分を 0 に保つ\nAGENTS.md の増分は宣言しない\n"
        self.assertEqual(size.parse_declaration(body), (None, []))

    def test_near_misses_are_named(self):
        for line in ("AGENTS.md の増分：+5", "AGENTS.md の増分: +5 字", "`AGENTS.md の増分: +5`",
                     "- AGENTS.md の増分: +5", "AGENTS.md の増分: ＋５", "AGENTS.md の増分:+5"):
            with self.subTest(line=line):
                value, problems = size.parse_declaration(f"{line}\n")
                self.assertIsNone(value)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("宣言の形が違う", problems[0])
                self.assertIn(size.DECLARATION_FORM, problems[0])

    def test_two_declarations_are_named(self):
        value, problems = size.parse_declaration("AGENTS.md の増分: +5\nAGENTS.md の増分: +5\n")
        self.assertIsNone(value)
        self.assertEqual(len(problems), 1)
        self.assertIn("2 行ある", problems[0])

    def test_crlf_body(self):
        self.assertEqual(size.parse_declaration("本文\r\nAGENTS.md の増分: +5\r\n"), (5, []))


class SectionTest(unittest.TestCase):
    def test_heading_inside_fence_does_not_split(self):
        titles = [t for t, _ in size.sections(DOC)]
        self.assertEqual(titles, ["(冒頭)", "進め方", "描画"])

    def test_subsection_counts_toward_parent(self):
        doc = "## 親\n\n### 子\n\n本文\n"
        self.assertEqual(size.sections(doc), [("(冒頭)", 0), ("親", len(doc))])

    def test_sections_add_up_to_whole(self):
        parts = size.sections(DOC)
        # 節の間の改行 1 つは節に数えない
        self.assertEqual(sum(n for _, n in parts) + len(parts) - 1, len(DOC))

    def test_section_over_limit_is_named(self):
        doc = "## 短い\n\nあ\n\n## 長い節\n\n" + "い" * 50 + "\n"
        problems = size.check(doc, limit=40)
        self.assertEqual(len(problems), 1)
        self.assertIn("節「長い節」", problems[0])

    def test_section_at_limit_is_green(self):
        doc = "## 節\n\n" + "う" * 10
        limit = size.sections(doc)[1][1]
        self.assertEqual(size.check(doc, limit=limit), [])


def run_script(*args, stdin="", env_extra=None, cwd=None):
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=stdin.encode("utf-8"), capture_output=True, env=env, cwd=cwd,
    )


class GrowthCommandTest(unittest.TestCase):
    """review-gate が呼ぶ `growth BASE HEAD` (本文は標準入力)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name) / "base"
        self.head = Path(self.tmp.name) / "head"
        self.base.write_text(DOC, encoding="utf-8")

    def test_counts_characters_not_bytes_under_c_locale(self):
        added = "日本語を足した。\n"
        # バイトで数えれば宣言と食い違って赤くなる
        self.assertNotEqual(len(added), len(added.encode("utf-8")))
        self.head.write_text(DOC + added, encoding="utf-8")
        result = run_script(
            "growth", str(self.base), str(self.head),
            stdin=f"AGENTS.md の増分: +{len(added)}\n",
            env_extra={"LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C", "PYTHONIOENCODING": "",
                       # C ロケールを UTF-8 へ読み替える Python 自身の救済 (PEP 538 / 540) を切る。
                       # 切らないと、エンコーディングを指定し忘れても緑のまま通る
                       "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(f"+{len(added)} 字で宣言どおり", result.stdout.decode("utf-8"))

    def test_red_names_the_reason_on_stderr(self):
        self.head.write_text(DOC + "足した。\n", encoding="utf-8")
        result = run_script("growth", str(self.base), str(self.head), stdin="本文\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("AGENTS.md の増分: +5", result.stderr.decode("utf-8"))

    def test_a_malformed_declaration_is_red_even_when_the_number_is_right(self):
        self.head.write_text(DOC + "足した。\n", encoding="utf-8")
        result = run_script("growth", str(self.base), str(self.head), stdin="AGENTS.md の増分：+5\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("宣言の形が違う", result.stderr.decode("utf-8"))


class TempRepo:
    """使い捨ての git リポジトリ。手元の署名設定は切る (temp_repo_signing_test.py)。"""

    def __init__(self, root: Path):
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.invalid")

    def git(self, *args) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.root), *args], capture_output=True, text=True, encoding="utf-8"
        )
        if result.returncode != 0:
            raise AssertionError(f"git {' '.join(args)} が失敗した: {result.stderr}")
        return result.stdout.strip()

    def commit(self, text: str, message: str) -> str:
        (self.root / "AGENTS.md").write_text(text, encoding="utf-8")
        self.git("add", "AGENTS.md")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def show(self, rev: str) -> str:
        return self.git("show", f"{rev}:AGENTS.md") + "\n"


BASE_DOC = "# AGENTS.md\n\n## 進め方\n\n規律。\n\n## コメント\n\n置き場。\n"


class ParallelMergeTest(unittest.TestCase):
    """完了条件 2: 同じ base から別の節に足した 2 本 (#1664 × #1665 と同じ形)。

    先の 1 本が入った後も、後の 1 本は `git merge-tree` で衝突せず、後の 1 本の増分は
    merge-base と比べて自分の分だけと数えられる。範囲の重ならない合流では字数の差が
    PR ごとの増分の和になるので、merge queue で group の base と比べた差も一致する。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = TempRepo(Path(self.tmp.name))

    def test_two_prs_on_different_sections_do_not_conflict_and_count_their_own_growth(self):
        repo = self.repo
        base = repo.commit(BASE_DOC, "base")
        first_text = BASE_DOC.replace("規律。\n", "規律。\n足した一行目。\n")
        second_text = BASE_DOC.replace("置き場。\n", "置き場。\n別の節に足した。\n")
        repo.git("checkout", "-q", "-b", "first", base)
        first = repo.commit(first_text, "first")
        repo.git("checkout", "-q", "-b", "second", base)
        second = repo.commit(second_text, "second")
        # 先の 1 本が main に入る (squash と同じく、main は first の木になる)
        repo.git("checkout", "-q", "main")
        repo.git("merge", "-q", "--ff-only", first)

        # 後の 1 本は衝突しない (記録値の 1 行があった頃はここで衝突した)
        merged_tree = repo.git("merge-tree", "--write-tree", "main", second)
        merged = repo.git("show", f"{merged_tree}:AGENTS.md") + "\n"

        second_growth = len(second_text) - len(BASE_DOC)
        # merge-base と比べれば、後の 1 本の増分は自分の分だけ
        merge_base = repo.git("merge-base", "main", second)
        self.assertEqual(merge_base, base)
        self.assertEqual(size.growth_problems(repo.show(merge_base), second_text, second_growth), [])
        # base の先端と比べると、先の 1 本の分が混ざって宣言と合わない (だから先端とは比べない)
        self.assertNotEqual(size.growth_problems(repo.show("main"), second_text, second_growth), [])
        # 合流後の木と group の base (main) の差は、PR 時点の増分と一致する (加法性)
        self.assertEqual(len(merged) - len(repo.show("main")), second_growth)
        self.assertEqual(len(merged) - len(BASE_DOC), (len(first_text) - len(BASE_DOC)) + second_growth)


class LocalRunTest(unittest.TestCase):
    """既定の実行 (make agents-md-size): 節の上限は赤、分岐点との差は表示だけ。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.agents = self.root / "AGENTS.md"

    def run_local(self, env_extra=None):
        env = {"GITHUB_ACTIONS": "", **(env_extra or {})}
        result = run_script("--agents", str(self.agents), env_extra=env)
        return result.returncode, result.stdout.decode("utf-8"), result.stderr.decode("utf-8")

    def make_repo_with_growth(self, grow: str):
        repo = TempRepo(self.root)
        repo.commit(DOC, "base")
        repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.agents.write_text(DOC + grow, encoding="utf-8")

    def test_shows_growth_from_the_merge_base_without_turning_red(self):
        self.make_repo_with_growth("足した。\n")
        code, out, err = self.run_local()
        self.assertEqual(code, 0, err)
        self.assertIn("より +5 字", out)
        self.assertIn("AGENTS.md の増分: +5", out)

    def test_counts_characters_not_bytes_under_c_locale(self):
        self.make_repo_with_growth("足した。\n")
        code, out, err = self.run_local(
            {"LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"}
        )
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok: AGENTS.md は {len(DOC) + 5} 字", out)
        self.assertIn("より +5 字", out)

    def test_ci_does_not_show_growth(self):
        self.make_repo_with_growth("足した。\n")
        code, out, err = self.run_local({"GITHUB_ACTIONS": "true"})
        self.assertEqual(code, 0, err)
        self.assertNotIn("分岐点", out + err)

    def test_outside_git_does_not_show_growth(self):
        self.agents.write_text(DOC, encoding="utf-8")
        code, out, err = self.run_local()
        self.assertEqual(code, 0, err)
        self.assertNotIn("分岐点", out + err)

    def test_section_over_limit_is_red(self):
        # 節の上限は今までどおり make ci-check で効く (完了条件 5)
        self.agents.write_text("## 長い節\n\n" + "い" * (size.SECTION_LIMIT + 1) + "\n", encoding="utf-8")
        code, _, err = self.run_local()
        self.assertEqual(code, 1)
        self.assertIn("節「長い節」", err)
        self.assertIn("節ごとの字数", err)


if __name__ == "__main__":
    unittest.main()
