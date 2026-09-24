#!/usr/bin/env python3
"""Deterministic native-table primitive regressions; Python standard library only."""
from __future__ import annotations

import argparse
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
RUNTIMES = ("runtime.tex", "paint_runtime.tex", "layout_runtime.tex", "pager_runtime.tex")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def compile_tex(engine: str, directory: Path, name: str, source: str) -> subprocess.CompletedProcess[str]:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (name + ".tex")
    path.write_text(source, encoding="utf-8")
    result = subprocess.run(
        [engine, "-interaction=nonstopmode", "-halt-on-error", path.name],
        cwd=directory, capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=120, check=False,
    )
    (directory / (name + ".stdout.txt")).write_text(result.stdout + result.stderr, encoding="utf-8")
    return result


def border_cases() -> list[tuple[str, str, int, int, int, int, int]]:
    rng = random.Random(81723)
    return [(axis, style, rng.randrange(1, 45), rng.randrange(1, 5),
             rng.randrange(1, 7), rng.randrange(1, 11), rng.randrange(300))
            for axis in ("H", "V")
            for style in ("solid", "double", "dotted", "dashed", "dashdot", "dashdotdot")
            for _ in range(20)]


def expected_rectangles(case: tuple[str, str, int, int, int, int, int]) -> list[tuple[int, ...]]:
    axis, style, length, thickness, gap, dash, phase = case
    result = []

    def ink(position: int, extent: int, rail: int = 0) -> None:
        result.append((3 + position, 5 + rail, extent, thickness) if axis == "H"
                      else (3 + rail, 5 + position, thickness, extent))

    if style in ("solid", "double"):
        ink(0, length)
        if style == "double":
            ink(0, length, thickness + gap)
        return result
    intervals = [thickness if style == "dotted" else dash, gap]
    intervals += [thickness, gap] * {"dotted": 0, "dashed": 0, "dashdot": 1, "dashdotdot": 2}[style]
    phase %= sum(intervals)
    index = 0
    while phase >= intervals[index]:
        phase -= intervals[index]
        index += 1
    position = 0
    while position < length:
        extent = min(length - position, intervals[index] - phase)
        if index % 2 == 0:
            ink(position, extent)
        position += extent
        index = (index + 1) % len(intervals)
        phase = 0
    return result


def weight_cases() -> list[tuple[int, int, int]]:
    rng = random.Random(12532)
    result = [(300 * 65536, 333333333, 1000000000),
              (19555944, 333333333, 1000000000), (1073741823, 1, 1)]
    for _ in range(200):
        denominator = rng.randrange(1, 1000000001)
        result.append((rng.randrange(1, 1073741824), rng.randrange(1, denominator + 1), denominator))
    return result


def oracle_body(borders: list[tuple], weights: list[tuple]) -> str:
    body = [r"\begingroup", r"\def\vestiTBrawrect{\immediate\write16{RECT \number\vestiTBx,\number\vestiTBy,\number\vestiTBwidth,\number\vestiTBheight}}"]
    for index, (axis, style, length, thickness, gap, dash, phase) in enumerate(borders):
        body += [rf"\immediate\write16{{CASE {index}}}",
                 r"\setbox\vestiTBcanvas=\hbox{\vestiTBborder{%s}{3sp}{5sp}{%dsp}{%s}{%dsp}{%dsp}{%dsp}{%dsp}{gray}{0}}"
                 % (axis, length, style, thickness, gap, dash, phase)]
    body.append(r"\endgroup")
    for index, (available, numerator, denominator) in enumerate(weights):
        body.append(r"\vestiTBavailable=%dsp\relax\vestiTBweighted{%d}{%d}\immediate\write16{WEIGHT %d \number\vestiTBshare}"
                    % (available, numerator, denominator, index))
    return "\n".join(body) + "\n"


def verify_oracles(output: str, borders: list[tuple], weights: list[tuple]) -> None:
    rectangles: dict[int, list[tuple[int, ...]]] = {}
    values = {}
    current = None
    for line in output.splitlines():
        if line.startswith("CASE "):
            current = int(line[5:])
            rectangles[current] = []
        elif line.startswith("RECT "):
            require(current is not None, "Rectangle appears before case marker")
            rectangles[current].append(tuple(map(int, line[5:].split(","))))
        elif line.startswith("WEIGHT "):
            index, value = map(int, line[7:].split())
            values[index] = value
    require(len(rectangles) == len(borders), "Missing border case results")
    require(len(values) == len(weights), "Missing weight case results")
    for index, case in enumerate(borders):
        require(rectangles[index] == expected_rectangles(case), f"Border case {case}: {rectangles[index]}")
    for index, (available, numerator, denominator) in enumerate(weights):
        expected = (2 * available * numerator + denominator) // (2 * denominator)
        require(values[index] == expected, f"Weight case {weights[index]}: {values[index]} != {expected}")


