"""Claude subscription-only evidence. Keep the Go evaluator/wire vectors aligned.

Weekly percentages gate eligibility; they never become five-hour work units.
This module performs no network, credential or configuration reads.
"""
import hashlib
import json
import math
import re
from datetime import datetime


def epoch(value):
    try:
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
            return 0
        if value[-1] != "Z" and (int(value[-5:-3]) > 23 or int(value[-2:]) > 59):
            return 0
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def family(model):
    for name in ("sonnet", "opus", "haiku"):
        if any(model.startswith(p + name + "-") for p in ("claude-", "claude-3-", "claude-3-5-", "claude-3-7-")):
            return name
    return ""


def evaluate(e, model, now, reservations=0):
    out = dict(e, model=model, state="unknown", reason="missing_windows", capacity_status="baseline_unknown",
               weekly_capacity="unknown", reservations=reservations)
    def reason(state, why):
        out.update(state=state, reason=why)
        return out
    if e.get("ineligible_reason"):
        return reason("ineligible", e["ineligible_reason"])
    if e.get("paused") or not e.get("refresh_healthy"):
        return reason("ineligible", "paused_or_refresh_unhealthy")
    if e.get("limited"):
        return reason("limited", "429_cooldown")
    fam = family(model)
    valid = (e.get("complete") or e.get("observed_model") == model and bool(model)) and not e.get("read_failed") and bool(fam)
    if not fam:
        out["reason"] = "unknown_model_pool"
    elif e.get("read_failed"):
        out["reason"] = "read_failed"
    elif not e.get("complete") and e.get("observed_model") != model:
        out["reason"] = "incomplete_account_observation"
    full = five = weekly = False
    seen = set()
    five_remaining = weekly_remaining = five_reset = 0
    for w in e.get("windows", []):
        scope = w.get("model", "")
        if scope and not w.get("unknown_scope") and scope not in (model, "family:" + fam):
            continue
        if w.get("unknown_scope"):
            valid = False
            out["reason"] = "unknown_model_scope"
            out.setdefault("issues", []).append(out["reason"])
            continue
        key = (scope, w.get("id"))
        minutes = w.get("minutes")
        general = not scope
        five |= general and key[1] == "five_hour" and minutes == 300
        weekly |= general and key[1] == "seven_day" and minutes == 10080
        used, at, reset = w.get("used_percent"), epoch(w.get("observed_at")), epoch(w.get("reset_at"))
        pct_ok = number(used) and 0 <= used <= 100
        if pct_ok and used == 100 and 0 < at <= now and (not reset or reset > now):
            full = True
        why = ""
        if key in seen:
            why = "duplicate_window"
        elif general and (key[1], minutes) not in (("five_hour", 300), ("seven_day", 10080)) or minutes not in (300, 10080):
            why = "unexpected_window"
        elif not pct_ok:
            why = "invalid_percentage"
        elif not at or at > now:
            why = "invalid_observation"
        elif not reset:
            why = "missing_reset"
        elif reset <= now:
            why = "awaiting_reset_reading"
        elif reset > at + minutes * 60:
            why = "reset_outside_window"
        elif now - at > 600:
            why = "stale_window"
        seen.add(key)
        if why:
            valid = False
            out["reason"] = why
            out.setdefault("issues", []).append(why)
            continue
        if general and key[1] == "five_hour":
            five_remaining, five_reset = 100 - used, reset
        if general and key[1] == "seven_day":
            weekly_remaining = out["weekly_remaining_percent"] = 100 - used
    if full:
        return reason("limited", "blocked_or_full_window")
    if not five or not weekly:
        out["reason"] = "missing_dual_window"
        return out
    if not valid:
        return out
    reason("tight" if min(five_remaining, weekly_remaining) < 20 else "usable", "all_applicable_windows_valid")
    p = e.get("profile")
    if not p or e.get("metadata_status") != "valid":
        out["capacity_status"] = e.get("metadata_status") or "baseline_unknown"
        if out["capacity_status"] == "valid":
            out["capacity_status"] = "baseline_unknown"
        return out
    status = ""
    if p.get("plan") != e.get("plan") or p.get("tier") != e.get("tier") or p.get("pool") != "claude":
        status = "profile_mismatch"
    elif p.get("confidence") not in ("verified", "provisional") or not all(p.get(k) for k in ("source", "unit", "basis")):
        status = "baseline_unverified"
    elif not epoch(p.get("effective_from")) or now < epoch(p.get("effective_from")) or p.get("effective_to") and now >= epoch(p["effective_to"]):
        status = "baseline_outside_effective_period"
    elif not number(p.get("five_hour_units")) or p["five_hour_units"] <= 0:
        status = "invalid_baseline"
    if status:
        out["capacity_status"] = status
        return out
    units = p["five_hour_units"] * five_remaining / 100
    horizon = max(.05, min(1, (five_reset - now) / 18000))
    out.update(estimated_five_hour_units=units, score=units * (1 + .25 * (1 - horizon)) / (1 + max(0, reservations)),
               capacity_status="five_hour_only_estimate")
    if number(p.get("weekly_units")) and p["weekly_units"] > 0:
        out.update(estimated_weekly_units=p["weekly_units"] * weekly_remaining / 100, weekly_capacity="separately_evidenced")
    return out


