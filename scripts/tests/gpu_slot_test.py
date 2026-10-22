#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`scripts/gpu-slot.py` — GPU の検査を、機械全体で共有する枠を取ってから走らせる包みの検査 (#1898)。

守るのは 7 つ。
- 枠の数より多くは同時に走らない
- 持ち主が殺されれば、枠が返る
- 待つ側が期限を持つ
- 子の終了コードをそのまま返す
- 起動元 (親プロセスの連鎖・エージェントの出所) を、再起動で消えない記録に残す (#2059)
- 窓つきの計測 (`--exclusive`) は、GPU の検査と同時に走らない (#2052)
- GPU の待ちが期限を越えた記録があれば、次の検査・計測は名乗って始めずに止まる (#2235)

Swift も GPU も要らない。子には、合図のファイルを待つだけの小さな Python を走らせる。
置き場は検査ごとの一時ディレクトリで、本物の枠 (`~/Library/Caches/mokume/gpu-slots`) にも
本物の記録 (`~/Library/Logs/mokume/gpu-slot.jsonl`) にも触らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import fcntl
import importlib.util
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "gpu-slot.py"

# 子: 始まったら started を作り、release が現れるまで待って、与えた終了コードで抜ける
CHILD = (
    "import sys, time, pathlib\n"
    "started, release, code = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])\n"
    "started.touch()\n"
    "while not release.exists():\n"
    "    time.sleep(0.02)\n"
    "sys.exit(code)\n"
)


def _wait_for(predicate, seconds=10.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def _holder_mark(pid):
    """持ち主の行の中の pid の書き方 (`gpu-slot.py` の `_holders`・`_gate_holder` の `pid {pid} · `)。

    右に境界を付けて照合する。`pid 123` だけだと、`pid 1234` を名乗っても当たる。"""
    return f"pid {pid} · "


def _names_after(text, marker, pid):
    """`marker` を含む名乗りの行の直後 (次の `gpu-slot:` の行まで) に、`pid` の持ち主の行があるか。

    待つ間の名乗りも期限で抜ける文面も、続けて持ち主の行を出す。stderr 全体で pid を探すと、片方の
    持ち主の行で、もう片方が名乗ったことまで満たされる (#2343)。"""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if marker not in line:
            continue
        for following in lines[index + 1:]:
            if following.startswith("gpu-slot:"):
                break
            if _holder_mark(pid) in following:
                return True
    return False


class _Said:
    """包みの stderr を、塞がずに読み足して貯める。待つ側が待ちに入ったかを、名乗りで見るための補助 (#2304)。

    「子を起こして 0.5 秒眠ってから、まだ走っていないことを確かめる」と、子の起動が 0.5 秒を越える
    機械では、まだ枠の入口にも着いていない子に「走っていない」を確かめて素通りする。待つ側は待つ間に
    相手を名乗る (検査では 0.1 秒ごと) ので、名乗りが出るのを期限つきで待てば、待ちに入ったことが
    分かる。固定の眠りで順序を作らない。

    読み足すのは、読める分だけ (`select` が読めると言ったときだけ `os.read` する) なので、塞がない。
    読んだ分は `communicate` の返りには戻らない。その包みの出力を表明するなら、`communicate` ではなく
    `finish` (貯めた分に `communicate` の残りをつないで返す) を使う。"""

    def __init__(self, process):
        self._process = process
        self._chunks = []

    def text(self):
        descriptor = self._process.stderr.fileno()
        while select.select([descriptor], [], [], 0)[0]:
            data = os.read(descriptor, 65536)
            if not data:  # 閉じた
                break
            self._chunks.append(data)
        return b"".join(self._chunks).decode("utf-8", errors="replace")

    def has(self, marker):
        return marker in self.text()

    def count(self, marker):
        return self.text().count(marker)

    def finish(self, timeout=10):
        head = self.text()
        _, rest = self._process.communicate(timeout=timeout)
        return head + rest


class SlotHarness(unittest.TestCase):
    """検査ごとの一時ディレクトリに枠と記録を置き、偽の子を包みに通して走らせる下回り。検査は持たない。"""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.slots = self.root / "slots"
        self.log = self.root / "log" / "gpu-slot.jsonl"
        self.running = []

    def tearDown(self):
        # 先に合図を置いて子を終わらせる。包みを SIGKILL すると子が取り残され、パイプを握った
        # まま残る (持ち主を殺す検査はわざとそうするので、ここで終わらせる)
        for name in {path.stem for path in self.root.glob("*.started")}:
            (self.root / f"{name}.release").touch()
        for process in self.running:
            if process.poll() is None:
                process.terminate()  # 包みは SIGTERM を子へ渡す
        for process in self.running:
            process.communicate(timeout=10)
        self.temporary.cleanup()

    def _environment(self, slots="2", wait="30", extra=None):
        environment = dict(os.environ)
        environment.update(
            {
                "MOKUME_GPU_SLOT_DIR": str(self.slots),
                "MOKUME_GPU_SLOT_LOG": str(self.log),
                "MOKUME_GPU_SLOTS": slots,
                "MOKUME_GPU_SLOT_WAIT": wait,
                "MOKUME_GPU_SLOT_POLL": "0.02",
                "MOKUME_GPU_SLOT_REPORT": "0.1",
            }
        )
        environment.update(extra or {})
        # 検査そのものが計測の内側 (--exclusive の子) で走っていても、包みに枠を取らせる
        if "MOKUME_GPU_SLOT_EXCLUSIVE" not in (extra or {}):
            environment.pop("MOKUME_GPU_SLOT_EXCLUSIVE", None)
        return environment

    def _start(self, name, code=0, exclusive=False, **options):
        """包みを通して子を走らせる。子が始まった印と、子を終わらせる合図のファイルを返す。

        `exclusive` は窓つきの計測の口 (`--exclusive`) を通す。"""
        started = self.root / f"{name}.started"
        release = self.root / f"{name}.release"
        mode = ["--exclusive"] if exclusive else []
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), *mode, "--", sys.executable, "-c", CHILD, str(started), str(release), str(code)],
            env=self._environment(**options),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.running.append(process)
        return process, started, release

    def _entries(self):
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    # 待ちに入ってから、これだけ名乗りを重ねる間 (検査では 0.1 秒ごとなので 0.4 秒以上) 走らないのを見届ける。
    # 最初の名乗りだけで「走っていない」を確かめると、待ち始めてしばらくして走り出す退行を見逃す
    WAITING_ROUNDS = 5

    def _assert_waiting(self, said, started, marker, ran):
        """待つ側が待ちに入って名乗り (`marker`)、その後も走らずに名乗り続けるのを、期限つきで見届ける。

        名乗りを待たずに「走っていない」だけを見ると、起動が遅くて、まだ待ちに入っていない子でも通る (#2304)。"""
        _wait_for(lambda: said.count(marker) >= self.WAITING_ROUNDS or started.exists())
        self.assertFalse(started.exists(), ran)
        self.assertGreaterEqual(
            said.count(marker), self.WAITING_ROUNDS, f"待ちに入った旨 ({marker}) を {self.WAITING_ROUNDS} 回名乗らない"
        )


class GpuSlotTest(SlotHarness):
    def test_no_more_than_the_slot_count_run_at_once(self):
        first, first_started, first_release = self._start("first")
        second, second_started, _ = self._start("second")
        self.assertTrue(_wait_for(first_started.exists), "1 本目が走らない")
        self.assertTrue(_wait_for(second_started.exists), "2 本目が走らない")
        third, third_started, _ = self._start("third")
        self._assert_waiting(_Said(third), third_started, "空くのを待っている", "枠 2 なのに 3 本目が走った")
        first_release.touch()
        self.assertEqual(first.wait(timeout=10), 0)
        self.assertTrue(_wait_for(third_started.exists), "枠が空いても 3 本目が走らない")

    def test_waiting_side_names_the_holders(self):
        # 待つ側の期限は既定 (30 秒) のまま、待っている間の名乗りを見て、見届けたら止める (#2343)。
        # 期限を短くして終わりを待つと、待つ側が名乗る周回の前に止まった回は、期限で抜ける文面だけに
        # なって落ちる。期限で抜ける文面 (`_give_up`) も持ち主を名乗るので、持ち主の行は「空くのを
        # 待っている」の名乗りの直後に探す。期限で抜ける側の文面は
        # test_the_waiting_side_gives_up_at_its_deadline が見る
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, _, _ = self._start("waiter", slots="1")
        said = _Said(waiter)
        named = _wait_for(lambda: _names_after(said.text(), "空くのを待っている", holder.pid))
        waiter.terminate()
        tail = "\n".join(said.text().splitlines()[-6:])
        self.assertTrue(named, f"待つ間の名乗りに持ち主 (pid {holder.pid}) が載らない。stderr の末尾:\n{tail}")

    def test_a_killed_holder_gives_its_slot_back(self):
        holder, holder_started, holder_release = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, waiter_started, _ = self._start("waiter", slots="1")
        self._assert_waiting(_Said(waiter), waiter_started, "空くのを待っている", "枠 1 なのに 2 本目が走った")
        holder.send_signal(signal.SIGKILL)
        holder.wait(timeout=10)
        self.assertTrue(_wait_for(waiter_started.exists), "持ち主が殺されても枠が返らない")
        holder_release.touch()  # 取り残された子を終わらせる

    def test_the_waiting_side_gives_up_at_its_deadline(self):
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, waiter_started, _ = self._start("waiter", slots="1", wait="0.3")
        _, error = waiter.communicate(timeout=10)
        self.assertEqual(waiter.returncode, 75)
        self.assertFalse(waiter_started.exists(), "期限で抜けたのに子を走らせた")
        self.assertIn("空かなかった", error)
        # 持ち主は、期限で抜ける文面の後ろに探す。待つ間の名乗り (0.1 秒・0.2 秒) も同じ持ち主を名乗るので、
        # stderr 全体で探すと、期限で抜ける側が持ち主を名乗らなくても満たされる (#2343)
        self.assertTrue(_names_after(error, "空かなかったので", holder.pid), error)

    def test_the_child_exit_code_is_returned(self):
        for code in (0, 1, 3):
            with self.subTest(code=code):
                process, started, release = self._start(f"code{code}", code=code)
                self.assertTrue(_wait_for(started.exists))
                release.touch()
                self.assertEqual(process.wait(timeout=10), code)

    def test_a_bad_slot_count_is_refused(self):
        for value in ("0", "-1", "x", "1.5"):
            with self.subTest(value=value):
                process, started, _ = self._start(f"bad{value}", slots=value)
                _, error = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 2)
                self.assertIn("MOKUME_GPU_SLOTS", error)
                self.assertFalse(started.exists())

    def test_an_unusable_slot_directory_runs_without_a_slot_and_says_so(self):
        blocker = self.root / "blocker"
        blocker.write_text("")  # ファイルの下にディレクトリは作れない
        process, started, release = self._start(
            "unslotted", extra={"MOKUME_GPU_SLOT_DIR": str(blocker / "slots")}
        )
        self.assertTrue(_wait_for(started.exists), "置き場を使えないと子が走らない")
        release.touch()
        _, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertIn("枠を取らずに走らせる", error)

    def test_take_and_release_are_recorded_with_the_child_and_its_exit(self):
        process, started, release = self._start("recorded", code=3)
        self.assertTrue(_wait_for(started.exists))
        release.touch()
        self.assertEqual(process.wait(timeout=10), 3)
        take, done = self._entries()
        self.assertEqual(take["event"], "take")
        self.assertEqual(take["pid"], process.pid)
        self.assertEqual(take["slot"], "slot-0.lock")
        self.assertEqual(take["command"][0], sys.executable)
        self.assertEqual(done["event"], "release")
        self.assertEqual(done["exit_code"], 3)

    def test_the_lineage_reaches_the_process_that_started_it(self):
        # #2052: 起動元は、包みの親 (ここでは検査の Python) を辿って分かる
        process, started, release = self._start("lineage")
        self.assertTrue(_wait_for(started.exists))
        release.touch()
        process.wait(timeout=10)
        lineage = self._entries()[0]["lineage"]
        self.assertEqual(lineage[0]["pid"], process.pid)
        self.assertEqual(lineage[0]["ppid"], os.getpid())
        self.assertEqual(lineage[1]["pid"], os.getpid())
        own = subprocess.run(
            ["ps", "-o", "command=", "-p", str(os.getpid())], capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"}
        ).stdout.strip()
        self.assertEqual(lineage[1]["command"], own[:4000])  # Python.app の中の python も切らずに残す

    def test_the_agent_session_is_recorded(self):
        process, started, release = self._start(
            "agent", extra={"CLAUDE_CODE_SESSION_ID": "session-for-test", "MOKUME_AGENT_NAME": ""}
        )
        self.assertTrue(_wait_for(started.exists))
        release.touch()
        process.wait(timeout=10)
        agent = self._entries()[0]["agent"]
        self.assertEqual(agent["CLAUDE_CODE_SESSION_ID"], "session-for-test")
        self.assertNotIn("MOKUME_AGENT_NAME", agent)  # 空の値は載せない

    def test_giving_up_at_the_deadline_is_recorded(self):
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, _, _ = self._start("waiter", slots="1", wait="0.3")
        waiter.communicate(timeout=10)
        timeouts = [entry for entry in self._entries() if entry["event"] == "timeout"]
        self.assertEqual(len(timeouts), 1)
        self.assertEqual(timeouts[0]["pid"], waiter.pid)
        self.assertEqual(timeouts[0]["lineage"][0]["pid"], waiter.pid)
        self.assertIn(_holder_mark(holder.pid), " ".join(timeouts[0]["holders"]))

    def test_an_unwritable_record_still_runs_the_child_and_says_so(self):
        blocker = self.root / "blocker"
        blocker.write_text("")  # ファイルの下にディレクトリは作れない
        process, started, release = self._start(
            "unrecorded", code=4, extra={"MOKUME_GPU_SLOT_LOG": str(blocker / "log" / "gpu-slot.jsonl")}
        )
        self.assertTrue(_wait_for(started.exists), "記録に書けないと子が走らない")
        release.touch()
        _, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 4)
        self.assertIn("起動元の記録", error)

    def test_an_oversized_record_keeps_only_the_newer_half(self):
        self.log.parent.mkdir(parents=True)
        old = json.dumps({"event": "old", "padding": "x" * 200}) + "\n"
        self.log.write_text(old * 20000, encoding="utf-8")  # 約 4.4 MB
        inode = self.log.stat().st_ino
        process, started, release = self._start("trim")
        self.assertTrue(_wait_for(started.exists))
        release.touch()
        process.wait(timeout=10)
        self.assertLess(self.log.stat().st_size, 4_000_000)
        # 置き換えると、ロックを待っていた他のプロセスの行が名前の外れたファイルへ消える
        self.assertEqual(self.log.stat().st_ino, inode, "切り詰めでファイルを置き換えた")
        entries = self._entries()  # 行の途中で切れていない
        self.assertEqual(entries[-1]["event"], "release")
        self.assertEqual(entries[-2]["event"], "take")
        self.assertEqual(entries[0]["event"], "old")

    def test_a_vanished_cwd_still_runs_the_child_and_returns_its_code(self):
        # 反証の指摘: os.getcwd() が投げると、記録のために子が走らなくなっていた
        gone = self.root / "gone"
        gone.mkdir()
        started = self.root / "gone.started"
        release = self.root / "gone.release"
        release.touch()
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c", CHILD, str(started), str(release), "5"],
            env=self._environment(), cwd=gone, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.running.append(process)
        gone.rmdir()
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, 5)
        self.assertTrue(started.exists())

    def test_a_command_line_that_is_not_utf8_still_runs_the_child(self):
        # 反証の指摘: ps の出力を UTF-8 で読めないと、記録のために子が走らなくなっていた
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c", "import sys; sys.exit(6)", b"\xff"],
            env=self._environment(), capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertEqual(self._entries()[-1]["exit_code"], 6)

    def test_giving_up_keeps_its_exit_code_even_when_the_record_fails(self):
        # 反証の指摘: 待つ間に cwd が消えると、記録の失敗が「置き場を使えない」に化け、75 が 1 に変わった
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        gone = self.root / "gone"
        gone.mkdir()
        waiter = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c", "pass"],
            env=self._environment(slots="1", wait="5"), cwd=gone,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.running.append(waiter)
        said = _Said(waiter)
        # 待ちに入った (名乗った) のを待ってから消す。期限 (5 秒) までに消えれば、待つ間に消えたことになる。
        # 固定の眠りだと、子の起動が遅ければ待つ前に消え、検査側が止まれば期限の後に消える (#2304)。
        # 期限は抜けるのを確かめるために有限に置くしかないので、両側の止まりに余裕を持たせて 5 秒にする。
        # 待つ側は期限の判定を名乗りより先に行うので、最初の名乗りの前に期限まで止まると名乗らずに抜ける (#2343)
        self.assertTrue(_wait_for(lambda: said.has("空くのを待っている")), "待ちに入った旨を名乗らない")
        gone.rmdir()
        error = said.finish()
        self.assertEqual(waiter.returncode, 75, error)
        self.assertNotIn("枠を取らずに走らせる", error)
        # 消したのが期限より前だった (= 待つ間に消えた) ことを、期限で抜けたときの記録の cwd で確かめる。
        # 検査の側が消す前に期限を越えて止まると、待つ側は cwd が残ったまま抜け、上の 2 つは素通りする
        timeouts = [entry for entry in self._entries() if entry["event"] == "timeout"]
        self.assertEqual([entry["pid"] for entry in timeouts], [waiter.pid], error)
        self.assertTrue(timeouts[0]["cwd"].startswith("<読めない:"), f"期限で抜けた時点で cwd が残っていた: {timeouts[0]['cwd']}")

    def test_the_start_time_is_read_in_the_c_locale(self):
        # 反証の指摘: ja_JP の lstart は 10〜31 日に 4 語になり、コマンドラインの先頭が欄からずれた
        fake = self.root / "bin"
        fake.mkdir()
        (fake / "ps").write_text(
            "#!/bin/sh\n"
            'if [ "$LC_ALL" = C ]; then echo "    1 Wed Oct 14 14:33:01 2026 /bin/zsh -c make test-release"\n'
            'else echo "    1 水 10/14 14:33:01 2026 /bin/zsh -c make test-release"; fi\n'
        )
        (fake / "ps").chmod(0o755)
        process, started, release = self._start(
            "locale", extra={"PATH": f"{fake}:{os.environ['PATH']}", "LC_ALL": "ja_JP.UTF-8"}
        )
        self.assertTrue(_wait_for(started.exists))
        release.touch()
        process.wait(timeout=10)
        first = self._entries()[0]["lineage"][0]
        self.assertEqual(first["started"], "Wed Oct 14 14:33:01 2026")
        self.assertEqual(first["command"], "/bin/zsh -c make test-release")

    def test_usage_without_a_command(self):
        for arguments in ([], ["--exclusive"], ["--exclusive", "--"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), *arguments],
                    env=self._environment(), capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("使い方", result.stderr)


