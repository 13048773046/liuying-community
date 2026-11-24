# -*- coding: utf-8 -*-
"""应用市场行为埋点：浏览、下载、收藏、评分、评论。

事件写入不在这里 commit，由调用方与业务写入同一个事务提交；这样即使后续
业务失败，也不会留下一条“用户看过”的脏画像。
"""
import json
import time
import uuid


def _app_meta(c, app_id):
    row = c.execute(
        "SELECT id,name,category_id,subcategory_id,submitter_id,platform,package_type"
        " FROM community_apps WHERE id=?", (app_id,)).fetchone()
    if not row:
        return {}
    return {
        "name": row[1] or "",
        "categoryId": row[2] or "",
        "subCategoryId": row[3] or "",
        "authorId": row[4] or "",
        "platform": row[5] or "",
        "packageType": row[6] or "",
    }


def record_app_behavior(c, uid, app_id, event, value=1.0, meta=None):
    """记录一条应用市场行为。浏览 30 分钟内同一应用只记一次。"""
    if not uid or not app_id:
        return
    now = time.time()
    if event == "view":
        last = c.execute(
            "SELECT 1 FROM community_app_behavior_events"
            " WHERE user_id=? AND app_id=? AND event='view' AND created>?"
            " LIMIT 1", (uid, app_id, now - 1800)).fetchone()
        if last:
            return
    m = meta if isinstance(meta, dict) and meta else _app_meta(c, app_id)
    try:
        meta_text = json.dumps(m, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        meta_text = "{}"
    c.execute(
        "INSERT INTO community_app_behavior_events"
        "(id,user_id,app_id,event,value,meta,created) VALUES(?,?,?,?,?,?,?)",
        (uuid.uuid4().hex, uid, app_id, event, float(value), meta_text, now))