def eligible(q):
    return q.get("state") in ("usable", "tight")


def comparable(a, b):
    return all(number(q.get("score")) and q.get("profile") for q in (a, b)) and all(a["profile"].get(k) == b["profile"].get(k) for k in ("pool", "unit", "basis"))


def choose(rows, current, since, now, pin="", independent=True):
    old = next((q for q in rows if q["account"] == (pin or current)), None)
    if pin:
        return (old if old and eligible(old) else None), "explicit_binding"
    valid = [q for q in rows if eligible(q)]
    if not valid:
        return None, "no_observed_eligible_subscription"
    own = next((q["owner"] for q in valid if q["owner"] != "pool"), valid[0]["owner"])
    cohort = [q for q in valid if q["owner"] == own]
    comp = all(comparable(cohort[0], q) for q in cohort)
    cohort.sort(key=lambda q: (-q["score"] if comp else 0, -q.get("weekly_remaining_percent", 0), q["account"]))
    pick = cohort[0]
    if old and eligible(old):
        if not independent:
            return old, "continuation_binding"
        if now - since < 600:
            return old, "minimum_hold"
        if old["owner"] == pick["owner"]:
            if not comp or not comparable(old, pick):
                return old, "incomparable_keep"
            if pick["score"] <= old["score"] * 1.25:
                return old, "no_material_gain"
    return pick, "five_hour_capacity" if comp else "conservative_weekly_fraction"


def reference(kind, value):
    return hashlib.sha256(("fleet-claude-affinity-v1\0" + kind + "\0" + value).encode()).hexdigest()


def unique(pairs):
    obj = {}
    for k, v in pairs:
        if k in obj:
            raise ValueError("duplicate JSON key")
        obj[k] = v
    return obj


