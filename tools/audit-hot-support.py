#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PLAN_PATH = ROOT / "vendor/zig/doc/hot/hot-source-graph-reload-plan.md"
BODY_COMPILER_PATH = ROOT / "vendor/zig/lib/compiler/hot/body_compiler.zig"


CURRENT_SURFACE_GHOSTTY = "Current proven Ghostty function/variable surface:"
CURRENT_SURFACE_TB = "Current proven TigerBeetle function/variable surface:"
TIER_1 = "Tier 1: functions using inline for over comptime-known fields/values"
TIER_2 = "Tier 2: functions with complex switch on tagged unions and error handling"
TIER_3 = "Tier 3: functions with comptime type parameters (monomorphization)"
TIER_4 = "Tier 4: type factories (fundamentally compile-time)"


@dataclass(frozen=True)
class SurfaceGap:
    priority: int
    project: str
    symbol: str
    file: str
    status: str
    compiler_proven: bool


@dataclass(frozen=True)
class CapabilityGap:
    priority: int
    tier: str
    project: str
    symbol: str
    file: str
    blocker: str
    compiler_proven: bool


@dataclass(frozen=True)
class PermanentBoundary:
    symbol: str
    file: str
    blocker: str


def normalize_symbol(raw: str) -> str:
    symbol = raw.strip().strip("`")
    symbol = symbol.replace("TournamentTree.", "Tree.")
    symbol = symbol.replace("ewah.Decoder.", "Decoder.")
    return symbol


def project_for_file(path: str) -> str:
    return "TigerBeetle" if path.startswith("vendor/tigerbeetle/") else "Ghostty"


def compiler_proven_symbols() -> set[str]:
    text = BODY_COMPILER_PATH.read_text()
    symbols: set[str] = set()
    pattern = re.compile(r'test "real source (?:lowering|execute): ([^"]+?) from ')
    for match in pattern.finditer(text):
        symbols.add(normalize_symbol(match.group(1)))
    return symbols


def parse_markdown_tables() -> tuple[list[SurfaceGap], list[CapabilityGap], list[PermanentBoundary]]:
    lines = PLAN_PATH.read_text().splitlines()
    compiler_proven = compiler_proven_symbols()

    current_section = ""
    table_header_seen = False
    surface_gaps: list[SurfaceGap] = []
    capability_gaps: list[CapabilityGap] = []
    permanent_boundaries: list[PermanentBoundary] = []
    fully_proven_surface_symbols: set[str] = set()

    def section_text(line: str) -> str:
        text = line.strip()
        if text.startswith("#"):
            return text.lstrip("#").strip()
        if text.startswith("**") and text.endswith("**"):
            return text.strip("*").strip()
        return ""

    for line in lines:
        section = section_text(line)
        if section:
            current_section = section
            table_header_seen = False
            continue

        if not line.startswith("|"):
            continue

        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        if cells[0] == "Symbol" or set(cells[0]) == {"-"}:
            table_header_seen = True
            continue
        if not table_header_seen:
            continue

        if current_section in (CURRENT_SURFACE_GHOSTTY, CURRENT_SURFACE_TB):
            if len(cells) < 3:
                continue
            symbol = normalize_symbol(cells[0])
            file = cells[1].strip("`")
            status = cells[2].strip()
            lowered_status = status.lower()
            project = "Ghostty" if current_section == CURRENT_SURFACE_GHOSTTY else "TigerBeetle"
            if (
                "currently skips" in lowered_status
                or "compile-body currently skips" in lowered_status
                or "classified only" in lowered_status
                or "compile-body only" in lowered_status
                or "no assoc" in lowered_status
                or "unverified" in lowered_status
            ):
                priority = 1 if "skips" in lowered_status else 2
                surface_gaps.append(
                    SurfaceGap(
                        priority=priority,
                        project=project,
                        symbol=symbol,
                        file=file,
                        status=status,
                        compiler_proven=symbol in compiler_proven,
                    )
                )
            else:
                fully_proven_surface_symbols.add(symbol)
            continue

        if current_section in (TIER_1, TIER_2, TIER_3):
            if len(cells) < 4:
                continue
            symbol = normalize_symbol(cells[0])
            if symbol in compiler_proven or symbol in fully_proven_surface_symbols:
                continue
            tier_priority = {TIER_1: 3, TIER_2: 4, TIER_3: 5}[current_section]
            capability_gaps.append(
                CapabilityGap(
                    priority=tier_priority,
                    tier=current_section,
                    project=project_for_file(cells[1].strip("`")),
                    symbol=symbol,
                    file=cells[1].strip("`"),
                    blocker=cells[3].strip(),
                    compiler_proven=False,
                )
            )
            continue

        if current_section == TIER_4:
            if len(cells) < 4:
                continue
            permanent_boundaries.append(
                PermanentBoundary(
                    symbol=normalize_symbol(cells[0]),
                    file=cells[1].strip("`"),
                    blocker=cells[3].strip(),
                )
            )

    return surface_gaps, capability_gaps, permanent_boundaries


def emit_markdown() -> str:
    surface_gaps, capability_gaps, permanent_boundaries = parse_markdown_tables()

    surface_gaps.sort(key=lambda item: (item.priority, item.project, item.file, item.symbol))
    capability_gaps.sort(key=lambda item: (item.priority, item.project, item.file, item.symbol))
    permanent_boundaries.sort(key=lambda item: (project_for_file(item.file), item.file, item.symbol))

    lines: list[str] = []
    lines.append("## Script-backed hot support gap audit")
    lines.append("")
    lines.append("Generated by `python3 tools/audit-hot-support.py` from:")
    lines.append("")
    lines.append("- `vendor/zig/doc/hot/hot-source-graph-reload-plan.md` current-surface and complex-gap tables")
    lines.append("- `vendor/zig/lib/compiler/hot/body_compiler.zig` `real source lowering` / `real source execute` proofs")
    lines.append("")
    lines.append("Priority order is:")
    lines.append("")
    lines.append("1. downstream proof blocks that still skip")
    lines.append("2. downstream surfaces that are only classified / compile-body-only today")
    lines.append("3. remaining audited compiler/runtime capability gaps")
    lines.append("")
    lines.append(f"### Immediate downstream proof gaps ({len(surface_gaps)})")
    lines.append("")
    lines.append("| Priority | Project | Symbol | File | Current status | Compiler-proven already |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for gap in surface_gaps:
        lines.append(
            f"| P{gap.priority} | {gap.project} | `{gap.symbol}` | `{gap.file}` | {gap.status} | {'yes' if gap.compiler_proven else 'no'} |"
        )
    lines.append("")
    lines.append(f"### Remaining audited capability gaps ({len(capability_gaps)})")
    lines.append("")
    lines.append("| Priority | Tier | Project | Symbol | File | Blocker |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for gap in capability_gaps:
        tier_name = {
            TIER_1: "Tier 1",
            TIER_2: "Tier 2",
            TIER_3: "Tier 3",
        }[gap.tier]
        lines.append(
            f"| P{gap.priority} | {tier_name} | {gap.project} | `{gap.symbol}` | `{gap.file}` | {gap.blocker} |"
        )
    lines.append("")
    lines.append(f"### Permanent compile-time boundaries ({len(permanent_boundaries)})")
    lines.append("")
    lines.append("| Project | Symbol | File | Why out of scope |")
    lines.append("| --- | --- | --- | --- |")
    for boundary in permanent_boundaries:
        lines.append(
            f"| {project_for_file(boundary.file)} | `{boundary.symbol}` | `{boundary.file}` | {boundary.blocker} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    sys.stdout.write(emit_markdown())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
