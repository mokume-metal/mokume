#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""観測面へ要求を置き、応答を待つ経路の検査 (#817)。

**この検査がいちばん埋めているのは「CI で一度も動かない」ことである。**
`check-observation-roundtrip.sh` と `measure-frame-rate.sh --observe` は画面と GPU が
要るので `make ci-check` に入っていない — 壊れていても誰も気付かない状態だった。

だから固定するのは 3 つ:

1. **置き方・待ち方** (`observe_lib`) — 原子的に置く / 識別子の一致で完了を知る /
   期限を越えたら諦める
2. **数える側を実際に起動する** — 偽のスケッチ役スレッドが応答を返すディレクトリを
   相手に `observation_roundtrip.py` と `frame_rate_observe.py pressure` を走らせる。
   GPU 無しで、置く → 待つ → 数える経路が通る
3. **fps の判定** (`frame_rate_observe.judgment`) — 純関数なので合成したログで固定できる

**新しい検査 (Makefile の的) は足さない。** `make hooks-test` が `-p '*_test.py'` で
discover するので、ここに 1 ファイル置けば CI にも載る (ADR-0008 決定 5 段 1)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


observe_lib = _load("observe_lib", SCRIPTS / "observe_lib.py")
frame_rate = _load("frame_rate_observe", SCRIPTS / "frame_rate_observe.py")


class Sketch:
    """偽のスケッチ役。`request.json` を見て、同じ識別子の `report.json` を書く。

    **本物と同じ経路を通す** — 要求は原子的に置かれ、応答は識別子で照合される。
    frame は毎回 1 つ進める (数える側が「フレームが進んでいる」と読めるように)。
    """

    def __init__(self, *facets: Path, answer=True, frame=None):
        self.facets = facets
        self.answer = answer
        # **面ごとに覚える。** 観測と入力には同じ識別子が置かれるので、まとめて
        # 覚えると 2 面目が「もう見た」で素通りする
        self.seen: dict[Path, list[str]] = {f: [] for f in facets}
        self.frames = 0
        # 固定すると「フレームが進んでいない」を装える (止まったランタイム)
        self.frozen = frame
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    @property
    def placed(self) -> list[str]:
        """置かれた識別子を、面をまたいで並べたもの。"""
        return [i for seen in self.seen.values() for i in seen]

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *_):
        self._stop.set()
        self._thread.join(timeout=2)

    def _run(self):
        while not self._stop.is_set():
            for facet in self.facets:
                try:
                    request = json.loads((facet / "request.json").read_text())
                except Exception:
                    continue
                identifier = request.get("id")
                if identifier is None or identifier in self.seen[facet]:
                    continue
                self.seen[facet].append(identifier)
                if not self.answer:
                    continue
                self.frames += 1
                frame = self.frames if self.frozen is None else self.frozen
                (facet / "report.json").write_text(
                    json.dumps({"id": identifier, "frame": frame})
                )
            time.sleep(0.002)


def facets(root: Path, *names: str) -> tuple[Path, ...]:
    made = []
    for name in names:
        facet = root / ".mokume" / name
        facet.mkdir(parents=True)
        made.append(facet)
    return tuple(made)


