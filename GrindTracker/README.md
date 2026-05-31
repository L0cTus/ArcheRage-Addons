# GrindTracker

A lightweight, no-fuss farming / grinding session tracker.

Start a session, kill mobs, and watch the live stats roll in. Everything is
in-memory only — there's nothing to configure and nothing is saved between
sessions except your window positions.

## Features

- **Live session stats:** Time, Kills, XP, Gold, and total Items, each with a per-hour rate
- **Abbreviated numbers** (`32.4k`, `1.7M`, `5g/h`) so the panel stays compact at any scale
- **Loot window** with all looted items grouped by name, sorted most-looted first
- **Drag to position** — both windows; remembers position and open/closed state per character
- **ESC menu integration** under *Shop / Quality of Life* → *Grind Tracker*
- **Start / Pause / Reset** controls — fully manual, nothing auto-starts

## Notes

- **Kills** are counted on each XP tick (one tick = one kill while grinding). This is the
  closest signal available in the addon API. At max level XP is 0 and the Kills counter
  will stay at 0 — everything else still works.
- **Gold** counts every positive change to your wallet, so vendor sales during a session
  are included. For a pure-loot tracker, vendor before you start.
- **Items** counts everything entering your inventory during an active session, including
  crafted items and mail pickups if those happen mid-grind.