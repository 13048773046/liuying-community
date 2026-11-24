# -*- coding: utf-8 -*-
"""流小萤 · 自主发布排期。

不是固定 cron，也不是固定间隔：每次尝试发布后，由模型结合当前时间、
当天已发数量、内容池和最近动作，自行决定下一次什么时候发。
模型不可用时用带随机抖动的兜底，不会退回固定间隔。
"""
import datetime as _dt
import json
import random
import time

import ai_bot_core as CORE

KINDS = ("post", "video", "app")
LABEL = {"post": "帖子", "video": "短视频", "app": "应用"}
CAP_KEY = {"post": "max_posts_per_day", "video": "max_videos_per_day",
           "app": "max_apps_per_day"}
COUNT_KINDS = {
    "post": ["post.pending", "post.published", "post.auto"],
    "video": ["video.pending", "video.published", "video.auto"],
    "app": ["app.pending", "app.published", "app.auto"],
}
LAST_KEY = {"post": "last_post", "video": "last_video", "app": "last_app"}

# 只约束「不要一分钟连发」和「不要拖到用户以为坏了」，不参与固定排期。
MIN_GAP_MIN = {"post": 35, "video": 75, "app": 180}
MAX_GAP_MIN = {"post": 720, "video": 1080, "app": 2160}
START_GAP_MIN = {"post": 12, "video": 25, "app": 45}
RETRY_GAP_MIN = {"post": 35, "video": 60, "app": 40}


def _now():
    return time.time()


def _plan_key(kind):
    return "publish_plan_" + kind


def get_plan(kind):
    p = CORE.state_get(_plan_key(kind), None)
    return p if isinstance(p, dict) else {}


def set_plan(kind, plan):
    CORE.state_set(_plan_key(kind), plan)
    return plan


def clear_plan(kind):
    CORE.state_set(_plan_key(kind), {})


def _today_start():
    now = _dt.datetime.now()
    return now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def _today_count(kind):
    c = CORE.db()
    try:
        since = _today_start()
        kinds = COUNT_KINDS.get(kind) or []
        q = " OR ".join(["kind=?" for _ in kinds])
        row = c.execute(
            "SELECT COUNT(DISTINCT CASE WHEN target_id<>'' THEN target_id ELSE id END)"
            " FROM ai_bot_actions WHERE (" + q + ") "
            "AND status IN ('done','pending_review') AND created>=?",
            kinds + [since]).fetchone()
        return int(row[0] or 0)
    finally:
        c.close()


def _today_success(kind):
    """只统计已经成功提交的，失败重试不算当天配额。"""
    c = CORE.db()
    try:
        since = _today_start()
        if kind == "post":
            sql = ("SELECT COUNT(DISTINCT target_id) FROM ai_bot_actions WHERE kind IN "
                   "('post.pending','post.published') AND status IN ('done','pending_review')"
                   " AND created>=?")
        elif kind == "video":
            sql = ("SELECT COUNT(DISTINCT target_id) FROM ai_bot_actions WHERE kind IN "
                   "('video.pending','video.published') AND status IN ('done','pending_review')"
                   " AND created>=?")
        else:
            sql = ("SELECT COUNT(DISTINCT target_id) FROM ai_bot_actions WHERE kind IN "
                   "('app.pending','app.published') AND status IN ('done','pending_review')"
                   " AND created>=?")
        return int(c.execute(sql, (since,)).fetchone()[0] or 0)
    finally:
        c.close()


def _recent_actions(kind, limit=8):
    c = CORE.db()
    try:
        rows = c.execute(
            "SELECT kind,status,detail,result,created FROM ai_bot_actions "
            "WHERE kind LIKE ? ORDER BY created DESC LIMIT ?",
            (kind.split(".")[0] + "%", limit)).fetchall()
        return [dict(zip(("kind", "status", "detail", "result", "created"), r)) for r in rows]
    finally:
        c.close()


