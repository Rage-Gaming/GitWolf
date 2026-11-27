# Design language

GitWolf should feel like a calm, modern, native app: premium but never "AI-generated".

## Rules

1. **No gradients. Anywhere.** Not in buttons, badges, avatars, backgrounds or logos. Flat colour only.
2. **No glow shadows**, neon outlines or decorative blur. Shadows are a soft, low-contrast lift on
   floating panels only.
3. **Native controls first.** Use the platform's real text fields, menus, sheets, pickers, scroll
   views, window chrome and shortcuts. Custom styling only where it clearly helps.
4. **No UI jank.** Fixed-height rows; selection never jumps on refresh; assign state only when it
   changed; no flicker while syncing; stale async results are discarded.
5. **Buttons are simple.** A flat filled primary action, quiet secondary actions. No capsule buttons
   with an icon plus a count badge.
6. Text, cursor and placeholder must align exactly in inputs (a macOS bug was fixed by using a
   vertical TextField instead of a text editor with an overlay).
7. Light and dark are both first-class and must switch live, completely, together. Apply the
   appearance at application level, never per view.
8. Accent colour is user-selectable (8 presets) and used sparingly: selection, primary actions,
   focus, the local-branch chip.
9. Content scrolls horizontally when it must (diff lines); never silently clip.

## Layout

- Frameless window, floating rounded panels (radius 16) on a soft backdrop (translucent material in
  dark, near-opaque soft canvas in light), 8 pt draggable gaps between columns.
- Left to right: repo rail → sidebar (branches/tags/stashes) → history/changes list → detail/diff.
- Panels: surface colour, 1 px border at ~11% primary, subtle shadow.
- Rows: radius 10, hover = 5.5% primary, selected = accent at 16%.
- Pills/segmented controls and search fields are capsule-shaped; sheets use rounded 10 pt fields on a
  6% primary fill.
- Typography: system font; titles semibold rounded; small caps-like section labels (10.5 pt,
  semibold, letter-spaced, secondary colour).

## Colours

- Status: added green, modified orange, deleted red, renamed blue, untracked teal, conflicted pink.
- Graph lanes: 8 fixed hues (see `Theme.laneColors`), cycling by lane index.
- Avatars: stable hue from a hash of the email (use a deterministic hash, never a randomised one).
- Provider tiles: GitHub near-black (white tile in dark mode), GitLab orange, Bitbucket blue, Gitea
  green, Azure blue; logos in white.

## Testing visually (macOS)

A DEBUG-only hook renders the window to a PNG: `GITWOLF_SNAPSHOT=/path.png`, with
`GITWOLF_APPEARANCE=dark|light`, `GITWOLF_SNAPSHOT_WINDOW=settings|sheet:<menu title>`,
`GITWOLF_SHEET=clone|create|account`. Other platforms should offer something equivalent so UI work
can be checked without manual clicking.

## Brand artwork

The logo is vector only: `assets/gitwolf-mark.svg` (white wolf, transparent) and `assets/gitwolf-icon.svg` (the mark on the
`#012AA5` tile). Prefer the SVG everywhere; do not add PNG copies. macOS draws the app icon from the mark
(`apple/Scripts/make-icon.swift`) and embeds both files as vectors for the dashboard, the menu-bar item and development
builds (`apple/Scripts/embed-brand.py` regenerates `BrandArt.swift` after the artwork changes). Flat colour only, no gradients,
no shadows.