class PlaceAndAnswerTest(unittest.TestCase):
    """置き方・待ち方 (ADR-0018 決定 3)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.observe,) = facets(self.root, "observe")

    def test_the_request_lands_under_its_real_name(self):
        observe_lib.place(self.observe, {"id": "a"})
        self.assertEqual(json.loads((self.observe / "request.json").read_text()), {"id": "a"})

    def test_no_partial_file_is_left_behind(self):
        """**tmp を残さない。** 残ると次の読み手が書き途中を掴みうる。"""
        observe_lib.place(self.observe, {"id": "a"})
        self.assertFalse((self.observe / ".request.json.tmp").exists())

    def test_the_matching_report_comes_back(self):
        (self.observe / "report.json").write_text(json.dumps({"id": "a", "frame": 3}))
        report = observe_lib.answered(self.observe, "a", 0.2)
        self.assertEqual(report["frame"], 3)

    def test_a_stale_report_is_not_an_answer(self):
        """**壁時計ではなく識別子の一致で完了を知る。**

        前の要求の応答が残っているだけの状態を「返った」と読むと、遅い応答を
        取り違える。
        """
        (self.observe / "report.json").write_text(json.dumps({"id": "old"}))
        self.assertIsNone(observe_lib.answered(self.observe, "new", 0.05))

    def test_an_unreadable_report_is_just_not_yet(self):
        """書き換えの途中を掴んでも落ちない (次の周回で読み直す)。"""
        (self.observe / "report.json").write_text("{壊れた")
        self.assertIsNone(observe_lib.answered(self.observe, "a", 0.05))

    def test_the_deadline_is_honoured(self):
        """固まりうる待ちには待つ側が期限を持たせる (AGENTS.md)。"""
        started = time.time()
        self.assertIsNone(observe_lib.answered(self.observe, "a", 0.1))
        self.assertLess(time.time() - started, 2.0)


class RoundtripTest(unittest.TestCase):
    """**数える側を実際に起動する。** GPU の要る shell の中身を CI で通す唯一の経路。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.observe, self.inbox = facets(self.root, "observe", "input")

    def run_roundtrip(self, rounds, deadline="0.5"):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "observation_roundtrip.py"),
                str(self.root / ".mokume"),
                str(rounds),
                deadline,
            ],
            capture_output=True,
            text=True,
        )

    def test_all_answered_is_green(self):
        with Sketch(self.observe, self.inbox):
            proc = self.run_roundtrip(3)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("ok 観測 3/3", proc.stdout)
        self.assertIn("ok 入力 3/3", proc.stdout)
        self.assertIn("ok フレームは進み続けた", proc.stdout)

    def test_no_answer_is_red_and_names_the_rounds(self):
        with Sketch(self.observe, self.inbox, answer=False):
            proc = self.run_roundtrip(2, "0.05")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("NG 観測 0/2", proc.stdout)
        self.assertIn("応答が返らなかった回 1, 2", proc.stdout)

    def test_a_stuck_frame_number_is_red(self):
        """**応答が返るだけでは足りない** (ADR-0018)。

        止まったランタイムでも観測には応えられるので、番号が動いていることまで見て
        絵の生死を分ける。ここでは応答は全部返すが frame を固定した偽スケッチを使う。
        """
        with Sketch(self.observe, self.inbox, frame=7):
            proc = self.run_roundtrip(2)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("NG フレームが進んでいない (7 → 7)", proc.stdout)
        # 応答そのものは返っている — 分けて読めることが要点
        self.assertIn("ok 観測 2/2", proc.stdout)

    def test_pressure_keeps_placing_requests(self):
        with Sketch(self.observe) as sketch:
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "frame_rate_observe.py"),
                    "pressure",
                    str(self.observe),
                    "0.3",
                ],
                capture_output=True,
                text=True,
            )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # 識別子を変えながら**続けて**置いていること (1 回で終わっていない)
        self.assertGreater(len(sketch.placed), 1, f"置かれた要求が {sketch.placed}")
        self.assertEqual(sketch.placed[0], "m1")


class JudgementTest(unittest.TestCase):
    """fps の判定 — 純関数なので合成したログで固定できる。"""

    def rates(self, warmup, baseline, after):
        return [10.0] * warmup + baseline + after

    def test_a_steady_rate_is_green(self):
        status, lines = frame_rate.judgment(self.rates(5, [60.0] * 15, [55.0] * 20), 15, 0.5)
        self.assertEqual(status, 0)
        self.assertIn("ok 落ちなかった", "\n".join(lines))
        # 緑 1 回では足りないことを必ず言う (#370)
        self.assertIn("3 回続けて", "\n".join(lines))

    def test_the_baseline_is_the_median_not_the_mean(self):
        """**中央値を使う。** 平均だと立ち上がりの外れ値 1 つで基準がずれる。"""
        baseline = [60.0] * 14 + [1.0]
        status, lines = frame_rate.judgment(self.rates(5, baseline, [40.0] * 20), 15, 0.5)
        self.assertEqual(status, 0, "\n".join(lines))
        self.assertIn("60.0 fps", lines[0])

    def test_the_first_second_below_the_floor_is_named(self):
        after = [55.0] * 10 + [5.0] * 10
        status, lines = frame_rate.judgment(self.rates(5, [60.0] * 15, after), 15, 0.5)
        self.assertEqual(status, 1)
        # 立ち上がり 5 + 基準 15 + 10 番目の次 = 31 秒目
        self.assertIn("31 秒あたりで", "\n".join(lines))

    def test_too_few_samples_is_red(self):
        """**測れなかったことを緑にしない。** 数字が無いのは「落ちなかった」ではない。"""
        status, lines = frame_rate.judgment([60.0] * 10, 15, 0.5)
        self.assertEqual(status, 1)
        self.assertIn("測れた秒数が足りない", lines[0])

    def test_only_the_fps_lines_are_read(self):
        text = "== 背面 ==\nfps=60.0\n注意: なにか\nfps=55.5\n"
        self.assertEqual(frame_rate.rates_in(text), [60.0, 55.5])


if __name__ == "__main__":
    unittest.main()