def _clock(ts):
    return _dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def _parse_delay(text):
    """模型可能返回纯 JSON，也可能带 ```json 包裹。"""
    raw = str(text or "").strip()
    if not raw:
        return None
    if "```" in raw:
        raw = raw.replace("```json", "```").split("```")[1] if len(raw.split("```")) > 2 else raw
    try:
        obj = json.loads(raw)
    except Exception:
        m = __import__("re").search(r"\{.*\}", raw, __import__("re").S)
        if not m:
            return None
        try:
            obj = json.loads(m.group(0))
        except Exception:
            obj = None
    if not isinstance(obj, dict):
        # 模型偶尔在 max_tokens 边界截断；只要 delayMinutes 已完整，就先采用。
        m2 = __import__("re").search(r'"delayMinutes"\s*:\s*(\d+)', raw)
        return int(m2.group(1)) if m2 else None
    try:
        minutes = int(obj.get("delayMinutes", obj.get("delay_minutes", 0)))
    except Exception:
        return None
    return minutes


def _fallback(kind, outcome):
    if outcome == "startup":
        lo, hi = 3, START_GAP_MIN.get(kind, 30)
    elif outcome == "failed":
        lo, hi = 12, RETRY_GAP_MIN.get(kind, 45)
    elif outcome == "capped":
        # 今天配额用完了，明天零点后再随机 20–90 分钟，避免每个整点都发。
        tomorrow = _dt.datetime.now().replace(hour=0, minute=0, second=0,
                                             microsecond=0) + _dt.timedelta(days=1)
        delay = max(1, int((tomorrow.timestamp() - _now()) / 60) + random.randint(20, 90))
        return delay, "今天这类内容已经发到上限，明天再看"
    else:
        lo, hi = 25, MAX_GAP_MIN.get(kind, 600)
    return random.randint(lo, hi), "自主排期"


def _stagger(kind, next_at, reason):
    """避免帖子/视频/应用撞在同一分钟；给其他类型让出一点空间。"""
    for other in KINDS:
        if other == kind:
            continue
        plan = get_plan(other)
        other_at = float(plan.get("nextAt") or 0)
        if other_at and abs(other_at - next_at) < 20 * 60:
            next_at += random.randint(12, 30) * 60
            reason = (reason + "，错开" + LABEL.get(other, other)).strip("，")
    return next_at, reason


