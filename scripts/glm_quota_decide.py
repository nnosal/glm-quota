#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""GLM quota pause/resume decision engine.

Reads the cached Z.ai quota response, applies peak-hour and threshold
rules, and writes a decision file consumed by the PreToolUse guard hook.
"""

import json
import os
import sys
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

CACHE_DIR = "/tmp/.glm-quota-cache"
QUOTA_CACHE_FILE = os.path.join(CACHE_DIR, "quota.json")
STATE_FILE = os.path.join(CACHE_DIR, "pause-state.json")

PAUSE_THRESHOLD = 95.0
BEIJING_TZ = ZoneInfo("Asia/Shanghai") if ZoneInfo else timezone(timedelta(hours=8))
PEAK_START_HOUR = 14
PEAK_END_HOUR = 18


def is_glm_mode():
    # GLM_QUOTA_ACTIVE is the sole activation gate — set only where Claude Code
    # is launched against Z.ai (e.g. the mise/shell task's env block). This
    # avoids false positives from a stale ANTHROPIC_BASE_URL left over in the
    # shell environment from an unrelated session.
    if os.environ.get("GLM_QUOTA_ACTIVE") != "1":
        return False
    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    return "api.z.ai" in base_url or "bigmodel.cn" in base_url


def load_quota_cache():
    try:
        with open(QUOTA_CACHE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def local_tz():
    tz_name = os.environ.get("GLM_QUOTA_TZ", "Europe/Paris")
    if ZoneInfo:
        try:
            return ZoneInfo(tz_name)
        except Exception:
            return ZoneInfo("Europe/Paris")
    return timezone.utc


def next_off_peak_start(now_utc):
    """First instant >= now_utc that falls outside the 14:00-18:00 Beijing peak window."""
    now_beijing = now_utc.astimezone(BEIJING_TZ)
    peak_start_today = now_beijing.replace(
        hour=PEAK_START_HOUR, minute=0, second=0, microsecond=0
    )
    peak_end_today = now_beijing.replace(
        hour=PEAK_END_HOUR, minute=0, second=0, microsecond=0
    )

    if peak_start_today <= now_beijing < peak_end_today:
        return peak_end_today.astimezone(timezone.utc)
    return now_utc


def parse_reset_time(ms_epoch):
    if not ms_epoch:
        return None
    try:
        return datetime.fromtimestamp(float(ms_epoch) / 1000.0, tz=timezone.utc)
    except (ValueError, OSError):
        return None


def extract_limits(data):
    """Return (pct_5h, reset_5h, pct_7d, reset_7d) from the Z.ai quota payload."""
    limits = (data or {}).get("data", {}).get("limits", [])
    pct_5h = reset_5h = pct_7d = reset_7d = None
    seen_tokens_limit = False
    for entry in limits:
        if entry.get("type") == "TOKENS_LIMIT":
            pct = entry.get("percentage", 0) or 0
            reset = parse_reset_time(entry.get("nextResetTime"))
            if not seen_tokens_limit:
                pct_5h, reset_5h = pct, reset
                seen_tokens_limit = True
            else:
                pct_7d, reset_7d = pct, reset
    return pct_5h, reset_5h, pct_7d, reset_7d


def write_state(decision, reason, resume_at_utc, now_utc):
    tz = local_tz()
    state = {
        "decision": decision,
        "reason": reason,
        "generated_at_utc": now_utc.isoformat(),
    }
    if resume_at_utc:
        state["resume_at_utc"] = resume_at_utc.isoformat()
        state["resume_at_local"] = resume_at_utc.astimezone(tz).strftime(
            "%Y-%m-%d %H:%M %Z"
        )
        state["resume_in_seconds"] = max(
            0, int((resume_at_utc - now_utc).total_seconds())
        )
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp_path = STATE_FILE + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp_path, STATE_FILE)
    return state


def decide(now_utc=None):
    now_utc = now_utc or datetime.now(timezone.utc)

    if not is_glm_mode():
        return write_state("CONTINUE", "Not in GLM mode", None, now_utc)

    data = load_quota_cache()
    if data is None:
        return write_state("CONTINUE", "No quota data cached yet", None, now_utc)

    pct_5h, reset_5h, pct_7d, reset_7d = extract_limits(data)

    if pct_7d is not None and pct_7d >= PAUSE_THRESHOLD:
        resume_at = reset_7d or (now_utc + timedelta(days=1))
        reason = (
            f"7-day window at {pct_7d:.0f}% (>= {PAUSE_THRESHOLD:.0f}%). "
            "Stopping until the 7-day window resets, regardless of the 5h window."
        )
        return write_state("STOP", reason, resume_at, now_utc)

    if pct_5h is not None and pct_5h >= PAUSE_THRESHOLD:
        candidate = reset_5h or (now_utc + timedelta(hours=5))
        resume_at = next_off_peak_start(candidate)
        reason = (
            f"5h window at {pct_5h:.0f}% (>= {PAUSE_THRESHOLD:.0f}%). "
            "Pausing until the 5h window resets and we're outside GLM peak hours "
            "(14:00-18:00 Beijing time)."
        )
        return write_state("PAUSE", reason, resume_at, now_utc)

    return write_state(
        "CONTINUE",
        f"5h={pct_5h if pct_5h is not None else 'n/a'}%, "
        f"7d={pct_7d if pct_7d is not None else 'n/a'}% — within budget",
        None,
        now_utc,
    )


def main():
    state = decide()
    print(json.dumps(state, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