def route(method, path, headers, body):
    out = {"model": "", "independent": False, "references": [], "unknown": False}
    refs = set()
    try:
        if method != "POST" or path.split("?")[0] != "/v1/messages" or "?" in path and path.split("?", 1)[1] != "beta=true" or headers.get("content-encoding"):
            raise ValueError("unsupported path")
        root = json.loads(body, object_pairs_hook=unique)
        if not isinstance(root, dict):
            raise ValueError("invalid body")
        out["model"] = root.get("model", "")
        if not isinstance(out["model"], str):
            out["model"] = ""
        allowed = set("model messages system max_tokens tools tool_choice stream temperature top_p top_k stop_sequences metadata thinking output_config context_management".split())
        if set(root) - allowed or root.get("context_management") not in (None, {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}):
            out["unknown"] = True
        def add(kind, value):
            if not isinstance(value, str) or not value:
                out["unknown"] = True
            else:
                refs.add(reference(kind, value))
        def content(value):
            if isinstance(value, str):
                return
            if not isinstance(value, list):
                out["unknown"] = True
                return
            for p in value:
                if not isinstance(p, dict):
                    out["unknown"] = True
                    continue
                typ = p.get("type")
                keys = ""
                if typ == "text":
                    keys = "type text cache_control citations"
                    if p.get("citations") is not None and p["citations"] != []:
                        out["unknown"] = True
                elif typ == "thinking":
                    keys = "type thinking signature"
                    add("signature", p.get("signature"))
                elif typ == "redacted_thinking":
                    keys = "type data"
                    add("redacted", p.get("data"))
                elif typ == "tool_use":
                    keys = "type id name input cache_control"
                    add("tool", p.get("id"))
                elif typ == "tool_result":
                    keys = "type tool_use_id content is_error cache_control"
                    add("tool", p.get("tool_use_id"))
                    if p.get("content") is not None:
                        content(p["content"])
                elif typ == "image":
                    keys = "type source cache_control"
                    if not isinstance(p.get("source"), dict) or p["source"].get("type") != "base64":
                        out["unknown"] = True
                else:
                    out["unknown"] = True
                if set(p) - set(keys.split()):
                    out["unknown"] = True
        msgs = root.get("messages")
        if not isinstance(msgs, list) or not msgs:
            raise ValueError("missing messages")
        for m in msgs:
            if not isinstance(m, dict):
                raise ValueError("invalid message")
            if m.get("role") not in ("user", "assistant") or set(m) - {"role", "content"}:
                out["unknown"] = True
            content(m.get("content"))
        if root.get("system") is not None:
            content(root["system"])
        if "tools" in root:
            if not isinstance(root["tools"], list) or any(not isinstance(t, dict) or t.get("type") not in (None, "custom") or set(t) - set("type name description input_schema cache_control defer_loading eager_input_streaming input_examples strict".split()) for t in root["tools"]):
                out["unknown"] = True
    except (ValueError, TypeError, RecursionError):
        out["unknown"] = True
    if len(refs) > 4096:
        out["unknown"] = True
        refs.clear()
    out["references"] = sorted(refs)
    out["independent"] = not out["unknown"] and not refs
    return out


class Recorder:
    def __init__(self, record):
        self.record, self.signatures = record, {}

    def event(self, v):
        refs = []
        def block(p):
            kind, field = {"tool_use": ("tool", "id"), "thinking": ("signature", "signature"), "redacted_thinking": ("redacted", "data")}.get(p.get("type"), ("", ""))
            if kind and isinstance(p.get(field), str) and p[field]:
                refs.append(reference(kind, p[field]))
        for p in v.get("content", []):
            if isinstance(p, dict):
                block(p)
        idx = v.get("index", 0)
        p = v.get("content_block")
        if isinstance(p, dict):
            block(p)
            if p.get("type") == "thinking":
                self.signatures[idx] = p.get("signature", "")
        d = v.get("delta", {})
        if d.get("type") == "signature_delta":
            s = self.signatures.get(idx, "") + d["signature"]
            if len(s) > 8 * 1024 * 1024:
                raise ValueError("signature too large")
            self.signatures[idx] = s
        if v.get("type") == "content_block_stop":
            s = self.signatures.pop(idx, "")
            if s:
                refs.append(reference("signature", s))
        if refs:
            self.record(refs)


def response_chunks(response, content_type, record):
    """Bounded JSON/SSE, byte preserving; commit source before frame delivery."""
    cap = 8 * 1024 * 1024
    if not content_type.lower().startswith("text/event-stream"):
        raw = response.read(cap + 1)
        if len(raw) > cap:
            raise ValueError("Claude response too large")
        record(json.loads(raw, object_pairs_hook=unique))
        yield raw
        return
    while True:
        frame, data = bytearray(), []
        while True:
            line = response.readline(cap + 1)
            frame.extend(line)
            if len(frame) > cap:
                raise ValueError("Claude event too large")
            bare = line.rstrip(b"\r\n")
            if bare.startswith(b"data:"):
                data.append(bare[5:].lstrip(b" "))
            if not bare or not line:
                break
        if data:
            record(json.loads(b"\n".join(data), object_pairs_hook=unique))
        if frame:
            yield bytes(frame)
        if not line:
            return
