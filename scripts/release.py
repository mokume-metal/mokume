#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""版を決め、リリースノートを組む。

リリースは**リポジトリのファイルを 1 つも変えない**。まとめた変更履歴を main へ
入れるには PR が要り、Actions の既定のトークンで作った PR は他のワークフローを
起こさないので必須チェックが走らない — その迂回はリリースのたびに壊れる場所を
増やす。置き場は GitHub の Releases で足り、ファイルに写すと二重管理になる
(ADR-0001 原則 9)。

したがって:
  - 版は履歴から決める (タグが唯一の記録)
  - ノートの本文は、前回のタグ以降に**追加された** changelog.d/ の断片から組む
  - 断片が 1 つも無ければリリースしない (中身の無い版を出さない)

サブコマンド:
  next-version   次の版を出す。出すものが無ければ終了コード 2
  notes          Release の本文を組んで出す
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
FRAGMENT_DIR = "changelog.d"

# 断片の分類 → 見出し。並びがそのままノートの並びになる
SECTIONS = [
    ("breaking", "破壊的変更"),
    ("feature", "新機能"),
    ("fix", "修正"),
    ("perf", "性能"),
    ("docs", "ドキュメント"),
]

TAG_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
# Conventional Commits の頭。`!` は破壊的変更の印
TITLE_PATTERN = re.compile(r"^(?P<type>[a-z]+)(\([^)]*\))?(?P<breaking>!)?: ")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=REPO, check=True, capture_output=True, text=True
    ).stdout.strip()


def latest_tag() -> str | None:
    """いちばん新しい版のタグ。1 つも無ければ None。"""
    tags = [t for t in git("tag", "--list", "v*").splitlines() if TAG_PATTERN.match(t)]
    if not tags:
        return None
    return max(tags, key=lambda t: tuple(int(n) for n in TAG_PATTERN.match(t).groups()))


def bump_for(titles: list[str], current: tuple[int, int, int]) -> tuple[int, int, int]:
    """コミットのタイトル列から次の版を決める。

    **1.0 未満では破壊的変更も minor で出す。** 0.x は形が動くことを織り込んだ区間で、
    そこで major を上げ始めると 1.0 の意味が薄れる。
    """
    major, minor, patch = current
    breaking = any(
        m.group("breaking") for t in titles if (m := TITLE_PATTERN.match(t))
    ) or any("BREAKING CHANGE" in t for t in titles)
    feature = any(
        (m := TITLE_PATTERN.match(t)) and m.group("type") == "feat" for t in titles
    )

    if major == 0:
        if breaking or feature:
            return (0, minor + 1, 0)
        return (0, minor, patch + 1)
    if breaking:
        return (major + 1, 0, 0)
    if feature:
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def added_fragments(since: str | None) -> list[Path]:
    """前回のタグ以降に**追加された**断片。初回は全部。"""
    if since is None:
        names = git("ls-files", FRAGMENT_DIR).splitlines()
    else:
        names = git(
            "diff", "--name-only", "--diff-filter=A", f"{since}..HEAD", "--", FRAGMENT_DIR
        ).splitlines()
    return [
        REPO / n
        for n in sorted(names)
        if n.endswith(".md") and not n.endswith("README.md")
    ]


def body_of(fragment: Path) -> str:
    """断片から SPDX ヘッダ (HTML コメント) を落とした本文。"""
    text = fragment.read_text(encoding="utf-8")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    return text.strip()


def category_of(fragment: Path) -> str:
    """`<slug>.<category>.md` の分類。"""
    parts = fragment.name.split(".")
    return parts[-2] if len(parts) >= 3 else "feature"


def notes(fragments: list[Path]) -> str:
    """Release の本文を組む。"""
    grouped: dict[str, list[str]] = {}
    for fragment in fragments:
        grouped.setdefault(category_of(fragment), []).append(body_of(fragment))

    lines: list[str] = []
    known = {name for name, _ in SECTIONS}
    for name, heading in SECTIONS:
        if entries := grouped.get(name):
            lines.append(f"## {heading}")
            lines.append("")
            lines.extend(f"- {entry}" for entry in entries)
            lines.append("")
    # 知らない分類も落とさない。落とすと「書いたのにノートに出ない」が黙って起きる
    for name in sorted(set(grouped) - known):
        lines.append(f"## {name}")
        lines.append("")
        lines.extend(f"- {entry}" for entry in grouped[name])
        lines.append("")
    return "\n".join(lines).strip() + "\n"


def command_next_version() -> int:
    previous = latest_tag()
    fragments = added_fragments(previous)
    if not fragments:
        print(
            "前回の版から、利用者に届く変更の断片が 1 つも増えていない。"
            "中身の無い版は出さない",
            file=sys.stderr,
        )
        return 2

    current = (
        (0, 0, 0)
        if previous is None
        else tuple(int(n) for n in TAG_PATTERN.match(previous).groups())
    )
    titles = git(
        "log", "--format=%s%n%b", *(f"{previous}..HEAD",) if previous else ("HEAD",)
    ).splitlines()
    major, minor, patch = bump_for(titles, current)
    print(f"v{major}.{minor}.{patch}")
    return 0


def command_notes() -> int:
    previous = latest_tag()
    fragments = added_fragments(previous)
    if not fragments:
        print("断片が 1 つも無い", file=sys.stderr)
        return 2
    print(notes(fragments), end="")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    match argv[1]:
        case "next-version":
            return command_next_version()
        case "notes":
            return command_notes()
        case unknown:
            print(f"知らないサブコマンド: {unknown}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
