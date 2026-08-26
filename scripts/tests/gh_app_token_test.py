#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/gh-app-token.sh の検査 (#49)。

守りたいのは 5 つ (Issue #49 / #71 の完了条件):
  1. 設定が足りないとき、何を設定すればよいかを示して落ちる
  2. 組み立てる JWT が GitHub の App 認証の形 (RS256・iss が App ID・exp は 10 分以内)
  3. 応答から token だけを標準出力に出す
  4. **どの経路でも秘密鍵の内容を出力しない**
  5. ID 2 つが未設定でも org から引いて発行できる。引けなければ手で引く手順を出す (#71)

鍵は使い捨てを生成し、HTTP は偽の gh に差し替えるので、ネットワークも App も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import base64
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "gh-app-token.sh"

# 引数から --jq のクエリを拾って応答に適用する最小の gh。呼ばれた引数と、渡された
# JWT (GH_TOKEN) を 1 呼び出しにつき 2 行、追記で記録して、テスト側が中身を検証できる
# ようにする (#71 の自動解決では gh が複数回呼ばれる)。応答は呼ばれ方で切り替える
FAKE_GH = """#!/bin/sh
query=.
prev=
for arg in "$@"; do
  [ "$prev" = "--jq" ] && query=$arg
  prev=$arg
done
{ printf '%s\\n' "$*"; printf 'JWT=%s\\n' "$GH_TOKEN"; } >> "$GH_STUB_LOG"
case "$*" in
  *"repo view"*)
    printf '%s' "${GH_STUB_OWNER:-{}}" | jq -r "$query"
    exit 0 ;;
  *orgs/*installations*)
    [ "${GH_STUB_RESOLVE_FAIL:-0}" = "1" ] && { echo "HTTP 403: read:org が要る" >&2; exit 1; }
    printf '%s' "${GH_STUB_INSTALLATIONS:-}" | jq -r "$query"
    exit 0 ;;
esac
[ "${GH_STUB_FAIL:-0}" = "1" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
printf '%s' "${GH_STUB_RESPONSE}" | jq -r "$query"
"""

APP_ID = "123456"
INSTALLATION_ID = "78901234"
TOKEN = "ghs_stubtoken0123456789"

# org から引ける値 (環境変数で明示した値とは別物にして、どちらが使われたかを見分ける)
OWNER = "stub-org"
RESOLVED_APP_ID = "654321"
RESOLVED_INSTALLATION_ID = "43210987"


def b64url_decode(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class GhAppTokenTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)

        self.bindir = d / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.log = d / "gh.log"

        # 使い捨ての鍵。本物の App の鍵は要らない (署名できることだけが要件)
        self.key = d / "key.pem"
        subprocess.run(
            ["openssl", "genrsa", "-out", str(self.key), "2048"],
            check=True,
            capture_output=True,
        )
        body = [
            line
            for line in self.key.read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("-----")
        ]
        # 出力に鍵が混ざっていないかを見るための目印。PEM の途中の 1 行で十分
        self.key_marker = body[len(body) // 2]

    def env(self, **overrides):
        env = {k: v for k, v in os.environ.items() if not k.startswith("MOKUME_APP_")}
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["GH_STUB_LOG"] = str(self.log)
        env["GH_STUB_RESPONSE"] = json.dumps({"token": TOKEN, "expires_at": "2026-08-26T09:00:00Z"})
        env["GH_STUB_OWNER"] = json.dumps({"owner": {"login": OWNER}})
        # installations の応答は既定では置かない — 何も設定していない環境を再現する
        env.update(overrides)
        return env

    def installations(self, *entries):
        """orgs/<org>/installations の応答 (既定はこのリポジトリの App が 1 つだけ)"""
        entries = entries or ((RESOLVED_APP_ID, RESOLVED_INSTALLATION_ID, "mokume-agent"),)
        return json.dumps(
            {
                "installations": [
                    {"app_id": int(app_id), "id": int(inst_id), "app_slug": slug}
                    for app_id, inst_id, slug in entries
                ]
            }
        )

    def gh_calls(self):
        lines = self.log.read_text(encoding="utf-8").splitlines()
        return [l for l in lines if not l.startswith("JWT=")]

    def run_script(self, **env):
        return subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, env=self.env(**env)
        )

    def configured(self, **overrides):
        env = {
            "MOKUME_APP_ID": APP_ID,
            "MOKUME_APP_INSTALLATION_ID": INSTALLATION_ID,
            "MOKUME_APP_PRIVATE_KEY": self.key.read_text(encoding="utf-8"),
        }
        env.update(overrides)
        return env

    def jwt_parts(self):
        line = [
            l for l in self.log.read_text(encoding="utf-8").splitlines() if l.startswith("JWT=")
        ][-1]
        return line[len("JWT=") :].split(".")

    # --- 1. 設定不足 --------------------------------------------------------

    def test_missing_config_names_what_to_set(self):
        proc = self.run_script()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("MOKUME_APP_ID", proc.stderr)
        self.assertIn("次にすること", proc.stderr)

    def test_missing_key_alone_is_reported(self):
        proc = self.run_script(
            MOKUME_APP_ID=APP_ID, MOKUME_APP_INSTALLATION_ID=INSTALLATION_ID
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("MOKUME_APP_PRIVATE_KEY", proc.stderr)

    # --- 2. JWT の形 --------------------------------------------------------

    def test_jwt_has_the_shape_github_requires(self):
        before = int(time.time())
        proc = self.run_script(**self.configured())
        self.assertEqual(proc.returncode, 0, proc.stderr)

        parts = self.jwt_parts()
        self.assertEqual(len(parts), 3, "JWT は header.payload.signature の 3 パート")

        header = json.loads(b64url_decode(parts[0]))
        self.assertEqual(header["alg"], "RS256")
        self.assertEqual(header["typ"], "JWT")

        payload = json.loads(b64url_decode(parts[1]))
        self.assertEqual(payload["iss"], APP_ID)
        # exp は GitHub の上限 10 分以内。超えると発行そのものが弾かれる
        self.assertLessEqual(payload["exp"] - payload["iat"], 600)
        # iat は過去でなければならない (少しでも未来だと弾かれる)
        self.assertLessEqual(payload["iat"], before)

    def test_signature_is_not_empty(self):
        self.run_script(**self.configured())
        self.assertTrue(self.jwt_parts()[2])

    # --- 3. token の取り出し ------------------------------------------------

    def test_prints_only_the_token(self):
        proc = self.run_script(**self.configured())
        self.assertEqual(proc.stdout.strip(), TOKEN)
        self.assertNotIn("expires_at", proc.stdout)

    def test_calls_the_installation_endpoint(self):
        self.run_script(**self.configured())
        called = self.log.read_text(encoding="utf-8").splitlines()[0]
        self.assertIn(f"app/installations/{INSTALLATION_ID}/access_tokens", called)
        self.assertIn("POST", called)

    def test_sends_the_jwt_as_bearer(self):
        # gh は GH_TOKEN を "token <値>" として送るため、JWT をそのまま渡すと
        # GitHub が復号できず 401 になる (#53)。Bearer での送出を固定する
        self.run_script(**self.configured())
        called = self.log.read_text(encoding="utf-8").splitlines()[0]
        self.assertIn("Authorization: Bearer", called)

    def test_api_failure_is_reported_with_next_step(self):
        proc = self.run_script(**self.configured(), GH_STUB_FAIL="1")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("次にすること", proc.stderr)

    # --- 4. 鍵が漏れない ----------------------------------------------------

    def test_private_key_never_reaches_the_output(self):
        proc = self.run_script(**self.configured())
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)

    def test_private_key_stays_hidden_when_the_api_fails(self):
        proc = self.run_script(**self.configured(), GH_STUB_FAIL="1")
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)

    # --- 壊れた鍵を名指しで拒む (#57) --------------------------------------
    # 保管先が値を壊す事故は実際に起きた (1678 バイトの鍵が 87 バイトに切り詰められた)。
    # openssl に渡すと一般的な暗号エラーになり、原因から最も遠い形で出る

    def test_rejects_a_value_that_is_not_a_pem(self):
        proc = self.run_script(**self.configured(MOKUME_APP_PRIVATE_KEY="ただの文字列"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("PEM ではない", proc.stderr)

    def test_rejects_a_truncated_pem(self):
        head = self.key.read_text(encoding="utf-8").splitlines()[0]
        proc = self.run_script(**self.configured(MOKUME_APP_PRIVATE_KEY=head))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("途中で切れている", proc.stderr)

    def test_rejects_a_pem_flattened_into_one_line(self):
        flat = self.key.read_text(encoding="utf-8").replace("\n", " ")
        proc = self.run_script(**self.configured(MOKUME_APP_PRIVATE_KEY=flat))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("改行が無い", proc.stderr)

    def test_broken_key_messages_do_not_leak_the_key(self):
        flat = self.key.read_text(encoding="utf-8").replace("\n", " ")
        proc = self.run_script(**self.configured(MOKUME_APP_PRIVATE_KEY=flat))
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)

    def test_private_key_stays_hidden_when_signing_fails(self):
        proc = self.run_script(**self.configured(MOKUME_APP_PRIVATE_KEY="鍵ではない文字列"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("鍵ではない文字列", proc.stdout + proc.stderr)

    # --- 間接参照 -----------------------------------------------------------

    def test_key_can_come_from_a_command(self):
        proc = self.run_script(
            MOKUME_APP_ID=APP_ID,
            MOKUME_APP_INSTALLATION_ID=INSTALLATION_ID,
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key}",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), TOKEN)
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)

    def test_failing_key_command_is_reported_without_leaking(self):
        proc = self.run_script(
            MOKUME_APP_ID=APP_ID,
            MOKUME_APP_INSTALLATION_ID=INSTALLATION_ID,
            # 秘密管理ツールが鍵を stderr へ出しても、こちらの出力には混ぜない
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key} >&2; exit 1",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("次にすること", proc.stderr)
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)

    # --- 5. ID を org から引く (#71) ----------------------------------------
    # 新しいセッション・新しい worktree には MOKUME_APP_* が渡っていない。ID 2 つは
    # 秘密ではない識別子なので、手で揃える設定を鍵 1 つに縮める

    def test_ids_are_resolved_from_the_org_when_unset(self):
        proc = self.run_script(
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key}",
            GH_STUB_INSTALLATIONS=self.installations(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), TOKEN)

        payload = json.loads(b64url_decode(self.jwt_parts()[1]))
        self.assertEqual(payload["iss"], RESOLVED_APP_ID)

        calls = self.gh_calls()
        self.assertTrue(any(f"orgs/{OWNER}/installations" in c for c in calls), calls)
        self.assertIn(
            f"app/installations/{RESOLVED_INSTALLATION_ID}/access_tokens", calls[-1]
        )

    def test_resolution_never_overrides_an_explicit_id(self):
        proc = self.run_script(
            **self.configured(), GH_STUB_INSTALLATIONS=self.installations()
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(b64url_decode(self.jwt_parts()[1]))
        self.assertEqual(payload["iss"], APP_ID)

    def test_explicit_ids_skip_the_resolution_call(self):
        # 解決には org を読める認証が要る。要らない場面で要求しない
        self.run_script(**self.configured(), GH_STUB_INSTALLATIONS=self.installations())
        self.assertFalse([c for c in self.gh_calls() if "installations?" in c or "orgs/" in c])

    def test_ambiguous_installations_are_not_guessed(self):
        # 別 App が同じ org に入っていても、slug が一致するものだけを見る
        proc = self.run_script(
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key}",
            GH_STUB_INSTALLATIONS=self.installations(
                (RESOLVED_APP_ID, RESOLVED_INSTALLATION_ID, "mokume-agent"),
                ("999999", "99999999", "some-other-app"),
            ),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(b64url_decode(self.jwt_parts()[1]))
        self.assertEqual(payload["iss"], RESOLVED_APP_ID)

    def test_resolution_failure_names_the_manual_command(self):
        # #71 の完了条件そのもの — 出力だけを読んで次の一手に辿り着けること
        proc = self.run_script(
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key}", GH_STUB_RESOLVE_FAIL="1"
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("MOKUME_APP_ID", proc.stderr)
        self.assertIn("次にすること", proc.stderr)
        self.assertIn(f"gh api orgs/{OWNER}/installations", proc.stderr)
        self.assertIn("--jq", proc.stderr)
        self.assertIn("read:org", proc.stderr)

    def test_resolution_failure_does_not_leak_the_key(self):
        proc = self.run_script(
            MOKUME_APP_PRIVATE_KEY_CMD=f"cat {self.key}", GH_STUB_RESOLVE_FAIL="1"
        )
        self.assertNotIn(self.key_marker, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
