#!/usr/bin/env python3
"""Fails when a UI string in the Swift sources has no Ukrainian translation, or a translation is unused.

Keys are the English strings passed to NSLocalizedString, LocalizedStringKey and SwiftUI's Text, Toggle,
Section, Button, Picker, LabeledContent and Label initialisers, plus the rows of the "How it works" list.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
literal = r'"((?:[^"\\]|\\.)*)"'
patterns = [
    re.compile(r'(?:NSLocalizedString|LocalizedStringKey|Text|Toggle|Section|Button|Picker|LabeledContent|Label)\(\s*' + literal),
    re.compile(r'row\("[^"]+",\s*' + literal + r'\)'),
]

used = set()
for source in (root / "Sources").rglob("*.swift"):
    text = source.read_text()
    for pattern in patterns:
        used.update(match.group(1) for match in pattern.finditer(text))

strings = (root / "Resources/uk.lproj/Localizable.strings").read_text()
translated = set(re.findall(r'^' + literal + r'\s*=', strings, re.M))

missing = sorted(used - translated)
unused = sorted(translated - used)
for key in missing:
    print(f"missing Ukrainian translation: {key}")
for key in unused:
    print(f"unused Ukrainian translation: {key}")
sys.exit(1 if missing or unused else 0)
