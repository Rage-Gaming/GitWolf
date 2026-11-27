#!/usr/bin/env python3
"""Regenerates Sources/GitWolfApp/BrandArt.swift from ../assets/*.svg. Run after changing the artwork."""
import pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent
mark = (root.parent / "assets/gitwolf-mark.svg").read_text().strip()
icon = (root.parent / "assets/gitwolf-icon.svg").read_text().strip()
path = root / "Sources/GitWolfApp/BrandArt.swift"
src = path.read_text()
src = re.sub(r'(markSVG = #"""\n).*?(\n"""#)', lambda m: m.group(1) + mark + m.group(2), src, flags=re.S)
src = re.sub(r'(iconSVG = #"""\n).*?(\n"""#)', lambda m: m.group(1) + icon + m.group(2), src, flags=re.S)
path.write_text(src)
