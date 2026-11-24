# -*- coding: utf-8 -*-
"""流小萤 · 后台调度器。

单进程内一个守护线程：私信 5 秒轮询、回关 60 秒扫描；内容发布由 AI 自主排期，互动按策略间隔。
没有外部 systemd/cron 依赖，随社区主进程启动。
"""
import os
import threading
import time
import uuid

import ai_bot_core as CORE
import ai_bot_dm as DM
import ai_bot_content as CONTENT
import ai_bot_schedule as SCHEDULE

_STARTED = False
_LOCK = threading.Lock()
_MY_ID = uuid.uuid4().hex[:10]


def _enabled():
    return os.environ.get("AI_BOT_ENABLED", "1").strip() not in ("0", "false", "no", "off")


def _lease():
    now = time.time()
    cur = CORE.state_get("worker_owner", {}) or {}
    if cur.get("id") and cur.get("id") != _MY_ID and (cur.get("expires") or 0) > now:
        return False
    CORE.state_set("worker_owner", {"id": _MY_ID, "expires": now + 40})
    return True


def _due(key, interval):
    last = float(CORE.state_get("last_" + key, 0) or 0)
    return time.time() - last >= max(30, int(interval or 0))


def _mark(key):
    CORE.state_set("last_" + key, time.time())


def run_kind(kind):
    """给管理端/测试用的同步入口；异常统一写动作日志。"""
    r = CONTENT.run_kind(kind)
    if (kind or "").strip().lower() in SCHEDULE.KINDS:
        try:
            SCHEDULE.after_run(kind, r)
        except Exception as e:
            CORE.action_log("schedule.error", kind, "排期写入失败", "failed", str(e)[:200])
    return r


def run_now(kind):
    """异步触发一次，避免管理接口被素材下载/模型调用阻塞。"""
    def _do():
        try:
            run_kind(kind)
        except Exception as e:
            CORE.action_log("worker.error", kind, "手动任务失败", "failed", str(e)[:300])
    t = threading.Thread(target=_do, daemon=True)
    t.start()
    return {"started": True, "kind": kind}


def _loop():
    CORE.state_set("worker_started_at", time.time())
    while True:
        try:
            if not _enabled():
                time.sleep(10)
                continue
            if not _lease():
                time.sleep(5)
                continue
            p = CORE.get_policy()
            if not p.get("enabled"):
                time.sleep(10)
                continue

            # 私信：每 5 秒
            try:
                DM.process_unread()
            except Exception as e:
                CORE.action_log("dm.error", "", "私信轮询失败", "failed", str(e)[:300])

            # 回关：每 60 秒
            if p.get("auto_followback") and _due("followback", 60):
                try:
                    n = CORE.followback_scan()
                    _mark("followback")
                    if n:
                        CORE.action_log("followback.scan", "", "本轮回关 %d 人" % n, "done")
                except Exception as e:
                    CORE.action_log("followback.error", "", "回关扫描失败", "failed", str(e)[:300])

            # 自动互动：按策略间隔
            if p.get("auto_engage") and _due("engage", p.get("engage_interval", 1200)):
                try:
                    r = CONTENT.engage()
                    _mark("engage")
                    CORE.action_log("engage.run", "", "自动互动", "done", str(r)[:200])
                except Exception as e:
                    CORE.action_log("engage.error", "", "自动互动失败", "failed", str(e)[:300])

            # 自主发布：AI 自己排下一次，不按固定间隔
            if p.get("auto_publish"):
                for kind in SCHEDULE.KINDS:
                    if not SCHEDULE.is_due(kind):
                        continue
                    try:
                        r = run_kind(kind)
                        if not r.get("ok"):
                            CORE.action_log(kind + ".auto", "", "自动" + SCHEDULE.LABEL.get(kind, kind) + "跳过",
                                            "skipped", str(r)[:200])
                    except Exception as e:
                        CORE.action_log(kind + ".error", "", "自动" + SCHEDULE.LABEL.get(kind, kind) + "失败",
                                        "failed", str(e)[:300])
                        try:
                            SCHEDULE.after_run(kind, {"ok": False, "reason": str(e)[:200]})
                        except Exception:
                            pass

            CORE.state_set("worker_heartbeat", time.time())
        except Exception as e:
            try:
                CORE.action_log("worker.error", "", "调度器异常", "failed", str(e)[:300])
            except Exception:
                pass
        time.sleep(5)


def start():
    global _STARTED
    if not _enabled():
        return False
    with _LOCK:
        if _STARTED:
            return True
        # 首次启动时给互动任务一个短缓冲；内容发布交给自主排期，
        # 已有排期会沿用，不会因为重启就把发布时间重置成固定间隔。
        for k, iv in (("followback", 60), ("engage", 1200)):
            if CORE.state_get("last_" + k, None) is None:
                CORE.state_set("last_" + k, time.time())
        SCHEDULE.ensure_all()
        t = threading.Thread(target=_loop, name="ai-bot-worker", daemon=True)
        t.start()
        _STARTED = True
        return True
