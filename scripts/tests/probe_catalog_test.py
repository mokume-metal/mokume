#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""Tests/probe-catalog.tsv (約束を書いて探させる検査の帰属の表・#3207 の K2) の整合を見る。

固定したいのは 2 つ:

- **表の行の suite が Tests/ に在る** — 改名・削除で行だけが残ると、提案 6 (#3221) の道具が
  殺した検査を提案へ引けない
- **生成器 (`Probe.run(`・#3216) を使う suite が表に在る** — 載せ忘れると、その suite の発見が
  どの提案のものか後から引けない

表の形 (タブ区切り 3 列・提案の名は小文字の語・番号は数字) も、読めない行は名指しで赤にする。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = Path("Tests") / "probe-catalog.tsv"
GENERATOR_CALL = re.compile(r"\bProbe\.run\(")
SUITE_DECLARATION = re.compile(r"^\s*(?:@\w+[^\n]*\n\s*)*(?:\w+\s+)*(?:struct|class|enum)\s+(\w+)", re.M)


def read_catalog(root):
    """表を読み、(行の一覧, 読めない行の名乗り) を返す。行は (suite, 提案の名, 番号)。"""
    rows, problems = [], []
    path = root / CATALOG
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not re.fullmatch(r"\w+", fields[0]) or not re.fullmatch(r"[a-z][a-z0-9-]*", fields[1]) \
                or not fields[2].isdigit():
            problems.append(f"{CATALOG}:{number}: タブ区切りの 3 列 (suite の型名・提案の名・番号) として読めない: {line!r}")
            continue
        rows.append(tuple(fields))
    return rows, problems


def suites_in(root):
    """Tests/ の Swift に宣言された型名と、生成器を呼ぶファイルに宣言された型名。"""
    declared, generating = set(), {}
    for path in sorted((root / "Tests").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        names = set(SUITE_DECLARATION.findall(text))
        declared |= names
        if GENERATOR_CALL.search(text):
            for name in names:
                if name.endswith("Tests"):
                    generating[name] = path.relative_to(root)
    return declared, generating


def problems(root):
    rows, found = read_catalog(root)
    declared, generating = suites_in(root)
    listed = {row[0] for row in rows}
    for suite, proposal, issue in rows:
        if suite not in declared:
            found.append(f"{CATALOG}: {suite} ({proposal} #{issue}) の suite が Tests/ に無い。改名・削除したなら行も直す")
    for suite, path in sorted(generating.items()):
        if suite not in listed:
            found.append(f"{path}: {suite} は生成器 (Probe.run) を使うのに {CATALOG} に無い。suite・提案の名・sub-issue の 1 行を足す")
    return found


class RepositoryCatalogTest(unittest.TestCase):
    def test_the_catalog_of_this_repository_is_consistent(self):
        self.assertEqual(problems(REPO), [])


class CatalogRulesTest(unittest.TestCase):
    def tree(self, catalog, sources):
        root = Path(tempfile.mkdtemp())
        (root / "Tests" / "T").mkdir(parents=True)
        (root / CATALOG).write_text("# 注釈\n" + catalog, encoding="utf-8")
        for name, text in sources.items():
            (root / "Tests" / "T" / name).write_text(text, encoding="utf-8")
        return root

    def test_a_listed_suite_that_exists_is_green(self):
        root = self.tree("FakeTests\tnetwork\t3219\n", {"A.swift": '@Suite("x")\nstruct FakeTests {}\n'})
        self.assertEqual(problems(root), [])

    def test_a_row_without_its_suite_is_red(self):
        root = self.tree("GoneTests\tnetwork\t3219\n", {"A.swift": "struct OtherTests {}\n"})
        self.assertEqual(len(problems(root)), 1)
        self.assertIn("GoneTests (network #3219) の suite が Tests/ に無い", problems(root)[0])

    def test_a_generating_suite_missing_from_the_catalog_is_red(self):
        root = self.tree(
            "", {"D.swift": '@Suite("密度")\nnonisolated struct DensityTests {\n  func f() { Probe.run(name: "d") }\n}\n'})
        found = problems(root)
        self.assertEqual(len(found), 1)
        self.assertIn("DensityTests は生成器 (Probe.run) を使うのに", found[0])

    def test_a_row_that_cannot_be_read_is_named(self):
        root = self.tree("FakeTests network 3219\n", {"A.swift": "struct FakeTests {}\n"})
        found = problems(root)
        self.assertEqual(len(found), 1)
        self.assertIn(":2: タブ区切りの 3 列", found[0])


if __name__ == "__main__":
    unittest.main()