class ExclusiveTest(SlotHarness):
    """窓つきの計測は、GPU の検査と同時に走らない (#2052 の完了条件 2)。

    計測は `--exclusive` で枠を全部取ってから走る。検査が 1 本でも枠を握っていれば計測が待ち、
    計測が走っている間は検査が待つ。どちらの待ちも期限を持ち、待つ間は相手を名乗る。
    """

    def test_the_exclusive_waits_while_a_test_holds_a_slot_and_names_it(self):
        holder, holder_started, holder_release = self._start("holder")
        self.assertTrue(_wait_for(holder_started.exists))
        measure, measure_started, measure_release = self._start("measure", exclusive=True)
        said = _Said(measure)
        # 計測が、検査の握る枠を見て待ちに入った (名乗った) のを待ってから、走っていないことを見る
        self._assert_waiting(said, measure_started, "計測を始めずに待っている", "検査が枠を握っているのに、計測が走った")
        holder_release.touch()
        self.assertEqual(holder.wait(timeout=10), 0)
        self.assertTrue(_wait_for(measure_started.exists), "検査が終わっても計測が走らない")
        measure_release.touch()
        error = said.finish()
        self.assertEqual(measure.returncode, 0, error)
        self.assertIn("計測を始めずに待っている", error)
        self.assertIn(_holder_mark(holder.pid), error)

    def test_a_test_waits_while_the_exclusive_runs_and_names_it(self):
        measure, measure_started, measure_release = self._start("measure", exclusive=True)
        self.assertTrue(_wait_for(measure_started.exists))
        test, test_started, test_release = self._start("test")
        said = _Said(test)
        # 検査の子が、走っている計測を見て待ちに入った (名乗った) のを待ってから、計測を終わらせる
        self._assert_waiting(said, test_started, "窓つきの計測が GPU の枠を全部使う", "計測が走っているのに、検査が走った")
        measure_release.touch()
        self.assertEqual(measure.wait(timeout=10), 0)
        self.assertTrue(_wait_for(test_started.exists), "計測が終わっても検査が走らない")
        test_release.touch()
        error = said.finish()
        self.assertEqual(test.returncode, 0, error)
        self.assertIn("窓つきの計測", error)
        self.assertIn(_holder_mark(measure.pid), error)

    def _gate_is_held(self):
        try:
            with open(self.slots / "exclusive.lock", "r") as handle:
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        except FileNotFoundError:
            return False
        return False

    def test_a_test_that_arrives_while_the_exclusive_waits_does_not_jump_ahead(self):
        # 計測が順番を待っている間に枠が 1 つ空いても、後から来た検査はそれを取らない。取ると、
        # 検査が途切れない限り計測に順番が回ってこない
        first, first_started, first_release = self._start("first")
        second, second_started, second_release = self._start("second")
        self.assertTrue(_wait_for(first_started.exists))
        self.assertTrue(_wait_for(second_started.exists))
        # 計測の取り直しは遅くする。順番待ちの印が効いていなければ、取り直しの速い後の検査が、
        # 空いた枠を先に取る
        measure, measure_started, measure_release = self._start(
            "measure", exclusive=True, extra={"MOKUME_GPU_SLOT_POLL": "1"}
        )
        self.assertTrue(_wait_for(self._gate_is_held), "計測が順番待ちの印を取らない")
        late, late_started, late_release = self._start("late")
        late_said = _Said(late)
        waiting = "窓つきの計測が GPU の枠を全部使う"
        # 後から来た検査が、計測の順番待ちの印を見て待ちに入ってから、枠を空ける (入る前に空けると、
        # 待っている検査が空いた枠を取るかを見る検査が、来たばかりの検査が取るかを見る検査に変わる)
        self._assert_waiting(late_said, late_started, waiting, "計測が順番を待っているのに、後から来た検査が走った")
        first_release.touch()
        self.assertEqual(first.wait(timeout=10), 0)
        # 枠が空いた後に、後から来た検査が空いた枠を見ても取らずに、1 周以上回った、と名乗りで確かめる。
        # 枠は包みが終わる前に返っているので、いま以降に始まる周回は空いた枠を見ている。いま読める名乗りは
        # 空く前に始まった周回のものでありうる (名乗りは周回の終わりに出る) ので、2 つ増えるまで待つ。
        # 2 つめを出す周回は、1 つめの後に始まるので、必ず空いた後に始まっている。飛び越して取っていれば、
        # 名乗りは増えずに走り出す
        seen = late_said.count(waiting)
        _wait_for(lambda: late_started.exists() or late_said.count(waiting) >= seen + 2)
        self.assertFalse(late_started.exists(), "計測が待っている間に、後から来た検査が空いた枠を取った")
        self.assertGreaterEqual(late_said.count(waiting), seen + 2, "枠が空いた後に、後から来た検査が待っている旨を名乗らない")
        second_release.touch()
        self.assertTrue(_wait_for(measure_started.exists), "先の検査が終わっても計測が走らない")
        self.assertFalse(late_started.exists(), "計測が走っている間に、後から来た検査が走った")
        measure_release.touch()
        self.assertTrue(_wait_for(late_started.exists), "計測が終わっても、後から来た検査が走らない")
        late_release.touch()

    def test_the_exclusive_gives_up_at_its_deadline_and_names_the_test(self):
        holder, holder_started, _ = self._start("holder")
        self.assertTrue(_wait_for(holder_started.exists))
        measure, measure_started, _ = self._start("measure", exclusive=True, wait="0.3")
        _, error = measure.communicate(timeout=10)
        self.assertEqual(measure.returncode, 75, error)
        self.assertFalse(measure_started.exists(), "期限で抜けたのに計測を走らせた")
        # 持ち主は、期限で抜ける文面の後ろに探す (待つ間の名乗りも同じ持ち主を名乗る。#2343)
        self.assertTrue(_names_after(error, "空かなかったので", holder.pid), error)
        timeouts = [entry for entry in self._entries() if entry["event"] == "timeout"]
        self.assertEqual([entry["pid"] for entry in timeouts], [measure.pid])
        # 抜けた計測が取りかけた枠は返っている
        after, after_started, after_release = self._start("after")
        self.assertTrue(_wait_for(after_started.exists), "期限で抜けた計測が、枠を握ったまま残った")
        after_release.touch()

    def test_a_test_gives_up_at_its_deadline_and_names_the_exclusive(self):
        measure, measure_started, _ = self._start("measure", exclusive=True)
        self.assertTrue(_wait_for(measure_started.exists))
        test, test_started, _ = self._start("test", wait="0.3")
        _, error = test.communicate(timeout=10)
        self.assertEqual(test.returncode, 75, error)
        self.assertFalse(test_started.exists())
        self.assertIn("窓つきの計測", error)
        # 持ち主は、期限で抜ける文面の後ろに探す (待つ間の名乗りも同じ持ち主を名乗る。#2343)
        self.assertTrue(_names_after(error, "空かなかったので", measure.pid), error)

    def test_the_exclusive_take_is_recorded_with_every_slot(self):
        measure, measure_started, measure_release = self._start("measure", exclusive=True)
        self.assertTrue(_wait_for(measure_started.exists))
        measure_release.touch()
        self.assertEqual(measure.wait(timeout=10), 0)
        take = self._entries()[0]
        self.assertEqual(take["event"], "take")
        self.assertEqual(take["mode"], "exclusive")
        self.assertEqual(take["slots"], ["slot-0.lock", "slot-1.lock"])

    def test_a_command_line_that_is_not_utf8_still_runs_the_measurement(self):
        # 計測のコマンドは順番待ちの印に書くので、書けない引数で包みが落ちないこと
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--exclusive", "--", sys.executable, "-c", "import sys; sys.exit(6)", b"\xff"],
            env=self._environment(), capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 6, result.stderr)

    def test_the_child_knows_it_runs_inside_the_exclusive_and_a_nested_one_does_not_wait(self):
        # 包まれた計測の中から、もう一度 --exclusive を通しても (スクリプトの自分で包む口が、外から
        # 包まれたときに当たる)、自分の親が握る枠を待たずに走る
        nested = (
            "import os, subprocess, sys\n"
            "assert os.environ.get('MOKUME_GPU_SLOT_EXCLUSIVE'), 'no marker'\n"
            "sys.exit(subprocess.run([sys.executable, sys.argv[1], '--exclusive', '--',"
            " sys.executable, '-c', 'import sys; sys.exit(7)']).returncode)\n"
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--exclusive", "--", sys.executable, "-c", nested, str(SCRIPT)],
            env=self._environment(wait="2"), capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("既に", result.stderr)

    def test_a_plain_run_inside_the_exclusive_does_not_wait_for_it(self):
        # 計測の内側で `make test` (= 普段の `gpu-slot.py -- …`) を打っても、祖先が握る順番待ちの印と
        # 枠を期限まで待たない (#2052 の反証)。親の --exclusive が枠を全部握っているので、そのまま走る
        nested = (
            "import os, subprocess, sys\n"
            "sys.exit(subprocess.run([sys.executable, sys.argv[1], '--',"
            " sys.executable, '-c', 'import sys; sys.exit(8)']).returncode)\n"
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--exclusive", "--", sys.executable, "-c", nested, str(SCRIPT)],
            env=self._environment(wait="2"), capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertIn("既に", result.stderr)
        self.assertNotIn("取るのを待っている", result.stderr)


class ParallelizationWidthTest(unittest.TestCase):
    """子の swift test へ、Swift Testing の並列の幅が届くこと (#1999)。"""

    VARIABLE = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    def _child_sees(self, extra):
        environment = {key: value for key, value in os.environ.items() if key != self.VARIABLE}
        environment.update({
            "MOKUME_GPU_SLOT_DIR": self.temporary.name,
            "MOKUME_GPU_SLOT_LOG": str(Path(self.temporary.name) / "gpu-slot.jsonl"),
            "MOKUME_GPU_SLOT_POLL": "0.02",
        })
        environment.update(extra)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c",
             f"import os; print(os.environ.get({self.VARIABLE!r}, 'unset'))"],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_the_child_runs_with_width_1_by_default(self):
        # 幅 4・16・100000 では GPU の仕事が打ち切られ、幅 1 では出なかった (#2007)
        self.assertEqual(self._child_sees({}), "1")

    def test_a_width_given_by_the_caller_is_kept(self):
        # 既定 (1) と区別できる値で見る
        self.assertEqual(self._child_sees({self.VARIABLE: "4"}), "4")

    def test_an_empty_width_is_treated_as_unset(self):
        self.assertEqual(self._child_sees({self.VARIABLE: ""}), "1")


class ExpiryRecordTest(SlotHarness):
    """GPU の待ちが期限を越えたプロセスの記録 (`wait-expired.json`) を、次の検査・計測が名乗って止まること (#2235)。

    子は偽物で、Swift の `ExpiryRecord` が書く形の JSON を、渡された書き先へ自分で書く。本物の GPU も
    Swift も要らない。"""

    EXIT_GPU_STUCK = 76

    # 子が見た、記録の書き先と包みの pid を出す
    SEES = (
        "import os, json\n"
        "print(json.dumps({'path': os.environ.get('MOKUME_GPU_SLOT_EXPIRY_RECORD'),"
        " 'pid': os.environ.get('MOKUME_GPU_SLOT_PID')}))\n"
    )
    # 子が、期限を越えたと名乗って記録を書く (Swift の `ExpiryRecord.write` と同じ項目)
    WRITES = (
        "import os, json\n"
        "path = os.environ['MOKUME_GPU_SLOT_EXPIRY_RECORD']\n"
        "open(path, 'x').write(json.dumps({'event': 'wait-expired', 'time': '2026-10-22T09:00:00+0900',"
        " 'pid': os.getpid(), 'cwd': os.getcwd(), 'wait': 'waiting for the GPU to finish', 'limit': '5 seconds',"
        " 'gpu_slot_pid': int(os.environ['MOKUME_GPU_SLOT_PID'])}))\n"
    )

    @property
    def record(self):
        return self.slots / "wait-expired.json"

    def _write_record(self, **fields):
        self.slots.mkdir(parents=True, exist_ok=True)
        entry = {
            "event": "wait-expired", "time": "2026-10-22T09:00:00+0900", "pid": 4242, "cwd": "/work/tree",
            "wait": "waiting for the GPU to finish", "limit": "5 seconds", "gpu_slot_pid": 1,
        }
        entry.update(fields)
        self.record.write_text(json.dumps(entry), encoding="utf-8")

    def _run_wrapper(self, child_source, exclusive=False, **options):
        mode = ["--exclusive"] if exclusive else []
        return subprocess.run(
            [sys.executable, str(SCRIPT), *mode, "--", sys.executable, "-c", child_source],
            env=self._environment(**options), capture_output=True, text=True, timeout=30,
        )

    def _never_ran(self, result):
        """子 (`SEES` を出すもの) が起きていないこと。"""
        self.assertNotIn("MOKUME_GPU_SLOT_EXPIRY_RECORD", result.stdout)
        self.assertEqual(result.stdout, "")

    def test_a_record_stops_the_run_before_the_child_starts(self):
        self._write_record()
        result = self._run_wrapper(self.SEES + "print('child ran')")
        self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
        self._never_ran(result)
        # 名乗りは、記録の場所・中身 (時刻・pid・cwd・待ち・期限)・人が確かめてから消すこと
        for text in (str(self.record), "2026-10-22T09:00:00+0900", "pid 4242", "/work/tree", "5 seconds", "人が確かめてから消す"):
            self.assertIn(text, result.stderr)
        # 確かめることを先に言い、場所を示すだけにする。読んだエージェントが、確かめずにそのまま打てる削除の
        # 1 行は出さない
        self.assertLess(result.stderr.index("確かめること"), result.stderr.index(f"記録のファイル: {self.record}"))
        for line in result.stderr.splitlines():
            self.assertNotRegex(line.strip(), r"^(rm|unlink|/bin/rm)\b", f"そのまま打てる削除の行がある: {line}")

    def test_a_record_stops_the_exclusive_measurement_too(self):
        self._write_record()
        result = self._run_wrapper(self.SEES, exclusive=True)
        self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
        self._never_ran(result)
        self.assertIn("計測", result.stderr)
        self.assertIn(str(self.record), result.stderr)

    def test_without_a_record_the_child_runs_as_before(self):
        for exclusive in (False, True):
            with self.subTest(exclusive=exclusive):
                result = self._run_wrapper(self.SEES, exclusive=exclusive)
                self.assertEqual(result.returncode, 0, result.stderr)
                seen = json.loads(result.stdout)
                # 子が書き先と包みの pid を受け取る。書き先は置き場の中の 1 つ
                self.assertEqual(seen["path"], str(self.record.absolute()))
                self.assertTrue(seen["pid"].isdigit(), seen)
                self.assertFalse(self.record.exists(), "子が書かなければ、記録は作られない")

    def test_removing_the_record_lets_the_next_run_through(self):
        self._write_record()
        self.assertEqual(self._run_wrapper(self.SEES).returncode, self.EXIT_GPU_STUCK)
        self.record.unlink()
        self.assertEqual(self._run_wrapper(self.SEES).returncode, 0)

    def test_an_unreadable_record_still_stops_the_run(self):
        # 在るのに読めない記録を、無いものとして素通ししない
        self.slots.mkdir(parents=True)
        self.record.write_text("not json", encoding="utf-8")
        result = self._run_wrapper(self.SEES)
        self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
        self._never_ran(result)
        self.assertIn("読めない", result.stderr)

    def test_a_record_that_appears_while_waiting_for_a_slot_stops_the_run(self):
        """枠を待つ間に別のプロセスが期限を越えた回は、枠が取れても起こさず、枠を返す。"""
        holder, holder_started, holder_release = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists), "1 本目が走らない")
        waiting, waiting_started, _ = self._start("waiting", slots="1")
        said = _Said(waiting)
        self._assert_waiting(said, waiting_started, "空くのを待っている", "枠 1 なのに 2 本目が走った")
        self._write_record()
        holder_release.touch()
        self.assertEqual(holder.wait(timeout=10), 0)
        self.assertEqual(waiting.wait(timeout=10), self.EXIT_GPU_STUCK, said.finish())
        self.assertFalse(waiting_started.exists(), "記録が現れた後に、待っていた子が起きた")
        # 枠は返っている (記録を消せば、次はすぐ走る)
        self.record.unlink()
        self.assertEqual(self._run_wrapper(self.SEES, slots="1").returncode, 0)

    def test_a_symlink_record_stops_the_run_whether_it_is_broken_or_alive(self):
        """リンクは辿らず、在るものとして数える。Swift の関所 (lstat) と前検査 (`-L`) と同じ読み方 (#2235)。

        辿ると、壊れたリンクを「無い」と読んで子を起こし、関所が止める記録をこの包みが素通しする。"""
        self.slots.mkdir(parents=True)
        elsewhere = self.root / "elsewhere.json"
        for name, target in (("broken", self.root / "no-such-file.json"), ("alive", elsewhere)):
            with self.subTest(link=name):
                elsewhere.write_text(json.dumps({"event": "wait-expired", "pid": 1}), encoding="utf-8")
                self.record.symlink_to(target)
                result = self._run_wrapper(self.SEES)
                self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
                self._never_ran(result)
                self.assertIn("読めない", result.stderr)  # 辿らないので、中身は読めない記録として止める
                self.assertIn(str(self.record), result.stderr)
                self.record.unlink()
                self.assertTrue(elsewhere.exists(), "リンクの先まで消した")

    def _gpu_slot_module(self):
        spec = importlib.util.spec_from_file_location("gpu_slot_under_test", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_completing_the_record_does_not_bring_back_one_removed_meanwhile(self):
        """起動元を足す間 (読んでから置き換えるまで) に、人が記録を消したら、書き戻さない (#2235)。"""
        module = self._gpu_slot_module()
        self.slots.mkdir(parents=True)
        mine = {"event": "wait-expired", "gpu_slot_pid": os.getpid(), "wait": "w", "limit": "5 seconds"}
        origin = {"lineage": [{"pid": 1}], "agent": {}}

        def person_removes_it(descriptor):
            self.record.unlink()  # 読んだ後、置き換える前に、人が消す

        with mock.patch.dict(os.environ, {"MOKUME_GPU_SLOT_DIR": str(self.slots)}):
            self.record.write_text(json.dumps(mine), encoding="utf-8")
            with mock.patch.object(module, "_fullsync", side_effect=person_removes_it):
                module._complete_expiry(origin)
            self.assertFalse(self.record.exists(), "消した記録を書き戻した")
            self.assertEqual([p.name for p in self.slots.iterdir()], [], "下書きが残った")

            # 消されなければ、起動元が足される (対照)
            self.record.write_text(json.dumps(mine), encoding="utf-8")
            module._complete_expiry(origin)
            self.assertEqual(json.loads(self.record.read_text(encoding="utf-8"))["lineage"], [{"pid": 1}])

    def test_completing_the_record_does_not_follow_a_link(self):
        module = self._gpu_slot_module()
        self.slots.mkdir(parents=True)
        elsewhere = self.root / "elsewhere.json"
        elsewhere.write_text(json.dumps({"gpu_slot_pid": os.getpid()}), encoding="utf-8")
        self.record.symlink_to(elsewhere)
        with mock.patch.dict(os.environ, {"MOKUME_GPU_SLOT_DIR": str(self.slots)}):
            module._complete_expiry({"lineage": [], "agent": {}})
        self.assertNotIn("lineage", json.loads(elsewhere.read_text(encoding="utf-8")))
        self.assertTrue(self.record.is_symlink())

    def test_a_record_stops_the_run_without_waiting_for_a_slot(self):
        """記録があれば、枠が空くのを待たずに止まる (枠を取る前に見る)。"""
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists), "1 本目が走らない")
        self._write_record()
        # 枠は 1 本とも握られている。待つなら、期限 (30 秒) まで返らない
        result = self._run_wrapper(self.SEES, slots="1", wait="30")
        self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
        self.assertNotIn("空くのを待っている", result.stderr)
        self.assertIsNone(holder.poll(), "持ち主が終わっている (待ちの検査にならない)")

    def test_a_run_inside_the_exclusive_also_stops_at_a_record(self):
        """計測の内側で起こした包みは、枠は取らないが、記録は見て止まる (1 つの計測が何本も起こす)。"""
        for exclusive in (False, True):
            with self.subTest(exclusive=exclusive):
                self._write_record()
                result = self._run_wrapper(
                    self.SEES, exclusive=exclusive, extra={"MOKUME_GPU_SLOT_EXCLUSIVE": "4242"})
                self.assertEqual(result.returncode, self.EXIT_GPU_STUCK, result.stderr)
                self._never_ran(result)
                self.assertIn(str(self.record), result.stderr)
                self.assertNotIn("そのまま走らせる", result.stderr)
                self.record.unlink()
                # 記録が無ければ、今までどおり枠を取らずにそのまま走らせる
                clear = self._run_wrapper(
                    self.SEES, exclusive=exclusive, extra={"MOKUME_GPU_SLOT_EXCLUSIVE": "4242"})
                self.assertEqual(clear.returncode, 0, clear.stderr)
                self.assertIn("そのまま走らせる", clear.stderr)

    def test_the_wrapper_adds_the_origin_to_the_record_its_child_wrote(self):
        result = self._run_wrapper(self.WRITES)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text(encoding="utf-8"))
        # 子が書いた項目は残り、包みが起動元 (「起動元の記録」と同じ項目) を足す
        self.assertEqual(record["wait"], "waiting for the GPU to finish")
        self.assertIn("lineage", record)
        self.assertTrue(record["lineage"], "親プロセスの連鎖が空")
        self.assertIn("agent", record)
        # 次の実行は、その記録で止まる
        self.assertEqual(self._run_wrapper(self.SEES).returncode, self.EXIT_GPU_STUCK)

    def test_the_wrapper_leaves_a_record_it_did_not_ask_for(self):
        # 別の包みの子が書いた記録 (gpu_slot_pid が違う) に、起動元を足さない
        self._write_record(gpu_slot_pid=1)
        before = self.record.read_text(encoding="utf-8")
        # 記録で止まるので、子は起きない。止まった包みは、記録に触らない
        self.assertEqual(self._run_wrapper(self.SEES).returncode, self.EXIT_GPU_STUCK)
        self.assertEqual(self.record.read_text(encoding="utf-8"), before)

    def test_stopping_is_recorded_in_the_launch_log(self):
        self._write_record()
        self.assertEqual(self._run_wrapper(self.SEES).returncode, self.EXIT_GPU_STUCK)
        refused = [entry for entry in self._entries() if entry["event"] == "refused"]
        self.assertEqual(len(refused), 1, refused)
        self.assertEqual(refused[0]["reason"], "wait-expired")
        self.assertIn("lineage", refused[0])
        # 子は起きていないので、take は無い
        self.assertEqual([entry for entry in self._entries() if entry["event"] == "take"], [])


