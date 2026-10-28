#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/sub-issue.sh の検査 (#78)。

sub-issue.sh は「作成 + 親への紐づけ + 親の分類の継承」を 1 コマンドにする。
継承の対象は #78 で type: ラベルから Issue Type へ移した (ADR-0004 決定 5)。

固定するのは継承の三態 (継ぐ / 上書きする / 継ぐものが無い) と、使い捨て検証用の
--test の雛形。紐づけ (sub_issues API) は script の存在理由そのものなので併せて見る。
既に在る Issue を繋ぐ --attach (#1661) は、作らないこと・型を継がないこと・既に親の居る
Issue を付け替えないことを見る。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "sub-issue.sh"

# 署名の名乗りに効く env (scripts/agent-signature.sh。#3149)
AGENT_ENV = [
    "MOKUME_AGENT_NAME", "MOKUME_AGENT_URL", "MOKUME_AGENT_MODEL",
    "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "AI_AGENT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR",
    "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_HOME",
]
SIGNATURE = "<sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code)</sub>"

# 偽 gh。sub-issue.sh が呼ぶのは 4 つ:
#   gh issue view <親> -R <repo> --json issueType --jq ... → 親の型
#   gh issue create ...                                    → 作成した URL
#   gh api repos/<repo>/issues/<番号> --jq .id             → 子の node id
#   gh api -X POST repos/<repo>/issues/<親>/sub_issues ... → 紐づけ
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"issue view"*)   printf '%s' "$FAKE_PARENT_TYPE" ;;
  *"issue create"*) printf 'https://github.com/mokume-metal/mokume/issues/99\\n' ;;
  # 紐づけを断らせる (#1661)。綴りは既に親を持つ子を繋ごうとしたときの GitHub の応答
  *"api -X POST"*)
    if [ -n "${FAKE_LINK_ERROR:-}" ]; then
      # 本物の gh api と同じく、本文 (errors を含む) は stdout・要約は stderr (#2075)
      printf '%s\\n' "${FAKE_LINK_BODY:-}"
      printf '%s\\n' "$FAKE_LINK_ERROR" >&2; exit 1
    fi
    printf '99\\n' ;;
  *"api "*)         printf '4242\\n' ;;
