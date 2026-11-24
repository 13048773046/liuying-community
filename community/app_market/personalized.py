# -*- coding: utf-8 -*-
"""应用市场个性化推荐。

多路召回 + 画像加权 + 多样性重排，输出带推荐理由：
- 行为分类 / 子分类 / 开发者 / 平台
- 相似用户协同
- 社区精选 / 近期热门 / 新上架 / 随机探索
- 已浏览（7 天）、已下载/收藏的应用不进推荐；3 小时内推过的应用去重
匿名用户退化为精选 / 热门 / 新上架，并标记 personalized=false。
"""
import json
import random
import time
from collections import defaultdict

REC_CAND_LIMIT = 500
REC_WINDOW = 60 * 86400
REC_SEEN_DAYS = 7 * 86400
REC_PUSH_WINDOW = 3 * 3600

W = {
    "behavior_cat": 2.8,
    "behavior_sub": 2.2,
    "behavior_author": 1.6,
    "collab": 1.4,
    "featured": 2.4,
    "hot": 1.0,
    "fresh": 1.1,
    "explore": 0.28,
    "platform": 1.2,
}
EVENT_W = {
    "view": 1.0,
    "download": 5.0,
    "fav": 6.0,
    "unfav": -2.0,
    "rating": 4.0,
    "comment": 4.0,
}
MAX_PER_CAT = 3
MAX_PER_AUTHOR = 2
MAX_PER_ROUTE = 5


def _meta(v):
    try:
        d = json.loads(v or "{}")
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _resolve_cat(c, name):
    if not name:
        return ""
    row = c.execute("SELECT id FROM community_app_categories WHERE id=? OR slug=?",
                    (name, name)).fetchone()
    return row[0] if row else ""


def _candidates(c, category="", sub="", platform="", q=""):
    where = ["a.status=2", "v.status=2"]
    args = []
    cid = _resolve_cat(c, category)
    if cid:
        where.append("a.category_id=?")
        args.append(cid)
    sid = _resolve_cat(c, sub)
    if sid:
        where.append("a.subcategory_id=?")
        args.append(sid)
    if platform:
        where.append("a.platform=?")
        args.append(platform)
    if q:
        where.append("(a.name LIKE ? OR a.package_name LIKE ? OR a.description LIKE ?)")
        args += ["%" + q + "%"] * 3
    base = ("SELECT a.* FROM community_apps a JOIN community_app_versions v"
            " ON v.id=a.current_version_id WHERE " + " AND ".join(where))
    out = {}
    for order, limit in (
            ("a.published_at DESC, a.created DESC", 300),
            ("a.featured DESC, a.published_at DESC, a.created DESC", 150),
            ("a.download_count DESC, a.published_at DESC", 150)):
        for r in c.execute(base + " ORDER BY " + order + " LIMIT ?",
                           args + [min(REC_CAND_LIMIT, limit)]).fetchall():
            out[r["id"]] = r
            if len(out) >= REC_CAND_LIMIT:
                break
        if len(out) >= REC_CAND_LIMIT:
            break
    return list(out.values())


def _profile(c, uid):
    """近 60 天行为画像；返回分类/子类/开发者/平台/应用分数与已看集合。"""
    out = {
        "cat": defaultdict(float), "sub": defaultdict(float),
        "author": defaultdict(float), "platform": defaultdict(float),
        "app": defaultdict(float), "seen": set(), "events": 0,
    }
    if not uid:
        return out
    rows = c.execute(
        "SELECT app_id,event,value,meta,created FROM community_app_behavior_events"
        " WHERE user_id=? AND created>? ORDER BY created DESC LIMIT 800",
        (uid, time.time() - REC_WINDOW)).fetchall()
    out["events"] = len(rows)
    now = time.time()
    for app_id, event, value, meta, created in rows:
        age = max(now - (created or now), 0)
        decay = max(0.2, 1.0 - age / REC_WINDOW * 0.8)
        m = _meta(meta)
        w = EVENT_W.get(event, 0) * float(value or 1.0) * decay
        cat = m.get("categoryId") or ""
        sub = m.get("subCategoryId") or ""
        author = m.get("authorId") or ""
        platform = m.get("platform") or ""
        if cat:
            out["cat"][cat] += w
        if sub:
            out["sub"][sub] += w
        if author:
            out["author"][author] += w
        if platform:
            out["platform"][platform] += w
        out["app"][app_id] += w
        if event in ("download", "fav", "rating"):
            out["seen"].add(app_id)
        elif event == "view" and age <= REC_SEEN_DAYS:
            out["seen"].add(app_id)
    return out


