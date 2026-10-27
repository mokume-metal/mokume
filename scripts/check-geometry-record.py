#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""日次へ移した探索が全て実行されたかを xunit で確かめる (#3338)。

終了コードだけでは、環境変数や filter の誤りで全探索が skipped/0件でも緑になる。
既存の gpu-ran と同じく記録を読む。対象は移した6本の論理テストで、Swift Testingの
引数付きテストは全引数の結果を1つのtestcaseへ集約する。入力数の約束はSwift側でも
確認する。入力/seed/判定器は移行前のままで、ここは実行の完全性だけを見る。

失敗・欠落・skip・重複・読めないXMLは非0。releaseの全検査ではGPU等の無関係なskipは
許すが、対象6本のskipは許さない。--summaryは成功/失敗いずれも同じ記録をMarkdownへ
書く。SHAは実行するcheckoutから取る。記録を古い実行から流用しないのはMakefileが担う。
"""

import argparse
import math
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

REQUIRED = {
    ("CoordinateMagnitudeHolesTests", "wrongBeforeMapping()"),
    ("CoordinateMagnitudeHolesTests", "scaledOrNearbyScenesStayRight(_:)"),
    ("CoordinateMagnitudeHolesTests", "farTranslatedScenesStayRight(_:)"),
    ("NonzeroSplitTests", "randomCrossingRingsNeverGetWorse()"),
    ("NonzeroSplitTests", "randomHolesFollowNonzero()"),
    ("RotatedTouchingHolesTests", "sweepOfScenesWhereABridgeMeetsAVertex(_:)"),
}
INPUTS = "座標: 1133場面×identity/near3/far5; 交差: seed1618×400; 穴: seed77×600; 回転: 場面95/207/214×3600角度"


def inspect(path):
    errors = []
    try:
        root = ET.parse(path).getroot()
        cases = list(root.iter("testcase"))
    except (OSError, ET.ParseError) as error:
        return [f"記録を読めない: {error}"], 0, 0, 0.0
    if root.tag not in ("testsuite", "testsuites"):
        errors.append(f"xunitの根ではない: {root.tag}")
    if not cases:
        errors.append("検査が0件")
    selected = Counter()
    seconds = 0.0
    skipped = 0
    # suiteだけにエラーが載る記録も、testcaseの緑で隠さない。
    for suite in root.iter("testsuite"):
        for attr in ("failures", "errors"):
            try:
                if int(suite.get(attr, "0")) != 0:
                    errors.append(f"suite {suite.get('name')}: {attr}={suite.get(attr)}")
            except ValueError:
                errors.append(f"suiteの{attr}が数でない")
    for case in cases:
        identity = (case.get("classname", ""), case.get("name", ""))
        if case.find("failure") is not None or case.find("error") is not None:
            errors.append(f"失敗: {identity}")
        key = (identity[0].removeprefix("MokumeCoreTests."), identity[1])
        if identity[0] != "MokumeCoreTests." + key[0] or key not in REQUIRED:
            continue
        selected[key] += 1
        if case.find("skipped") is not None:
            skipped += 1
            errors.append(f"探索がskipped: {key}")
        try:
            duration = float(case.attrib["time"])
            if not math.isfinite(duration) or duration < 0:
                raise ValueError("負/非有限の時間")
            seconds += duration
        except (KeyError, ValueError):
            errors.append(f"所要時間が無い/不正: {key}")
    for key in sorted(REQUIRED):
        if selected[key] != 1:
            errors.append(f"探索の欠落/重複: {key}: {selected[key]}件 (必要1件)")
    return errors, sum(selected.values()), skipped, seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), required=True)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    sha = subprocess.run(["git", "rev-parse", "HEAD"], text=True, capture_output=True, check=True).stdout.strip()
    errors, count, skipped, seconds = inspect(args.record)
    lines = ["## 図形の全探索", "", f"SHA: `{sha}` / 構成: `{args.configuration}`",
             f"記録確認: {datetime.now(timezone.utc).isoformat()}", "",
             INPUTS, "", f"探索の論理テスト: {count}/6 / skipped: {skipped} / 累計: {seconds:.3f}秒", "",
             "結果: **失敗**" if errors else "結果: **成功**"]
    lines += [f"- {error}" for error in errors]
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if args.summary:
        args.summary.write_text(text, encoding="utf-8")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