def failure_cases() -> dict[str, tuple[str, str]]:
    result = {}
    effects = {"write": r"\write16{forbidden}", "immediate-write": r"\immediate\write16{forbidden}",
               "insert": r"\insert7{forbidden}", "footnote": r"\footnote{forbidden}",
               "output": r"\output={forbidden}", "pagebreak": r"\eject",
               "float": r"\csname @float\endcsname{figure}"}
    for name, effect in effects.items():
        result[name] = (r"\def\vestiTBcellsource{source row 7 column 2}\setbox\vestiTBcellbox=\vbox{\vestiTBguardcell "
                        + effect + "}", "Vesti T010 at source row 7 column 2")
    style = r"\vestiTBdef{e1style}{double}\vestiTBdef{e1t}{%s}\vestiTBdef{e1g}{%s}\vestiTBdef{e1d}{0pt}\vestiTBdef{e1p}{0pt}\vestiTBvalidatestyle{1}"
    result["rounded-zero"] = (style % (".000001pt", "1pt"), "Vesti T011")
    result["double-overflow"] = (style % ("6000pt", "6000pt"), "Vesti T011")
    result["auto-overflow"] = (r"\vestiTBdef{e1t}{5000pt}\vestiTBautolength{1}{d}{4}", "Vesti T011")
    result["page-headroom"] = (r"\vestiTBdef{pageheight}{1073741823sp}\vestiTBmeasurepage{head}{1}{1}{foot}", "Vesti T009")
    result["explicit-conflict"] = (
        r"\vestiTBcols=1\relax\vestiTBdef{e1sign}{solid}\vestiTBdef{e2sign}{dashed}"
        r"\vestiTBpaintstart\vestiTBpaintpending{\vestiTBhitem0{-1}}"
        r"\vestiTBpaintjoin{\vestiTBhitem0{-2}}", "Vesti T012")
    return result


def run(engine: str, output: Path, runtime: str) -> None:
    executable = shutil.which(engine)
    require(executable is not None, f"TeX executable not found: {engine}")
    directory = output / Path(engine).stem
    borders, weights = border_cases(), weight_cases()
    color = r"\def\vestiTBtestmodel{gray}\def\vestiTBtestcolor{0}" if Path(engine).stem == "tex" else r"\def\vestiTBtestmodel{rgb}\def\vestiTBtestcolor{.1 .3 .6}"
    source = runtime + oracle_body(borders, weights) + color + "\n" + (HERE / "runtime-proof.tex").read_text(encoding="utf-8")
    proof = compile_tex(executable, directory, "runtime-proof", source)
    require(proof.returncode == 0, f"{engine} proof failed:\n{proof.stdout[-6000:]}")
    verify_oracles(proof.stdout, borders, weights)
    require("ASSEMBLY-PASS" in proof.stdout and "STACK-PASS 2000" in proof.stdout, "Missing fixture success markers")
    edges = [(axis, int(style), *map(int, dimensions.split(",")))
             for axis, style, dimensions in re.findall(r"^EDGE ([HV]) (\d+) ([\d,]+)$", proof.stdout, re.MULTILINE)]
    expected = [("H", 1, 0, 0, 105), ("H", 4, 0, 21, 105), ("H", 1, 0, 42, 105),
                ("V", 2, 0, 0, 43), ("V", 3, 51, 0, 43), ("V", 2, 104, 0, 43)]
    require(edges == [(axis, style, x * 65536, y * 65536, length * 65536)
                      for axis, style, x, y, length in expected], f"Incorrect maximal edge runs: {edges}")
    failures = failure_cases()
    for name, (body, diagnostic) in failures.items():
        failed = compile_tex(executable, directory, "fail-" + name, runtime + body + r"\bye")
        require(failed.returncode != 0 and diagnostic in failed.stdout,
                f"{engine} {name}: expected {diagnostic}\n{failed.stdout[-3000:]}")
    print(f"PASS {engine}: 240 border cases, 203 weights, assembly, nested/2,000-cell stacks, {len(failures)} diagnostics")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".zig-cache" / "native-table-runtime")
    parser.add_argument("--engines", nargs="+", default=["pdftex"], help="plain-format TeX engines; e.g. pdftex luatex xetex tex")
    args = parser.parse_args()
    runtime = "\n".join((HERE.parent / name).read_text(encoding="utf-8") for name in RUNTIMES)
    for engine in args.engines:
        run(engine, args.output.resolve(), runtime)
    print(f"Generated proofs and logs: {args.output.resolve()}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