def _collab(c, uid, profile):
    """看过/下载过同一批应用的人，还在下什么。"""
    strong = [aid for aid, score in sorted(profile["app"].items(), key=lambda x: -x[1])
              if score > 2][:20]
    if not strong:
        return {}
    ph = ",".join("?" for _ in strong)
    rows = c.execute(
        "SELECT user_id,COUNT(DISTINCT app_id) FROM community_app_behavior_events"
        " WHERE user_id<>? AND app_id IN (%s) AND created>? AND event IN ('download','fav','rating')"
        " GROUP BY user_id ORDER BY 2 DESC LIMIT 20" % ph,
        [uid] + strong + [time.time() - REC_WINDOW]).fetchall()
    if not rows:
        return {}
    users = [r[0] for r in rows]
    uph = ",".join("?" for _ in users)
    peers = c.execute(
        "SELECT app_id,COUNT(DISTINCT user_id) FROM community_app_behavior_events"
        " WHERE user_id IN (%s) AND event IN ('download','fav','rating') AND created>?"
        " GROUP BY app_id ORDER BY 2 DESC LIMIT 80" % uph,
        users + [time.time() - REC_WINDOW]).fetchall()
    return {r[0]: r[1] for r in peers}


def _reason_map(item):
    cat = item.get("category") or "这个分类"
    sub = item.get("subCategory") or cat
    author = (item.get("author") or {}).get("name") or "这位开发者"
    return {
        "behavior_cat": "因为你常逛「%s」分类" % cat,
        "behavior_sub": "你常看「%s」" % sub,
        "behavior_author": "你常下载「%s」的应用" % author,
        "collab": "和你口味相近的人也在用",
        "featured": "社区精选",
        "hot": "近期热门",
        "fresh": "新上架",
        "explore": "发现新应用",
        "platform": "适合你的平台",
    }


