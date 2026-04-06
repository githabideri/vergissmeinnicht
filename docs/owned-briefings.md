# Owned Briefings

vergissmeinnicht now includes a generic script for room-owned daily briefings:

- `scripts/owned-briefing.sh`

The script is designed to stay **repo-native and reusable** while keeping
machine-/deployment-specific values outside the repo in `config.env` (gitignored)
or exported environment variables.

## Why

Different operational domains may need their own briefing:
- planning/general
- labmaster / llmlab-control
- schreiber
- heimsucher

The reusable part is the orchestration pattern and archive/send behavior.
The deployment-specific part is:
- which agent owns the briefing
- which room it is sent to
- where the archive is stored
- what sources/focus text should be used

## Required config

Set these in `config.env` before calling `scripts/owned-briefing.sh`:

- `BRIEFING_AGENT`
- `BRIEFING_ROOM_ID`
- `BRIEFING_SCOPE_LABEL`
- `BRIEFING_ARCHIVE_DIR`
- `BRIEFING_FOCUS`

Optional:
- `BRIEFING_EXTRA_SOURCES`
- `BRIEFING_STYLE`
- `BRIEFING_DELIVERY_INSTRUCTION`
- `BRIEFING_TIMEOUT`

## Archive rule

Every owned briefing should be archived as markdown before being sent.
This keeps it referenceable by agents later.

Examples:
- planning → `workspace/memory/briefings/YYYY-MM-DD.md`
- labmaster → `workspace/agents/labmaster/memory/briefings/YYYY-MM-DD.md`
- schreiber → `workspace/agents/schreiber/memory/briefings/YYYY-MM-DD.md`
- heimsucher → `workspace/agents/heimsucher/memory/briefings/YYYY-MM-DD.md`

## Delivery rule

Prefer sending briefings as the owning main agent rather than via servicebot,
because servicebot-triggered reactions may be globally sticky in some setups.