def next_plan(kind, outcome="success", detail=""):
    """让模型选下一次发布时间，并写入 ai_bot_config。"""
    p = CORE.get_policy()
    cap = max(1, int(p.get(CAP_KEY.get(kind, "")) or 1))
    done = _today_success(kind)
    if done >= cap:
        delay, reason = _fallback(kind, "capped")
        next_at, reason = _stagger(kind, _now() + delay * 60, reason)
        plan = {
            "kind": kind, "nextAt": next_at, "delayMinutes": int((next_at - _now()) / 60),
            "reason": reason, "source": "cap",
            "createdAt": _now(), "lastResult": str(detail or "")[:200],
        }
        set_plan(kind, plan)
        CORE.action_log("schedule.next", kind, "排期：" + reason, "done",
                        _clock(plan["nextAt"]) + " 下一次", dedupe_key=None)
        return plan

    now = _now()
    last = float(CORE.state_get(LAST_KEY.get(kind, ""), 0) or 0)
    recent = _recent_actions(kind, 6)
    fallback_delay, fallback_reason = _fallback(kind, outcome)
    if not p.get("auto_schedule", True):
        # 保留旧模式的固定间隔，但只在明确关掉自主排期时启用。
        iv = int(p.get({"post": "post_interval", "video": "video_interval",
                        "app": "app_interval"}.get(kind, "post_interval")) or 0)
        delay = max(30, iv // 60)
        plan = {"kind": kind, "nextAt": now + delay * 60, "delayMinutes": delay,
                "reason": "固定间隔（自主排期已关闭）", "source": "fixed",
                "createdAt": now, "lastResult": str(detail or "")[:200]}
        set_plan(kind, plan)
        return plan

    try:
        import ai_bot_media as MEDIA
        target = int(p.get("max_posts_per_day" if kind == "post" else
                           "max_videos_per_day" if kind == "video" else
                           "max_apps_per_day") or 0)
        prompt = (
            "你是流萤社区 AI 账号「流小萤」的发布排期器。你要自己决定下一次发布"
            "%s的时间，不要按固定间隔，也不要每个整点都发。\n"
            "现在是北京时间 %s。今天已经成功提交 %d 条，日上限 %d 条。\n"
            "最近动作：%s\n"
            "上次结果：%s\n"
            "可选间隔范围：%d–%d 分钟。请结合内容节奏和人的作息，选一个自然的时刻；"
            "深夜可以拉长，白天可以短一些，但不要连续轰炸。\n"
            "只输出 JSON：{\"delayMinutes\":整数,\"reason\":\"20字以内的中文理由\"}"
        ) % (LABEL.get(kind, kind), _clock(now), done, target,
             json.dumps(recent, ensure_ascii=False)[:1200], detail[:300],
             MIN_GAP_MIN.get(kind, 30), MAX_GAP_MIN.get(kind, 600))
        out = MEDIA.llm_text("你是发布节奏的决策者，只输出 JSON。", prompt,
                             max_tokens=520, temperature=0.55)
        minutes = _parse_delay(out)
        if minutes is not None:
            lo = MIN_GAP_MIN.get(kind, 30)
            hi = MAX_GAP_MIN.get(kind, 600)
            minutes = max(lo, min(hi, minutes))
            raw_reason = ""
            try:
                m = __import__("re").search(r'"reason"\s*:\s*"([^"]*)"', str(out))
                raw_reason = m.group(1) if m else ""
            except Exception:
                raw_reason = ""
            delay = minutes
            reason = (raw_reason or "模型选定的发布时刻").strip()[:40]
            source = "ai"
        else:
            delay, reason, source = fallback_delay, fallback_reason, "fallback"
    except Exception as e:
        delay, reason, source = fallback_delay, fallback_reason, "fallback"
        detail = (str(detail or "") + " / 排期模型不可用:" + str(e)[:90])[:300]

    next_at, reason = _stagger(kind, _now() + delay * 60, reason)
    plan = {
        "kind": kind, "nextAt": next_at, "delayMinutes": int((next_at - _now()) / 60),
        "reason": reason, "source": source, "createdAt": _now(),
        "lastResult": str(detail or "")[:200],
    }
    set_plan(kind, plan)
    CORE.action_log("schedule.next", kind, "排期：" + reason, "done",
                    _clock(plan["nextAt"]) + " 下一次", dedupe_key=None)
    return plan


def ensure_plan(kind):
    plan = get_plan(kind)
    if plan.get("nextAt"):
        return plan
    return next_plan(kind, "startup", "首次自主排期")


def ensure_all():
    for k in KINDS:
        ensure_plan(k)


def is_due(kind):
    p = CORE.get_policy()
    if not p.get("enabled") or not p.get("auto_publish"):
        return False
    plan = ensure_plan(kind)
    return float(plan.get("nextAt") or 0) <= _now()


def after_run(kind, result, manual=False):
    """一次尝试结束后，无论成败都重新让 AI 排下一次。"""
    result = result if isinstance(result, dict) else {"ok": False, "reason": str(result)[:200]}
    ok = bool(result.get("ok"))
    detail = ("成功：" if ok else "失败：") + str(result.get("reason") or result.get("postId")
                                               or result.get("appId") or "已提交")[:180]
    CORE.state_set(LAST_KEY.get(kind, ""), _now())
    p = CORE.get_policy()
    if not p.get("auto_schedule", True):
        # 固定模式也用 after_run 更新时间戳；nextAt 仍用于后台展示。
        return next_plan(kind, "success" if ok else "failed", detail)
    return next_plan(kind, "success" if ok else "failed", detail)


def describe():
    out = {}
    for k in KINDS:
        plan = get_plan(k)
        out[k] = {
            "nextAt": plan.get("nextAt") or 0,
            "nextText": _clock(plan.get("nextAt")) if plan.get("nextAt") else "",
            "reason": plan.get("reason") or "",
            "source": plan.get("source") or "",
            "lastResult": plan.get("lastResult") or "",
            "today": _today_success(k),
            "cap": int(CORE.get_policy().get(CAP_KEY.get(k, "")) or 0),
        }
    return out