esac
exit 0
"""


class SubIssueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.log = Path(self.tmp.name) / "gh.log"
        self.log.touch()

    def env(self, parent_type="", link_error="", link_body="", **agent):
        # 検査自体がエージェントのセッションから走るので、署名に効く env は消してから
        # 要るものだけ立てる (既定は人の実行)
        env = {k: v for k, v in os.environ.items() if k not in AGENT_ENV}
        env.update(agent)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_GH_LOG"] = str(self.log)
        env["FAKE_PARENT_TYPE"] = parent_type
        env["FAKE_LINK_ERROR"] = link_error
        env["FAKE_LINK_BODY"] = link_body
        return env

    def run_sub_issue(self, *args, parent_type="", link_error="", link_body="", **agent):
        env = self.env(parent_type, link_error, link_body, **agent)
        proc = subprocess.run(
            ["/bin/bash", str(SCRIPT), "74", *args],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc, self.log.read_text(encoding="utf-8")

    def create_call(self, calls):
        for line in calls.splitlines():
            if line.startswith("issue create"):
                return line
        self.fail(f"issue create が呼ばれていない: {calls}")

    # --- 継承の三態 ---------------------------------------------------------

    def test_parent_type_is_inherited(self):
        proc, calls = self.run_sub_issue("ci: 直す", parent_type="Design")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--type Design", self.create_call(calls))

    def test_explicit_type_wins_over_inheritance(self):
        proc, calls = self.run_sub_issue(
            "ci: 直す", "--type", "Task", parent_type="Design"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        create = self.create_call(calls)
        self.assertIn("--type Task", create)
        self.assertNotIn("Design", create)

    def test_no_type_is_passed_when_parent_has_none(self):
        proc, calls = self.run_sub_issue("ci: 直す")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--type", self.create_call(calls))

    # --- 使い捨ての検証用 Issue ---------------------------------------------

    def test_test_flag_prefixes_the_title_and_marks_it_machine_verified(self):
        proc, calls = self.run_sub_issue("動作を確かめる", "--test")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        create = self.create_call(calls)
        self.assertIn("test: 動作を確かめる", create)
        self.assertIn("--label verify: triaged", create)

    def test_test_flag_does_not_duplicate_an_existing_prefix(self):
        proc, calls = self.run_sub_issue("test: 動作を確かめる", "--test")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("test: test:", self.create_call(calls))

    # --- エージェントの署名 (#3149) ------------------------------------------
    # sub-issue は中の gh で作るので、素の gh issue create を見るフックには見えない。
    # 以前は 11 件中 9 件が無署名で、ready-queue がエージェントの起票と読めなかった

    def test_agent_run_signs_the_body(self):
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "本文", CLAUDECODE="1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f"本文\n\n---\n{SIGNATURE}", calls)

    def test_agent_run_signs_a_body_file_and_an_empty_body(self):
        body = Path(self.tmp.name) / "body.md"
        body.write_text("ファイルの本文\n", encoding="utf-8")
        proc, calls = self.run_sub_issue("ci: 直す", "--body-file", str(body), CLAUDECODE="1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f"ファイルの本文\n\n---\n{SIGNATURE}", calls)
        self.assertNotIn("--body-file", calls, "署名を足す前のファイルを渡している")
        self.log.write_text("", encoding="utf-8")
        proc, calls = self.run_sub_issue("ci: 直す", CLAUDECODE="1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f"--body ---\n{SIGNATURE}", calls)

    def test_human_run_is_not_signed(self):
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "本文")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("Assisted by", calls, "人の実行に署名を付けている")

    def test_codex_home_alone_is_not_an_agent(self):
        """CODEX_HOME は人もシェルの設定で立てる。それだけでは Codex の署名を付けない (反証の #7)。"""
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "本文", CODEX_HOME="/tmp/codex")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("Assisted by", calls)
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "本文", CODEX_SANDBOX="seatbelt")
        self.assertIn("Assisted by [OpenAI Codex]", calls)

    def test_body_from_process_substitution_and_stdin(self):
        """ファイルでない本文の口 (`<(…)`・`-`) も読む (反証の #10)。"""
        proc = subprocess.run(
            ["/bin/bash", "-c", f'bash "{SCRIPT}" 74 "ci: 直す" --body-file <(printf "置換の本文")'],
            capture_output=True, text=True, env=self.env(CLAUDECODE="1"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f"置換の本文\n\n---\n{SIGNATURE}", self.log.read_text(encoding="utf-8"))
        proc = subprocess.run(
            ["/bin/bash", str(SCRIPT), "74", "ci: 直す", "--body-file", "-"],
            input="標準入力の本文", capture_output=True, text=True, env=self.env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--body 標準入力の本文", self.log.read_text(encoding="utf-8"))

    # --- 絵の照合 (#3376) ---------------------------------------------------

    def test_agent_run_refuses_a_drawing_body_without_a_picture(self):
        # #2655・#2647: ここを通る起票はフックに見えず、絵も宣言も無いまま作られた
        for body in ("`Shapes.metal` の塗りが欠ける", "塗りが欠ける\n\n絵: なし — 着手時に撮る"):
            with self.subTest(body):
                self.log.write_text("", encoding="utf-8")
                proc, calls = self.run_sub_issue("fix: 欠ける", "--body", body, CLAUDECODE="1")
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn("drawing-evidence: 差し戻し", proc.stderr)
                self.assertNotIn("issue create", calls)

    def test_agent_run_creates_when_the_body_has_a_picture(self):
        proc, calls = self.run_sub_issue(
            "fix: 欠ける", "--body", "`Shapes.metal` の塗り\n\n![](https://i.gyazo.com/abc.png)", CLAUDECODE="1"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.create_call(calls)

    def test_human_run_is_not_checked_for_pictures(self):
        # 人の起票は雑でよい (AGENTS.md「進め方」1)。絵の要求はエージェントにだけ掛ける
        proc, calls = self.run_sub_issue("fix: 欠ける", "--body", "`Shapes.metal` の塗りが欠ける")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.create_call(calls)

    def test_body_and_body_file_together_is_a_usage_error(self):
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "x", "--body-file", "/dev/null")
        self.assertEqual(proc.returncode, 64, proc.stderr)
        self.assertNotIn("issue create", calls)

    def test_existing_signature_is_not_duplicated(self):
        proc, calls = self.run_sub_issue(
            "ci: 直す", "--body", f"本文\n\n---\n{SIGNATURE}", CLAUDECODE="1"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls.count("Assisted by"), 1)

    def test_other_agents_name_themselves(self):
        proc, calls = self.run_sub_issue(
            "ci: 直す", "--body", "本文", MOKUME_AGENT_NAME="Grok CLI", MOKUME_AGENT_MODEL="grok-5"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("<sub>🤖 Assisted by Grok CLI (grok-5)</sub>", calls)

    def test_with_names_collaborators(self):
        proc, calls = self.run_sub_issue(
            "ci: 直す", "--body", "本文", "--with", "OpenAI Codex (gpt-6-astra)", CLAUDECODE="1"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("(https://claude.com/claude-code) and OpenAI Codex (gpt-6-astra)</sub>", calls)
        self.assertNotIn("--with", calls, "--with を gh へ渡している")

    # --- 紐づけ -------------------------------------------------------------

    def test_child_is_linked_to_the_parent(self):
        proc, calls = self.run_sub_issue("ci: 直す")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("api -X POST repos/mokume-metal/mokume/issues/74/sub_issues", calls)
        self.assertIn("sub_issue_id=4242", calls)

    # --- 既に在る Issue を繋ぐ (#1661) ---------------------------------------
    # 同じ根の群を束ねる相手は、たいてい既に起票されている (ADR-0040 決定 2)

    def test_attach_links_an_existing_issue_without_creating_one(self):
        proc, calls = self.run_sub_issue("--attach", "55", parent_type="Design")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("api repos/mokume-metal/mokume/issues/55 --jq .id", calls)
        self.assertIn("api -X POST repos/mokume-metal/mokume/issues/74/sub_issues", calls)
        self.assertIn("sub_issue_id=4242", calls)
        self.assertNotIn("issue create", calls, "--attach なのに新しく作っている")
        # 型は起票したときに決まっている。親の型を読みに行くこと自体が要らない
        self.assertNotIn("issue view", calls, "--attach で親の型を継ごうとしている")
        self.assertIn("#55 を #74 の下に繋いだ", proc.stdout)

    def test_attach_does_not_reparent_an_issue_that_has_another_parent(self):
        proc, calls = self.run_sub_issue(
            "--attach",
            "55",
            link_error="gh: Validation Failed (HTTP 422)",
            link_body='{"message":"Validation Failed","errors":["Sub issue may only have one parent"]}',
        )
        self.assertNotEqual(proc.returncode, 0, "断られたのに成功を返している")
        self.assertIn("繋げなかった", proc.stderr)
        self.assertIn("付け替えはしない", proc.stderr)
        self.assertIn("only have one parent", proc.stderr, "GitHub の理由を隠している")
        self.assertNotIn("replace_parent", calls, "黙って付け替えようとしている")
        self.assertNotIn("繋いだ", proc.stdout)

    def test_attach_without_a_number_is_a_usage_error(self):
        for args in (("--attach",), ("--attach", "abc"), ("--attach", "55", "--type", "Bug")):
            with self.subTest(args=args):
                proc, calls = self.run_sub_issue(*args)
                self.assertEqual(proc.returncode, 64, proc.stderr)
                self.assertIn("--attach <番号>", proc.stderr)
                self.assertNotIn("api ", calls, "使い方の誤りなのに GitHub を叩いている")

    def test_dash_leading_positional_is_a_usage_error_without_calling_gh(self):
        # 慣習の `--help` を題や親番号として読むと、「--help」という題の Issue が立つ (#3047)
        cases = (
            ("題が選択肢の綴り", ("74", "--help")),
            ("題が -h", ("74", "-h")),
            ("題が - 単独", ("74", "-")),
            ("親番号が選択肢の綴り", ("--help", "ci: 直す")),
        )
        for label, args in cases:
            with self.subTest(label):
                self.log.write_text("", encoding="utf-8")
                proc = subprocess.run(
                    ["/bin/bash", str(SCRIPT), *args],
                    capture_output=True, text=True, env=self.env(),
                )
                self.assertEqual(proc.returncode, 64, proc.stderr)
                self.assertIn("使い方: sub-issue.sh", proc.stderr)
                self.assertEqual(self.log.read_text(encoding="utf-8"), "", "gh が呼ばれてはならない")

    def test_dash_leading_option_value_is_still_accepted(self):
        # `--body` の箇条書き `- …` は正当な値。位置引数だけを見る
        proc, calls = self.run_sub_issue("ci: 直す", "--body", "- 箇条書き")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("issue create", calls)


if __name__ == "__main__":
    unittest.main()
