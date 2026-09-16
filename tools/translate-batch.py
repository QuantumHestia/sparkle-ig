#!/usr/bin/env python3
"""Extract the untranslated half of a catalog, and merge translations back in.

A community catalog is ~2250 entries. Handing that whole file to a translator to
edit in place is the expensive way to do this: the file has to be read to be
edited safely, and almost none of it needs to change. This splits the job so the
translator only ever sees the entries that are actually still English.

    tools/translate-batch.py extract id -o work/id.strings
    # translate the values in work/id.strings, leaving the keys alone
    tools/translate-batch.py merge id work/id.strings

Merging is where the crash-class invariant is enforced. A translation whose
format specifiers do not match English will crash the app the first time that
string is formatted, so a mismatch fails the merge and nothing is written. That
check lives here, deterministically, rather than in the judgement of whoever or
whatever produced the translation.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGLISH = ROOT / "resources" / "Sparkle.bundle" / "en.lproj" / "Localizable.strings"
TRANSLATIONS = ROOT / "translations"

ENTRY_RE = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
# printf conversions as Foundation accepts them, including the positional %2$@ form.
SPEC_RE = re.compile(r"%(\d+\$)?[-+ #0]*[\d*]*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@diouxXeEfgGaAcCsSpn%])")


def entries(path: Path) -> dict[str, tuple[str, str]]:
    """Map key -> (value, whole source line). The raw line is kept so a merge can
    splice entries back without having to re-derive their escaping."""
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = ENTRY_RE.match(line)
        if match:
            found[match.group(1)] = (match.group(2), line)
    return found


def specifiers(value: str) -> tuple[list[str], list[tuple[int, str]]]:
    """Split a string's conversions into positional and non-positional ones.
    `%%` is a literal percent and consumes no argument, so it is dropped."""
    plain: list[str] = []
    positional: list[tuple[int, str]] = []
    for index, conversion in SPEC_RE.findall(value):
        if conversion == "%":
            continue
        if index:
            positional.append((int(index[:-1]), conversion))
        else:
            plain.append(conversion)
    return plain, positional


def specifier_error(english: str, translated: str) -> str | None:
    """Explain why `translated` cannot safely stand in for `english`, or None if it can.

    Reordering is legitimate and common, but it has to be spelled positionally:
    swapping two bare `%@` changes which argument lands where, while `%2$@ %1$@`
    says so explicitly and is safe."""
    want, want_positional = specifiers(english)
    if want_positional:  # English never uses positional form; if it starts to, this needs revisiting.
        return f"English itself is positional ({english!r}), which this check does not model"
    got, got_positional = specifiers(translated)

    if got and got_positional:
        return "mixes positional and non-positional specifiers, which Foundation reads inconsistently"

    if got_positional:
        for index, conversion in got_positional:
            if not 1 <= index <= len(want):
                return f"%{index}$ refers to argument {index}, but English passes {len(want)}"
            if want[index - 1] != conversion:
                return f"%{index}${conversion} takes argument {index}, which English formats as %{want[index - 1]}"
        return None

    # Without positions the arguments are consumed in order, so order is part of the contract.
    if got != want:
        return f"expected {''.join('%' + c for c in want) or 'no specifiers'}, found {''.join('%' + c for c in got) or 'none'}"
    return None


def catalog_path(locale: str) -> Path:
    path = TRANSLATIONS / f"{locale}.lproj" / "Localizable.strings"
    if not path.exists():
        raise SystemExit(f"No catalog for {locale} at {path.relative_to(ROOT)}")
    return path


def extract(locale: str, out: Path | None) -> int:
    english = entries(ENGLISH)
    catalog = entries(catalog_path(locale))
    # A value byte-identical to English was seeded from it and never translated.
    # Some of these stay English on purpose (proper nouns, codec names); that call
    # belongs to the translator, so they are all offered here.
    pending = [line for key, (_, line) in sorted(english.items())
               if key in catalog and catalog[key][0] == english[key][0]]
    text = "\n".join(pending) + "\n" if pending else ""
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print(f"{locale}: {len(pending)} untranslated entries -> {out}")
    else:
        sys.stdout.write(text)
    return 0


def merge(locale: str, source: Path) -> int:
    english = entries(ENGLISH)
    path = catalog_path(locale)
    catalog = entries(path)
    incoming = entries(source)
    if not incoming:
        raise SystemExit(f"No entries parsed from {source}; expected lines of \"KEY\" = \"value\";")

    problems = []
    for key in sorted(incoming):
        if key not in english:
            problems.append(f"{key}: not a key in the English catalog")
            continue
        reason = specifier_error(english[key][0], incoming[key][0])
        if reason:
            problems.append(f"{key}: {reason}")
    if problems:
        print(f"{locale}: refusing to merge, {len(problems)} entr(ies) would break formatting:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    translated = untouched = 0
    for key, (value, line) in incoming.items():
        if catalog[key][0] == value:
            untouched += 1
            continue
        catalog[key] = (value, line)
        translated += 1

    # Catalogs are sorted by key with no comments, which is what the linter enforces.
    path.write_text("\n".join(catalog[key][1] for key in sorted(catalog)) + "\n", encoding="utf-8")
    still_english = sum(1 for key, (value, _) in catalog.items()
                        if key in english and value == english[key][0])
    print(f"{locale}: merged {translated} translation(s), {untouched} left as English, "
          f"{still_english} of {len(english)} still English overall")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    take = sub.add_parser("extract", help="write a locale's still-English entries for translation")
    take.add_argument("locale")
    take.add_argument("-o", "--out", type=Path, help="destination file (default: stdout)")

    put = sub.add_parser("merge", help="splice translated entries back into a locale's catalog")
    put.add_argument("locale")
    put.add_argument("source", type=Path)

    args = parser.parse_args()
    if args.command == "extract":
        return extract(args.locale, args.out)
    return merge(args.locale, args.source)


if __name__ == "__main__":
    raise SystemExit(main())