class MakefileWiringTest(unittest.TestCase):
    """test と test-release の段が、swift test を枠の包みの内で走らせていること。"""

    def test_swift_test_runs_inside_the_slot(self):
        makefile = (REPO / "Makefile").read_text()
        for target in ("test:", "test-release:"):
            with self.subTest(target=target):
                body = makefile.split(f"\n{target}", 1)[1].split("\n\n", 1)[0]
                runs = [line for line in body.splitlines() if "swift test" in line]
                self.assertTrue(runs, f"{target} に swift test が無い")
                for line in runs:
                    self.assertIn("scripts/gpu-slot.py -- swift test", line)

    def test_the_build_stays_outside_the_slot(self):
        makefile = (REPO / "Makefile").read_text()
        body = makefile.split("\ntest:", 1)[1].split("\n\n", 1)[0]
        builds = [line for line in body.splitlines() if "swift build" in line]
        self.assertTrue(builds)
        for line in builds:
            self.assertNotIn("gpu-slot.py", line)


class MeasurementWiringTest(unittest.TestCase):
    """窓つきの計測のスクリプトが、窓を出す前に `--exclusive` の内側へ入り直すこと (#2052)。"""

    SCRIPTS = ("measure-frame-rate.sh", "check-observation-roundtrip.sh")
    # 窓を出すスケッチを起こす行
    LAUNCHES = ("frame-rate-probe", "./.build/debug/", "swift run ")

    def test_windowed_runs_happen_inside_the_exclusive(self):
        for name in self.SCRIPTS:
            with self.subTest(script=name):
                lines = [
                    line.strip()
                    for line in (REPO / "scripts" / name).read_text(encoding="utf-8").splitlines()
                    if line.strip() and not line.strip().startswith("#")
                ]
                entries = [
                    index for index, line in enumerate(lines)
                    if line.startswith("exec python3 scripts/gpu-slot.py --exclusive -- ")
                ]
                self.assertEqual(len(entries), 1, f"{name} が --exclusive の内側へ入り直していない")
                # 内側かどうかを見ずに入り直すと、自分を包んだ計測の枠を待ち続ける
                guard = next(line for line in reversed(lines[: entries[0]]) if line.startswith("if "))
                self.assertIn("MOKUME_GPU_SLOT_EXCLUSIVE", guard, f"{name} の入り直しが、内側かどうかを見ていない")
                launches = [
                    index for index, line in enumerate(lines)
                    if any(launch in line for launch in self.LAUNCHES)
                ]
                self.assertTrue(launches, f"{name} に窓を出す行が無い")
                self.assertLess(entries[0], min(launches), f"{name} が --exclusive の外で窓を出している")


if __name__ == "__main__":
    unittest.main()
