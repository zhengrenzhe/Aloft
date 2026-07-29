#!/usr/bin/env python3
"""Generate Aloft's pinned Unicode 17 grapheme and NFD data.

The input files are downloaded from the Unicode 17.0.0 public UCD directory,
verified by SHA-256, and converted into compact, sorted Swift tables. The
generated output is deterministic and contains a runtime table fingerprint.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path


UNICODE_VERSION = "17.0.0"
SOURCES = {
    "GraphemeBreakProperty.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt",
        "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    ),
    "DerivedCoreProperties.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt",
        "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
    ),
    "emoji-data.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt",
        "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    ),
    "UnicodeData.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt",
        "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    ),
    "GraphemeBreakTest.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakTest.txt",
        "e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec",
    ),
    "NormalizationTest.txt": (
        "https://www.unicode.org/Public/17.0.0/ucd/NormalizationTest.txt",
        "5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db",
    ),
    "LICENSE.txt": (
        "https://www.unicode.org/license.txt",
        "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96",
    ),
}
SOURCE_CONSTANT_NAMES = {
    "GraphemeBreakProperty.txt": "graphemeBreakPropertySHA256",
    "DerivedCoreProperties.txt": "derivedCorePropertiesSHA256",
    "emoji-data.txt": "emojiDataSHA256",
    "UnicodeData.txt": "unicodeDataSHA256",
    "GraphemeBreakTest.txt": "graphemeBreakTestSHA256",
    "NormalizationTest.txt": "normalizationTestSHA256",
    "LICENSE.txt": "licenseSHA256",
}

GCB_VALUES = {
    "CR": "cr",
    "Control": "control",
    "Extend": "extend",
    "L": "l",
    "LF": "lf",
    "LV": "lv",
    "LVT": "lvt",
    "Prepend": "prepend",
    "Regional_Indicator": "regionalIndicator",
    "SpacingMark": "spacingMark",
    "T": "t",
    "V": "v",
    "ZWJ": "zwj",
}
GCB_RAW_VALUES = {
    "other": 0,
    "cr": 1,
    "lf": 2,
    "control": 3,
    "extend": 4,
    "zwj": 5,
    "regionalIndicator": 6,
    "prepend": 7,
    "spacingMark": 8,
    "l": 9,
    "v": 10,
    "t": 11,
    "lv": 12,
    "lvt": 13,
}
INCB_VALUES = {"Consonant": "consonant", "Linker": "linker", "Extend": "extend"}
INCB_RAW_VALUES = {"none": 0, "consonant": 1, "linker": 2, "extend": 3}


@dataclass(frozen=True, order=True)
class ValueRange:
    lower: int
    upper: int
    value: str


@dataclass(frozen=True, order=True)
class ScalarRange:
    lower: int
    upper: int


@dataclass(frozen=True, order=True)
class Decomposition:
    scalar: int
    values: tuple[int, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Sources/AloftApp/Unicode/Unicode17Data.swift"),
    )
    parser.add_argument(
        "--fixture-output",
        type=Path,
        default=Path("Tests/AloftAppTests/Fixtures/Unicode17/GraphemeBreakTest.txt"),
    )
    parser.add_argument(
        "--normalization-fixture-output",
        type=Path,
        default=Path("Tests/AloftAppTests/Fixtures/Unicode17/NormalizationTest.txt"),
    )
    parser.add_argument(
        "--license-output",
        type=Path,
        default=Path("docs/licenses/Unicode-Terms-of-Use.txt"),
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        help="Use an existing verified source directory instead of downloading.",
    )
    return parser.parse_args()


def verified_sources(source_dir: Path | None) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if source_dir is None:
        temporary = tempfile.TemporaryDirectory(prefix="aloft-unicode17-")
        source_dir = Path(temporary.name)
        for filename, (url, _) in SOURCES.items():
            urllib.request.urlretrieve(url, source_dir / filename)

    for filename, (_, expected) in SOURCES.items():
        path = source_dir / filename
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"{filename}: expected SHA-256 {expected}, got {actual}")
    return source_dir, temporary


def code_range(text: str) -> tuple[int, int]:
    values = text.strip().split("..")
    lower = int(values[0], 16)
    return lower, int(values[-1], 16)


def coalesce_value_ranges(ranges: list[ValueRange]) -> list[ValueRange]:
    result: list[ValueRange] = []
    for item in sorted(ranges):
        if result and item.lower <= result[-1].upper:
            raise RuntimeError(f"overlapping property ranges: {result[-1]} and {item}")
        if result and item.lower == result[-1].upper + 1 and item.value == result[-1].value:
            previous = result.pop()
            result.append(ValueRange(previous.lower, item.upper, item.value))
        else:
            result.append(item)
    return result


def coalesce_scalar_ranges(ranges: list[ScalarRange]) -> list[ScalarRange]:
    result: list[ScalarRange] = []
    for item in sorted(ranges):
        if result and item.lower <= result[-1].upper:
            raise RuntimeError(f"overlapping scalar ranges: {result[-1]} and {item}")
        if result and item.lower == result[-1].upper + 1:
            previous = result.pop()
            result.append(ScalarRange(previous.lower, item.upper))
        else:
            result.append(item)
    return result


def parse_gcb(path: Path) -> list[ValueRange]:
    result: list[ValueRange] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        fields = [part.strip() for part in raw_line.split("#", 1)[0].split(";")]
        if len(fields) < 2 or not fields[0]:
            continue
        lower, upper = code_range(fields[0])
        result.append(ValueRange(lower, upper, GCB_VALUES[fields[1]]))
    return coalesce_value_ranges(result)


def parse_incb(path: Path) -> list[ValueRange]:
    result: list[ValueRange] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        fields = [part.strip() for part in raw_line.split("#", 1)[0].split(";")]
        if len(fields) != 3 or fields[1] != "InCB":
            continue
        lower, upper = code_range(fields[0])
        result.append(ValueRange(lower, upper, INCB_VALUES[fields[2]]))
    return coalesce_value_ranges(result)


def parse_extended_pictographic(path: Path) -> list[ScalarRange]:
    result: list[ScalarRange] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        fields = [part.strip() for part in raw_line.split("#", 1)[0].split(";")]
        if len(fields) < 2 or fields[1] != "Extended_Pictographic":
            continue
        lower, upper = code_range(fields[0])
        result.append(ScalarRange(lower, upper))
    return coalesce_scalar_ranges(result)


def parse_unicode_data(path: Path) -> tuple[list[ValueRange], list[Decomposition]]:
    combining: list[ValueRange] = []
    decompositions: list[Decomposition] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split(";")
        scalar = int(fields[0], 16)
        canonical_combining_class = int(fields[3])
        if canonical_combining_class:
            combining.append(
                ValueRange(scalar, scalar, str(canonical_combining_class))
            )
        mapping = fields[5]
        if mapping and not mapping.startswith("<"):
            decompositions.append(
                Decomposition(scalar, tuple(int(item, 16) for item in mapping.split()))
            )
    return coalesce_value_ranges(combining), decompositions


def fnv1a(values: list[int], version: str) -> int:
    result = 0xCBF29CE484222325
    for byte in version.encode("utf-8") + b"\0":
        result = ((result ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    for value in values:
        for byte in value.to_bytes(4, "little"):
            result = ((result ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return result


def hex_value(value: int) -> str:
    return f"0x{value:04X}"


def swift_value_ranges(name: str, ranges: list[ValueRange], enum_name: str | None) -> list[str]:
    lines = [f"    private static let {name}: [Unicode17ValueRange] = ["]
    for item in ranges:
        value = f"{enum_name}.{item.value}.rawValue" if enum_name else item.value
        lines.append(
            f"        .init(lower: {hex_value(item.lower)}, upper: {hex_value(item.upper)}, value: {value}),"
        )
    lines.append("    ]")
    return lines


def swift_scalar_ranges(name: str, ranges: list[ScalarRange]) -> list[str]:
    lines = [f"    private static let {name}: [Unicode17ScalarRange] = ["]
    for item in ranges:
        lines.append(
            f"        .init(lower: {hex_value(item.lower)}, upper: {hex_value(item.upper)}),"
        )
    lines.append("    ]")
    return lines


def generate_swift(
    gcb: list[ValueRange],
    incb: list[ValueRange],
    extended_pictographic: list[ScalarRange],
    combining: list[ValueRange],
    decompositions: list[Decomposition],
) -> str:
    flattened: list[int] = []
    decomposition_records: list[tuple[int, int, int]] = []
    for item in decompositions:
        decomposition_records.append((item.scalar, len(flattened), len(item.values)))
        flattened.extend(item.values)

    fingerprint_values: list[int] = []
    for item in gcb:
        fingerprint_values.extend(
            (item.lower, item.upper, GCB_RAW_VALUES[item.value])
        )
    for item in incb:
        fingerprint_values.extend(
            (item.lower, item.upper, INCB_RAW_VALUES[item.value])
        )
    for item in extended_pictographic:
        fingerprint_values.extend((item.lower, item.upper))
    for item in combining:
        fingerprint_values.extend((item.lower, item.upper, int(item.value)))
    for scalar, offset, count in decomposition_records:
        fingerprint_values.extend((scalar, offset, count))
    fingerprint_values.extend(flattened)
    fingerprint = fnv1a(fingerprint_values, UNICODE_VERSION)

    lines = [
        "// Generated by script/generate_unicode17_data.py. Do not edit by hand.",
        "// Source: Unicode Character Database 17.0.0.",
        "// Source SHA-256 values are recorded below and verified by the generator.",
        "",
        "enum Unicode17GraphemeBreakClass: UInt8, Sendable {",
        "    case other = 0",
        "    case cr = 1",
        "    case lf = 2",
        "    case control = 3",
        "    case extend = 4",
        "    case zwj = 5",
        "    case regionalIndicator = 6",
        "    case prepend = 7",
        "    case spacingMark = 8",
        "    case l = 9",
        "    case v = 10",
        "    case t = 11",
        "    case lv = 12",
        "    case lvt = 13",
        "}",
        "",
        "enum Unicode17IndicConjunctBreakClass: UInt8, Sendable {",
        "    case none = 0",
        "    case consonant = 1",
        "    case linker = 2",
        "    case extend = 3",
        "}",
        "",
        "private struct Unicode17ValueRange: Sendable {",
        "    let lower: UInt32",
        "    let upper: UInt32",
        "    let value: UInt8",
        "}",
        "",
        "private struct Unicode17ScalarRange: Sendable {",
        "    let lower: UInt32",
        "    let upper: UInt32",
        "}",
        "",
        "private struct Unicode17DecompositionRecord: Sendable {",
        "    let scalar: UInt32",
        "    let offset: Int",
        "    let count: Int",
        "}",
        "",
        "enum Unicode17Data {",
        f'    static let version = "{UNICODE_VERSION}"',
    ]
    for filename, (_, checksum) in SOURCES.items():
        constant = SOURCE_CONSTANT_NAMES[filename]
        lines.append(f'    static let {constant} = "{checksum}"')
    lines.extend(
        [
            f"    private static let expectedTableFingerprint: UInt64 = 0x{fingerprint:016X}",
            "",
            "    static let isValid: Bool = {",
            f'        guard version == "{UNICODE_VERSION}" else {{ return false }}',
            "        return tableFingerprint() == expectedTableFingerprint",
            "            && graphemeBreakClass(of: 0x000D) == .cr",
            "            && graphemeBreakClass(of: 0x000A) == .lf",
            "            && indicConjunctBreakClass(of: 0x094D) == .linker",
            "            && isExtendedPictographic(0x1FAE8)",
            "            && canonicalCombiningClass(of: 0x0315) == 232",
            "            && canonicalDecomposition(of: 0x00E9) == [0x0065, 0x0301]",
            "    }()",
            "",
            "    static func graphemeBreakClass(of scalar: UInt32) -> Unicode17GraphemeBreakClass {",
            "        Unicode17GraphemeBreakClass(rawValue: value(of: scalar, in: graphemeBreakRanges)) ?? .other",
            "    }",
            "",
            "    static func indicConjunctBreakClass(of scalar: UInt32) -> Unicode17IndicConjunctBreakClass {",
            "        Unicode17IndicConjunctBreakClass(rawValue: value(of: scalar, in: indicConjunctBreakRanges)) ?? .none",
            "    }",
            "",
            "    static func isExtendedPictographic(_ scalar: UInt32) -> Bool {",
            "        contains(scalar, in: extendedPictographicRanges)",
            "    }",
            "",
            "    static func canonicalCombiningClass(of scalar: UInt32) -> UInt8 {",
            "        value(of: scalar, in: canonicalCombiningClassRanges)",
            "    }",
            "",
            "    static func canonicalDecomposition(of scalar: UInt32) -> ArraySlice<UInt32>? {",
            "        var lower = 0",
            "        var upper = decompositionRecords.count",
            "        while lower < upper {",
            "            let middle = lower + (upper - lower) / 2",
            "            let record = decompositionRecords[middle]",
            "            if scalar < record.scalar {",
            "                upper = middle",
            "            } else if scalar > record.scalar {",
            "                lower = middle + 1",
            "            } else {",
            "                return decompositionScalars[record.offset..<(record.offset + record.count)]",
            "            }",
            "        }",
            "        return nil",
            "    }",
            "",
            "    private static func value(of scalar: UInt32, in ranges: [Unicode17ValueRange]) -> UInt8 {",
            "        var lower = 0",
            "        var upper = ranges.count",
            "        while lower < upper {",
            "            let middle = lower + (upper - lower) / 2",
            "            let range = ranges[middle]",
            "            if scalar < range.lower {",
            "                upper = middle",
            "            } else if scalar > range.upper {",
            "                lower = middle + 1",
            "            } else {",
            "                return range.value",
            "            }",
            "        }",
            "        return 0",
            "    }",
            "",
            "    private static func contains(_ scalar: UInt32, in ranges: [Unicode17ScalarRange]) -> Bool {",
            "        var lower = 0",
            "        var upper = ranges.count",
            "        while lower < upper {",
            "            let middle = lower + (upper - lower) / 2",
            "            let range = ranges[middle]",
            "            if scalar < range.lower {",
            "                upper = middle",
            "            } else if scalar > range.upper {",
            "                lower = middle + 1",
            "            } else {",
            "                return true",
            "            }",
            "        }",
            "        return false",
            "    }",
            "",
            "    private static func tableFingerprint() -> UInt64 {",
            "        var hash: UInt64 = 0xCBF29CE484222325",
            "        for byte in version.utf8 { updateFingerprint(&hash, with: UInt32(byte), byteCount: 1) }",
            "        updateFingerprint(&hash, with: 0, byteCount: 1)",
            "        for range in graphemeBreakRanges {",
            "            updateFingerprint(&hash, with: range.lower)",
            "            updateFingerprint(&hash, with: range.upper)",
            "            updateFingerprint(&hash, with: UInt32(range.value))",
            "        }",
            "        for range in indicConjunctBreakRanges {",
            "            updateFingerprint(&hash, with: range.lower)",
            "            updateFingerprint(&hash, with: range.upper)",
            "            updateFingerprint(&hash, with: UInt32(range.value))",
            "        }",
            "        for range in extendedPictographicRanges {",
            "            updateFingerprint(&hash, with: range.lower)",
            "            updateFingerprint(&hash, with: range.upper)",
            "        }",
            "        for range in canonicalCombiningClassRanges {",
            "            updateFingerprint(&hash, with: range.lower)",
            "            updateFingerprint(&hash, with: range.upper)",
            "            updateFingerprint(&hash, with: UInt32(range.value))",
            "        }",
            "        for record in decompositionRecords {",
            "            updateFingerprint(&hash, with: record.scalar)",
            "            updateFingerprint(&hash, with: UInt32(record.offset))",
            "            updateFingerprint(&hash, with: UInt32(record.count))",
            "        }",
            "        for scalar in decompositionScalars { updateFingerprint(&hash, with: scalar) }",
            "        return hash",
            "    }",
            "",
            "    private static func updateFingerprint(",
            "        _ hash: inout UInt64,",
            "        with value: UInt32,",
            "        byteCount: Int = 4",
            "    ) {",
            "        for offset in 0..<byteCount {",
            "            hash ^= UInt64((value >> UInt32(offset * 8)) & 0xFF)",
            "            hash = hash &* 0x100000001B3",
            "        }",
            "    }",
            "",
        ]
    )
    lines.extend(swift_value_ranges("graphemeBreakRanges", gcb, "Unicode17GraphemeBreakClass"))
    lines.append("")
    lines.extend(swift_value_ranges("indicConjunctBreakRanges", incb, "Unicode17IndicConjunctBreakClass"))
    lines.append("")
    lines.extend(swift_scalar_ranges("extendedPictographicRanges", extended_pictographic))
    lines.append("")
    lines.extend(swift_value_ranges("canonicalCombiningClassRanges", combining, None))
    lines.extend(
        [
            "",
            "    private static let decompositionRecords: [Unicode17DecompositionRecord] = [",
        ]
    )
    for scalar, offset, count in decomposition_records:
        lines.append(
            f"        .init(scalar: {hex_value(scalar)}, offset: {offset}, count: {count}),"
        )
    lines.append("    ]")
    lines.append("")
    lines.append("    private static let decompositionScalars: [UInt32] = [")
    for offset in range(0, len(flattened), 12):
        values = ", ".join(hex_value(value) for value in flattened[offset : offset + 12])
        lines.append(f"        {values},")
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    source_dir, temporary = verified_sources(args.source_dir)
    try:
        gcb = parse_gcb(source_dir / "GraphemeBreakProperty.txt")
        incb = parse_incb(source_dir / "DerivedCoreProperties.txt")
        extended_pictographic = parse_extended_pictographic(
            source_dir / "emoji-data.txt"
        )
        combining, decompositions = parse_unicode_data(
            source_dir / "UnicodeData.txt"
        )
        output = generate_swift(
            gcb, incb, extended_pictographic, combining, decompositions
        )

        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
        args.fixture_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            source_dir / "GraphemeBreakTest.txt", args.fixture_output
        )
        args.normalization_fixture_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            source_dir / "NormalizationTest.txt",
            args.normalization_fixture_output,
        )
        args.license_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_dir / "LICENSE.txt", args.license_output)
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    main()
