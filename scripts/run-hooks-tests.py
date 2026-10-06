#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""make hooks-test の駆動役。scripts/tests/*_test.py をファイル単位で並列に走らせる (#1714)。

    python3 scripts/run-hooks-tests.py [--dir DIR]   (呼ぶのは Makefile の hooks-test)

直列の `python3 -m unittest discover -s scripts/tests -p '*_test.py'` は 1195 件で
CI 171 秒・手元 160 秒かかっていた。所要は 53 ファイルに薄く散っていて (最大の
plan_record_test でも 25%)、1 本を削っても縮まないので、ファイルを並べて走らせる。

**1 ファイル = 1 プロセス。** ファイルごとに `python3 -m unittest discover -s DIR -p
<ファイル名>` を起こす。1 本ずつ起こす以外は直列のときと同じ呼び方なので、同じファイル
の中は今までどおり直列で、setUpModule も継承した検査もそのまま走る。ファイル同士が
奪い合う共有状態が無いことは #1714 で 55 本を読んで確かめた。**cwd はリポジトリ直下に
保つ** — cwd から git を引く検査がある (example_shots_test など)。

**並べる順はファイルの大きい順。** 長いファイルを後に回すと、それだけが最後に残って
並列の効き目が消える。実測の所要を記録して並べれば少し縮むが、CI の clean な runner では
記録が無く、状態を持つぶんだけ壊れ方が増える。大きさの順でも見積もりは 3 コアで 63 秒
(実測の順なら 55 秒) だった。

**同時に走らせる数は既定で CPU の数。** 環境変数 HOOKS_TEST_JOBS で上書きできる。
時間の上限を持つ検査が並列で赤くなったと疑うときは、
HOOKS_TEST_JOBS=1 で直列にして切り分ける。

**名乗り。** 終わったファイルから 1 行ずつ `ok` / `FAIL` を出す。落ちたファイルは、
捕まえた出力を 1 ファイルぶんまとめて書く (並列の出力が行の途中で混ざらないように)。
最後に `Ran <合計> tests in <壁時計>s` と `OK` / `FAILED` を出す。合計は各プロセスの
`Ran N tests` を足したもので、直列のときの件数と比べられる。**0 以外で終わったファイルに
加えて、`Ran N` を読めないファイル (殺された・出力が途切れた) と検査が 1 件も無いファイルも
落ちたと数える。** import で死んだファイルは unittest 自身が 1 件の失敗として数えて 1 で
終わるので、終了コードで拾える。

**道具を足した理由 (ADR-0008 決定 6)。** unittest にも discover にも並列の指定は無く
(既存を広げる段)、標準ライブラリに並列のランナーも無い (native の段)。pytest-xdist は
make setup と CI の道具の用意に依存を 1 つ増やすので、標準ライブラリだけで書いた
(置き換えの段)。検査の中身には触れない — scripts/ci-check.sh が段を駆動するのと同じ形。

**CI でだけ極端に遅いファイルは、名前引きを疑う。** macOS 15 以降の GitHub のランナーでは、
`socket.getfqdn()` が約 35 秒止まる (actions/runner-images#14409)。#1860 で並べた後も CI で
縮まなかったのは、`http.server` のサーバを立てる 5 ファイルがこれで 1 本あたり 30〜35 秒
長かったためである (#1714)。検査のサーバが名前を引かないことは run_hooks_tests_test が見る。

テストは scripts/tests/run_hooks_tests_test.py。
"""

import argparse
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DIR = REPO / "scripts" / "tests"
RAN = re.compile(r"^Ran (\d+) tests? in ", re.M)


def jobs() -> int:
    raw = os.environ.get("HOOKS_TEST_JOBS", "")
    if raw:
        try:
            value = int(raw)
        except ValueError:
            sys.exit(f"HOOKS_TEST_JOBS は正の整数で指定する (受け取った値: {raw!r})")
        if value < 1:
            sys.exit(f"HOOKS_TEST_JOBS は正の整数で指定する (受け取った値: {raw!r})")
        return value
    return os.cpu_count() or 1


def run_file(directory: Path, path: Path) -> tuple[Path, int | None, int, str, float]:
    """1 ファイルを別プロセスで走らせ、(ファイル, 件数, 終了コード, 出力, 秒) を返す。"""
    started = time.monotonic()
    proc = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", str(directory), "-p", path.name],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    output = proc.stdout + proc.stderr
    found = RAN.findall(output)
    count = int(found[-1]) if found else None
    return path, count, proc.returncode, output, time.monotonic() - started


def main() -> int:
    parser = argparse.ArgumentParser(description="scripts/tests/*_test.py をファイル単位で並列に走らせる")
    parser.add_argument("--dir", type=Path, default=DEFAULT_DIR, help="検査の置き場 (既定: scripts/tests)")
    args = parser.parse_args()
    directory = args.dir.resolve()

    files = sorted(directory.glob("*_test.py"), key=lambda p: (-p.stat().st_size, p.name))
    if not files:
        print(f"検査のファイルが 1 つも無い ({directory})", file=sys.stderr)
        return 1

    width = jobs()
    failed: list[str] = []
    total = 0
    started = time.monotonic()

    # 結果はこのスレッドだけで受け取る。名乗りが混ざらず、起動に失敗したファイルも
    # 例外として表に出る (完了時のコールバックに任せると、そこで投げた例外は握られる)
    with ThreadPoolExecutor(max_workers=width) as pool:
        futures = [pool.submit(run_file, directory, path) for path in files]
        for future in as_completed(futures):
            path, count, code, output, seconds = future.result()
            name = path.stem
            total += count or 0
            if code == 0 and count is not None and count > 0:
                print(f"ok    {name}  {count} 件  {seconds:.1f}s", flush=True)
                continue
            failed.append(name)
            if count is None:
                why = f"終了コード {code}・件数を読めない (殺されたか出力が途切れた)"
            elif count == 0:
                why = "検査が 1 件も無い"
            else:
                why = f"終了コード {code}・{count} 件"
            print(f"FAIL  {name}  {why}  {seconds:.1f}s", flush=True)
            print(f"----- {name} の出力 -----\n{output.rstrip()}\n----- ここまで -----", flush=True)

    elapsed = time.monotonic() - started
    print(f"\nRan {total} test{'' if total == 1 else 's'} in {elapsed:.3f}s ({len(files)} ファイル・同時に {width})")
    if failed:
        print(f"FAILED ({len(failed)} ファイル: {' '.join(sorted(failed))})")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
