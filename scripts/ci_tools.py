#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""手元の reuse・chardet・check-jsonschema が、CI と同じ版かを見る (#2612)。

    python3 scripts/ci_tools.py check   (呼ぶのは Makefile の setup)

**版の正本は scripts/ci-tools.txt の 1 か所。** CI の ubuntu のジョブ (ci-static) はそこから
照合値つきで入れる。手元の版がずれると、同じ木で手元と CI の結論がずれうる (ADR-0001 原則 8)。
ここは同じファイルを読んで、入っている版と突き合わせ、違えば版つきの入れ方を名乗って 1 で抜ける。
版を写さないので、ci-tools.txt を上げれば手元の案内も同時に上がる。

chardet は reuse の encoding 判定モジュール (#48・Makefile の REUSE_ENCODING_MODULE) で、
reuse と同じ環境に入っている必要がある。reuse の実行ファイルの shebang が指す Python で
読む (pipx でも venv でも、その環境の Python を指す)。

検査は scripts/tests/ci_tools_test.py。
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

PINS = Path(__file__).resolve().parent / "ci-tools.txt"
# 手元で見る 3 つ。残りはこれらの依存で、版の差が結論に効く道具ではない
TOOLS = ("reuse", "chardet", "check-jsonschema")
VERSION = re.compile(r"\bversion (\S+)")


def pins(path: Path = PINS) -> dict[str, str]:
    """ci-tools.txt の `名前==版` を読む。"""
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Za-z0-9._-]+)==(\S+)", line)
        if m:
            found[m.group(1).lower()] = m.group(2)
    return found


def install_lines(pinned: dict[str, str]) -> list[str]:
    return [
        f"pipx install --force reuse=={pinned['reuse']} && pipx inject reuse chardet=={pinned['chardet']}",
        f"pipx install --force check-jsonschema=={pinned['check-jsonschema']}",
    ]


def tool_version(command: str) -> str | None:
    """`<command> --version` が名乗る版。起動できなければ None。"""
    try:
        out = subprocess.run([command, "--version"], capture_output=True, text=True, timeout=60)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    m = VERSION.search(out.stdout)
    return m.group(1) if m else None


def chardet_version(reuse: str) -> str | None:
    """reuse と同じ環境の chardet の版。読めなければ None。"""
    try:
        head = Path(reuse).read_text(encoding="utf-8", errors="replace").splitlines()[:2]
    except OSError:
        return None
    if not head or not head[0].startswith("#!"):
        return None
    interpreter = head[0][2:].strip().split()
    # Python の置き場に空白があると、pip は shebang の代わりに sh で起こし直す 2 行を書く
    # (pipx の既定の置き場 ~/Library/Application Support がそれに当たる)
    trampoline = re.match(r"""^'''exec' "([^"]+)" """, head[1]) if len(head) > 1 else None
    if trampoline:
        interpreter = [trampoline.group(1)]
    try:
        out = subprocess.run(
            [*interpreter, "-c", "import chardet; print(chardet.__version__)"],
            capture_output=True, text=True, timeout=60,
        )
    except OSError:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def check() -> int:
    pinned = pins()
    missing = [name for name in TOOLS if name not in pinned]
    if missing:
        print(f"{PINS} に版が無い: {' '.join(missing)}", file=sys.stderr)
        return 1
    found: dict[str, str | None] = {}
    reuse = shutil.which("reuse")
    found["reuse"] = tool_version("reuse") if reuse else None
    found["chardet"] = chardet_version(reuse) if reuse else None
    found["check-jsonschema"] = (
        tool_version("check-jsonschema") if shutil.which("check-jsonschema") else None
    )
    wrong = [name for name in TOOLS if found[name] != pinned[name]]
    if not wrong:
        print("ok: reuse・chardet・check-jsonschema は CI と同じ版 (scripts/ci-tools.txt)")
        return 0
    print("CI と同じ版の道具が揃っていない (版の正本は scripts/ci-tools.txt):", file=sys.stderr)
    for name in wrong:
        print(f"  {name}: 手元 {found[name] or '見つからない'} / CI {pinned[name]}", file=sys.stderr)
    if found["reuse"] is None and reuse:
        # REUSE_ENCODING_MODULE=chardet の下で chardet が無いと、reuse は起動すらしない (#48)
        print("  reuse が起動しない。chardet が同じ環境に無い (Homebrew 版の reuse には同梱されない)", file=sys.stderr)
    print("入れ方:", file=sys.stderr)
    for line in install_lines(pinned):
        print(f"  {line}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if argv[1:] == ["check"]:
        return check()
    print("使い方: python3 scripts/ci_tools.py check", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
