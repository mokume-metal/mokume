#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/runner-preflight.sh — 専用機の job の最初に、検査を走らせられる環境かを見る (#2588)。

守るのは 5 つ。

1. **表の GUI セッション・画面・Metal のどれかが欠けたら赤で終え、欠けたものを名乗る。**
   #2507 では表のセッションが替わって画面が 0 枚に見え、make が 14 分走ってから落ちた
2. **当たったものは全部名乗る。** 1 つ目で止めると、直す人が専用機の前に何度も立つ
3. **読めない (osascript が落ちる・数でない) も赤にする。** 黙って通すと 14 分の赤に戻る
5. **gpu-slot の期限切れの記録 (`wait-expired.json`) が残っていれば赤にして名乗る** (#2235)。専用機では
   置き場が runner に固定され、記録は job をまたいで残る。残ったままだと、以後の検査は 76 で止まり続け、
   PR の赤と見分けられない。reason は既存の発信 (render-environment-report) がそのまま運ぶ
4. **落ちたら `$GITHUB_OUTPUT` に `reason=` を 1 行で書く。** render-environment-report は
   これが空でない回にだけ発信する。通ったら書かない (書けば PR の赤まで故障として起票される)

偽の stat・id・osascript は PATH の先頭に置いた同名のスタブ。本物の専用機は触らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "runner-preflight.sh"

FAKE_STAT = """#!/bin/sh
[ -n "$FAKE_CONSOLE" ] || exit 1
echo "$FAKE_CONSOLE"
"""

FAKE_ID = """#!/bin/sh
echo "$FAKE_USER"
"""

# 画面の枚数を問う式には FAKE_SCREENS を、Metal を問う式には FAKE_METAL を返す。
# FAKE_OSASCRIPT_FAIL が立っていれば落ちる
FAKE_OSASCRIPT = """#!/bin/sh
[ -z "$FAKE_OSASCRIPT_FAIL" ] || exit 1
case "$*" in
  *NSScreen*) printf '%s\\n' "$FAKE_SCREENS" ;;
  *Metal*) printf '%s\\n' "$FAKE_METAL" ;;
  *) exit 1 ;;
esac
"""

HEALTHY = {
    "FAKE_CONSOLE": "runner",
    "FAKE_USER": "runner",
    "FAKE_SCREENS": "1",
    "FAKE_METAL": "Apple M4",
}


class RunnerPreflightTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("stat", FAKE_STAT), ("id", FAKE_ID), ("osascript", FAKE_OSASCRIPT)):
            path = self.bin / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        self.output = self.root / "output"
        self.summary = self.root / "summary"
        self.slots = self.root / "slots"
        self.record = self.slots / "wait-expired.json"

    def run_preflight(self, **overrides):
        env = {k: v for k, v in os.environ.items() if not k.startswith("FAKE_")}
        env.update(HEALTHY)
        env.update(overrides)
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        env["GITHUB_OUTPUT"] = str(self.output)
        env["GITHUB_STEP_SUMMARY"] = str(self.summary)
        # 本物の機械の gpu-slot の置き場 (HOME の下) の記録を読まない。置き場は検査ごとの一時ディレクトリ
        env["MOKUME_GPU_SLOT_DIR"] = str(self.slots)
        return subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)

    def reason(self):
        if not self.output.exists():
            return None
        lines = [ln for ln in self.output.read_text(encoding="utf-8").splitlines() if ln.startswith("reason=")]
        self.assertEqual(len(lines), 1, lines)
        return lines[0].removeprefix("reason=")

    def test_揃っていれば緑で_reason_を書かない(self):
        r = self.run_preflight()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("検査を走らせられる", r.stdout)
        self.assertNotIn("::error", r.stdout)
        self.assertIsNone(self.reason())

    def test_表のセッションが別のユーザーなら赤で名乗る(self):
        # #2507 の形: 表は so、job は runner
        r = self.run_preflight(FAKE_CONSOLE="so")
        self.assertEqual(r.returncode, 1)
        self.assertIn("::error title=専用機の環境::console: 表の GUI セッションが so で、job のユーザー (runner) ではない", r.stdout)
        self.assertIn("console:", self.reason())
        self.assertIn("runner のユーザーに戻す", self.summary.read_text(encoding="utf-8"))

    def test_表のセッションを読めなければ赤(self):
        r = self.run_preflight(FAKE_CONSOLE="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("console: /dev/console の持ち主を読めない", self.reason())

    def test_画面が_0_枚なら赤(self):
        r = self.run_preflight(FAKE_SCREENS="0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("screens: job のユーザーから見える画面が 0 枚", self.reason())

    def test_画面の枚数が数でなければ赤(self):
        r = self.run_preflight(FAKE_SCREENS="error")
        self.assertEqual(r.returncode, 1)
        self.assertIn("screens: job のユーザーから画面の枚数を読めない (error)", self.reason())

    def test_Metal_のデバイスが取れなければ赤(self):
        r = self.run_preflight(FAKE_METAL="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("metal: Metal の既定のデバイスが取れない", self.reason())

    def test_osascript_が落ちれば画面も_Metal_も赤(self):
        r = self.run_preflight(FAKE_OSASCRIPT_FAIL="1")
        self.assertEqual(r.returncode, 1)
        reason = self.reason()
        self.assertIn("screens:", reason)
        self.assertIn("metal:", reason)

    def test_当たったものは全部名乗り_reason_は_1_行に畳む(self):
        r = self.run_preflight(FAKE_CONSOLE="so", FAKE_SCREENS="0", FAKE_METAL="")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.count("::error"), 3, r.stdout)
        reason = self.reason()
        self.assertEqual(reason.count(" / "), 2, reason)
        summary = self.summary.read_text(encoding="utf-8")
        for key in ("console:", "screens:", "metal:"):
            self.assertIn(key, summary)

    def test_gpu_slot_の期限切れの記録が残っていれば赤で名乗り_消すのは人だと言う(self):
        # 専用機では置き場が runner に固定されて job をまたぐので、記録が残ると以後の検査は 76 で止まり続ける (#2235)
        self.slots.mkdir()
        self.record.write_text("{}", encoding="utf-8")
        r = self.run_preflight()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("::error title=専用機の環境::gpu-slot:", r.stdout)
        self.assertIn(str(self.record), r.stdout)
        reason = self.reason()
        self.assertIn("gpu-slot:", reason)
        self.assertNotIn("\n", reason)
        summary = self.summary.read_text(encoding="utf-8")
        self.assertIn(str(self.record), summary)
        self.assertIn("確かめてから", summary)
        # 表のセッションの直し方 (#2507) は、環境が壊れていないのに言わない
        self.assertNotIn("runner のユーザーに戻す", summary)

    def test_記録が無ければ_gpu_slot_は名乗らない(self):
        self.slots.mkdir()
        r = self.run_preflight()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("gpu-slot", r.stdout)
        self.assertIsNone(self.reason())

    def test_記録と表のセッションの両方が当たれば_両方を名乗る(self):
        self.slots.mkdir()
        self.record.write_text("{}", encoding="utf-8")
        r = self.run_preflight(FAKE_CONSOLE="so")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.count("::error"), 2, r.stdout)
        reason = self.reason()
        self.assertIn("console:", reason)
        self.assertIn("gpu-slot:", reason)
        summary = self.summary.read_text(encoding="utf-8")
        self.assertIn("runner のユーザーに戻す", summary)
        self.assertIn("確かめてから", summary)


if __name__ == "__main__":
    unittest.main()