def build_app_recommendations(c, uid, size=20, category="", sub="", platform="",
                              q="", exclude=None, fresh=False):
    """返回 (items, has_more, personalized, pushed_ids)。items 已带 reason。"""
    from app_market.service import _public_item

    size = min(50, max(1, int(size or 20)))
    exclude = set((exclude or [])[:100])
    profile = _profile(c, uid)
    collab = _collab(c, uid, profile) if uid else {}
    rows = _candidates(c, category, sub, platform, q)
    if not rows:
        return [], False, False, []

    cat_rows = c.execute(
        "SELECT id,name,parent_id FROM community_app_categories").fetchall()
    cat_names = {r[0]: r[1] or "" for r in cat_rows}
    author_ids = {r["submitter_id"] for r in rows if r["submitter_id"]}
    authors = {}
    if author_ids:
        ph = ",".join("?" for _ in author_ids)
        authors = {r[0]: r[1] or "这位开发者" for r in c.execute(
            "SELECT id,name FROM users WHERE id IN (%s)" % ph, list(author_ids)).fetchall()}

    cand = {}
    for r in rows:
        aid = r["id"]
        cid = r["category_id"] or ""
        sid = r["subcategory_id"] or ""
        author = r["submitter_id"] or ""
        rating = ((r["rating_sum"] or 0) / (r["rating_count"] or 1)
                  if (r["rating_count"] or 0) else 0)
        cand[aid] = {
            "row": r, "cat": cid, "sub": sid, "author": author,
            "platform": r["platform"] or "", "featured": bool(r["featured"]),
            "download": r["download_count"] or 0, "rating": rating,
            "published": r["published_at"] or 0, "score": 0.0, "routes": {},
            "reasons": {
                "behavior_cat": "因为你常逛「%s」分类" % (cat_names.get(cid) or "这个分类"),
                "behavior_sub": "你常看「%s」" % (cat_names.get(sid) or cat_names.get(cid) or "这个分类"),
                "behavior_author": "你常下载「%s」的应用" % (authors.get(author) or "这位开发者"),
                "collab": "和你口味相近的人也在用",
                "featured": "社区精选",
                "hot": "近期热门",
                "fresh": "新上架",
                "explore": "发现新应用",
                "platform": ("适合你的 iPhone" if (r["platform"] or "") == "ios"
                              else "适合你的 Android" if (r["platform"] or "") == "android"
                              else "适合你的设备"),
            },
        }

    def add(aid, weight, route):
        if aid not in cand or weight <= 0:
            return
        cand[aid]["score"] += weight
        cand[aid]["routes"][route] = cand[aid]["routes"].get(route, 0.0) + weight

    author_counts = defaultdict(int)
    for d in cand.values():
        author_counts[d["author"]] += 1
    # 社区应用多由同一管理员代传时，“作者偏好”并不是真正的开发者偏好，
    # 会把整屏理由变成同一个上传者，因此仅在有真实作者分布时启用。
    author_signal = (len(author_counts) > 1
                     and max(author_counts.values()) <= len(cand) * 0.8)
    max_cat = max([profile["cat"].get(d["cat"], 0) for d in cand.values()] + [1])
    max_sub = max([profile["sub"].get(d["sub"], 0) for d in cand.values()] + [1])
    max_author = max([profile["author"].get(d["author"], 0) for d in cand.values()] + [1])
    max_platform = max([profile["platform"].get(d["platform"], 0) for d in cand.values()] + [1])
    for aid, d in cand.items():
        if profile["cat"].get(d["cat"], 0) > 0:
            add(aid, W["behavior_cat"] * profile["cat"][d["cat"]] / max_cat, "behavior_cat")
        if profile["sub"].get(d["sub"], 0) > 0:
            add(aid, W["behavior_sub"] * profile["sub"][d["sub"]] / max_sub, "behavior_sub")
        if author_signal and profile["author"].get(d["author"], 0) > 0:
            add(aid, W["behavior_author"] * profile["author"][d["author"]] / max_author, "behavior_author")
        if profile["platform"].get(d["platform"], 0) > 0:
            add(aid, W["platform"] * profile["platform"][d["platform"]] / max_platform, "platform")
        if collab.get(aid):
            add(aid, W["collab"] * min(1.0, collab[aid] / 3.0), "collab")
        if d["featured"]:
            add(aid, W["featured"], "featured")

    max_dl = max([d["download"] for d in cand.values()] + [1])
    now = time.time()
    for aid, d in cand.items():
        hot = (d["download"] / max_dl) * 0.7 + (d["rating"] / 5) * 0.3
        if hot > 0.18:
            add(aid, W["hot"] * hot, "hot")
        if d["published"] and now - d["published"] <= 30 * 86400:
            add(aid, W["fresh"], "fresh")

    rng = random.Random("%s-%s" % (uid or "guest", int(now // 3600)))
    for aid, d in cand.items():
        if d["score"] <= 0 or rng.random() < 0.55:
            add(aid, W["explore"] * rng.random(), "explore")
        if fresh:
            d["score"] += rng.random() * 0.6

    pushed = set()
    if uid:
        pushed = {r[0] for r in c.execute(
            "SELECT app_id FROM community_app_recommend_push WHERE uid=? AND pushed_at>?",
            (uid, now - REC_PUSH_WINDOW)).fetchall()}

    cat_values = {d["cat"] for d in cand.values()}
    author_values = {d["author"] for d in cand.values()}
    max_cat = size if len(cat_values) <= 1 else MAX_PER_CAT
    max_author = MAX_PER_AUTHOR
    if len(author_values) <= 1:
        max_author = size
    else:
        top_author = max(sum(1 for d in cand.values() if d["author"] == a)
                         for a in author_values)
        if top_author > len(cand) * 0.8:
            max_author = size

    behavior_keys = ("behavior_cat", "behavior_sub", "behavior_author",
                     "collab", "platform")

    def best_route(d, keys=None):
        routes = [(k, v) for k, v in d["routes"].items()
                  if not keys or k in keys]
        return max(routes, key=lambda kv: kv[1])[0] if routes else None

    def select(allow_seen=False, allow_pushed=False, allow_exclude=True):
        ordered = sorted(cand.items(), key=lambda kv: kv[1]["score"] + rng.random() * 0.05,
                         reverse=True)
        selected, selected_ids = [], set()
        cat_n, author_n = defaultdict(int), defaultdict(int)

        def take(pred, limit, keys=None):
            added = 0
            for aid, d in ordered:
                if len(selected) >= size or added >= limit:
                    break
                if aid in selected_ids:
                    continue
                if allow_exclude and aid in exclude:
                    continue
                if not allow_seen and aid in profile["seen"]:
                    continue
                if not allow_pushed and aid in pushed:
                    continue
                if pred and not pred(d):
                    continue
                if cat_n[d["cat"]] >= max_cat or author_n[d["author"]] >= max_author:
                    continue
                route = best_route(d, keys)
                if route is None:
                    route = "featured" if d["featured"] else "fresh" if "fresh" in d["routes"] else "explore"
                selected.append((aid, d, route))
                selected_ids.add(aid)
                cat_n[d["cat"]] += 1
                author_n[d["author"]] += 1
                added += 1

        personalized_mode = bool(uid and profile["events"] > 0)
        if personalized_mode:
            take(lambda d: best_route(d, behavior_keys) is not None,
                 max(4, int(size * 0.5)), behavior_keys)
            take(lambda d: d["featured"], max(2, int(size * 0.2)), ("featured",))
            take(lambda d: "hot" in d["routes"], max(1, int(size * 0.15)), ("hot",))
            take(lambda d: "fresh" in d["routes"], max(1, int(size * 0.15)), ("fresh",))
        else:
            take(lambda d: d["featured"], max(2, int(size * 0.35)), ("featured",))
            take(lambda d: "hot" in d["routes"], max(2, int(size * 0.3)), ("hot",))
            take(lambda d: "fresh" in d["routes"], max(2, int(size * 0.3)), ("fresh",))
        # 分类/作者上限导致未取满时，按总分补足；不再重复固定推荐路线。
        take(None, size)
        return selected

    chosen = select()
    fallback = False
    if not chosen:
        chosen = select(allow_seen=True, allow_pushed=True)
        fallback = True
    if not chosen and exclude:
        chosen = select(allow_seen=True, allow_pushed=True, allow_exclude=False)
        fallback = True

    items = []
    for aid, d, route in chosen:
        item = _public_item(c, d["row"], uid, detail=False)
        if not item:
            continue
        item["reason"] = d["reasons"].get(route, "发现新应用")
        items.append(item)
    total_eligible = sum(1 for aid in cand if aid not in exclude)
    has_more = (not fallback) and bool(items) and total_eligible > len(items)
    return items, has_more, bool(uid and profile["events"] > 0), [x["id"] for x in items]


def remember_app_pushed(c, uid, app_ids):
    if not uid:
        return
    now = time.time()
    for aid in app_ids:
        c.execute("INSERT OR REPLACE INTO community_app_recommend_push(uid,app_id,pushed_at)"
                  " VALUES(?,?,?)", (uid, aid, now))
