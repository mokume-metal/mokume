#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/secret-scan.sh の検査 (#819)。

以前この探索は `plan-record.sh` の CLI 口の 1 つで、検査も `plan_record_test.py`
(リポジトリ最大) の中にしか無かった。**プランに固有の機構ではない** — 問うているのは
「この本文を GitHub へ出してよいか」で、プランかどうかとは関係がない。

固定するのは 3 つ:

1. **2 段の別** — BLOCK (投稿用ファイルを作らせない) と WARN (判断を委ねる)
2. **中身を出さないこと** — 秘密情報を出力へ再掲したら守った意味が無い。場所だけを伝える
3. **伏せ字を拾わないこと** — `$VAR` / `<your-token>` / 「token は環境変数で渡す」のような
   説明文まで止めると、判断が信用されなくなって機構ごと迂回される

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "secret-scan.sh"

# 検査用の値。**本物ではない**が、形は本物と同じでなければ検出を測れない
FAKE_GH_TOKEN = "ghp_" + "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
FAKE_AWS_KEY = "AKIA" + "IOSFODNN7EXAMPLE"
FAKE_SLACK = "xoxb-" + "1234567890-abcdefghij"
FAKE_ANTHROPIC = "sk-ant-" + "api03-abcdefghijklmnop"


def scan(body):
    """ライブラリを source した bash に検めさせ、出力を返す。"""
    proc = subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\nsecret_scan "$1"', "_", body],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def kinds(out):
    return [line.split("\t")[0] for line in out.splitlines() if line]


class BlockTest(unittest.TestCase):
    """止める側 — 見つかったら投稿用ファイルを作らせない。"""

    def test_the_shapes_that_block(self):
        for label, body in (
            ("GitHub のトークン", f"export GITHUB_TOKEN={FAKE_GH_TOKEN}"),
            ("AWS のアクセスキー", f"key = {FAKE_AWS_KEY}"),
            ("Slack のトークン", f"slack: {FAKE_SLACK}"),
            ("API キー", f"ANTHROPIC_API_KEY={FAKE_ANTHROPIC}"),
            ("秘密鍵", "-----BEGIN OPENSSH PRIVATE KEY-----"),
        ):
            with self.subTest(label):
                out = scan(body + "\n")
                self.assertIn("BLOCK", kinds(out), out)

    def test_a_masked_value_is_not_a_secret(self):
        """**伏せ字は拾わない。** 拾うと機構ごと迂回される。"""
        body = (
            "token は環境変数で渡す (値は書かない)\n"
            "参照は $API_KEY と <your-token> のまま\n"
            "password: ****\n"
        )
        self.assertEqual(scan(body), "", scan(body))

    def test_only_the_offending_line_is_named(self):
        body = f"1 行目は普通\nexport GITHUB_TOKEN={FAKE_GH_TOKEN}\n3 行目も普通\n"
        out = scan(body)
        self.assertIn("行 2", out)
        self.assertNotIn("行 1", out)
        self.assertNotIn("行 3", out)

    def test_the_value_itself_never_appears(self):
        """**中身は出さない。** 再掲したら守った意味が無い。"""
        out = scan(f"export GITHUB_TOKEN={FAKE_GH_TOKEN}\n")
        self.assertNotIn(FAKE_GH_TOKEN, out)
        self.assertIn("行", out)

    def test_case_does_not_matter(self):
        """`GITHUB_TOKEN=` のような綴りを取りこぼさない。"""
        self.assertIn("BLOCK", kinds(scan(f"SECRET_TOKEN={FAKE_GH_TOKEN}\n")))


class WarnTest(unittest.TestCase):
    """止めない側 — 判断はエージェントへ委ねる。"""

    def test_the_shapes_that_warn(self):
        for label, body in (
            ("メールアドレス", "連絡は alice@example.com"),
            ("1Password の参照", "参照は op://Vault/item/credential"),
            ("絶対パス", "手元では /Users/someone/work に置いた"),
            ("ローカルのポート", "localhost:8080 で見られる"),
        ):
            with self.subTest(label):
                out = scan(body + "\n")
                self.assertEqual(kinds(out), ["WARN"], out)

    def test_a_warning_does_not_block(self):
        out = scan("連絡は alice@example.com。参照は op://Vault/item/credential\n")
        self.assertIn("WARN", kinds(out))
        self.assertNotIn("BLOCK", kinds(out))

    def test_the_github_noreply_address_is_not_personal(self):
        """GitHub が公開用に配るアドレスなので、伏せる意味が無い。

        **署名の 1 行がこれに当たる** — 拾うと、規約どおりに署名したコメントが毎回
        警告される。
        """
        self.assertEqual(scan("Assisted-by: Claude <noreply@anthropic.com>\n"), "")


class ContractTest(unittest.TestCase):
    def test_an_empty_body_finds_nothing(self):
        """パイプの途中で使われるので、空でも止めない。"""
        self.assertEqual(scan(""), "")

    def test_plain_prose_finds_nothing(self):
        body = "## 目的\n\n共有ライブラリが共有していない部分を畳む。\n\nCloses #815\n"
        self.assertEqual(scan(body), "", scan(body))

    def test_the_output_is_tab_separated_with_three_fields(self):
        """読む側 (`cut -f2,3`) が数えている形である。"""
        out = scan(f"export GITHUB_TOKEN={FAKE_GH_TOKEN}\n")
        for line in out.splitlines():
            self.assertEqual(len(line.split("\t")), 3, line)


class WiringTest(unittest.TestCase):
    """書いただけで読み手から使われていなければ効かない。"""

    def test_the_plan_record_hook_goes_through_it(self):
        text = (REPO / "scripts" / "plan-record.sh").read_text(encoding="utf-8")
        self.assertIn("secret-scan.sh", text, "plan-record.sh が共有の探索を読んでいない")
        self.assertIn("secret_scan ", text, "plan-record.sh が探索を呼んでいない")

    def test_the_hook_keeps_no_copy(self):
        """複製が残っていると、片方だけ直す事故が起きる。"""
        text = (REPO / "scripts" / "plan-record.sh").read_text(encoding="utf-8")
        self.assertNotIn("AKIA[0-9A-Z]", text, "plan-record.sh にパターンの写しが残っている")

    def test_the_posting_wrapper_is_not_wired(self):
        """**投稿の口には配線しない** — 新しいゲートは実害の提示が要る (ADR-0008)。

        配線したくなったら、実害を Issue 番号で示してからにする。この検査は「まだ
        配線していない」ことの記録であって、配線を禁じるものではない。
        """
        text = (REPO / "scripts" / "comment.sh").read_text(encoding="utf-8")
        self.assertNotIn("secret-scan.sh", text)


if __name__ == "__main__":
    unittest.main()
