# -*- coding: utf-8 -*-
"""应用市场业务层：投稿、审核、列表、详情、评论、评分、收藏、举报。"""
import json
import time
import uuid
import urllib.parse

from common import row_dict, user_mini, check_sensitive
from app_market.util import (
    normalize_payload, PACKAGE_TYPES, PLATFORMS, PUBLIC_PROVIDERS,
    LOGIN_REQUIRED, detect_provider,
)
from app_market.behavior import record_app_behavior

APP_STATUS = {0: "草稿", 1: "待审核", 2: "已上架", 3: "已拒绝", 4: "已下架"}
VER_STATUS = {0: "草稿", 1: "待审核", 2: "已通过", 3: "已拒绝"}
STATUS_TEXT = {0: "待审核", 1: "已通过", 2: "已拒绝", 3: "已下架"}


def _now():
    return time.time()


def _json_list(v):
    try:
        x = json.loads(v or "[]")
        return x if isinstance(x, list) else []
    except Exception:
        return []


def _cat(c, cid):
    row = c.execute("SELECT id,name,slug,parent_id FROM community_app_categories WHERE id=? AND active=1",
                    (cid,)).fetchone()
    return row_dict(row) if row else {}


def category_tree(c):
    rows = [row_dict(r) for r in c.execute(
        "SELECT id,parent_id,name,slug,sort FROM community_app_categories"
        " WHERE active=1 ORDER BY sort ASC, created ASC").fetchall()]
    children = {}
    for r in rows:
        children.setdefault(r["parent_id"] or "", []).append(r)
    def build(pid):
        out = []
        for r in children.get(pid, []):
            out.append({"id": r["id"], "name": r["name"], "slug": r["slug"],
                        "parentId": r["parent_id"] or "", "sort": r["sort"] or 0,
                        "children": build(r["id"])})
        return out
    return build("")


def _validate_category(c, cat_id, sub_id):
    major = c.execute("SELECT id,parent_id FROM community_app_categories WHERE id=? AND active=1",
                      (cat_id,)).fetchone()
    sub = c.execute("SELECT id,parent_id FROM community_app_categories WHERE id=? AND active=1",
                    (sub_id,)).fetchone()
    if not major or (major[1] or ""):
        return "应用大类不存在"
    if not sub or (sub[1] or "") != cat_id:
        return "子分类必须属于所选大类"
    return ""


def _app_row(c, app_id):
    return c.execute("SELECT * FROM community_apps WHERE id=?", (app_id,)).fetchone()


def _version_row(c, app_id, version_id=None):
    if version_id:
        return c.execute("SELECT * FROM community_app_versions WHERE id=? AND app_id=?",
                         (version_id, app_id)).fetchone()
    return c.execute("SELECT * FROM community_app_versions WHERE app_id=? ORDER BY created DESC LIMIT 1",
                     (app_id,)).fetchone()


def _public_version(c, app_row):
    vid = (app_row["current_version_id"] or "").strip()
    if vid:
        v = c.execute("SELECT * FROM community_app_versions WHERE id=? AND app_id=? AND status=2",
                      (vid, app_row["id"])).fetchone()
        if v:
            return v
    # current_version_id 尚未回填时，兼容取最新已通过版本
    return c.execute("SELECT * FROM community_app_versions WHERE app_id=? AND status=2"
                     " ORDER BY approved_at DESC, created DESC LIMIT 1",
                     (app_row["id"],)).fetchone()


def _public_item(c, app_row, viewer_uid=None, detail=False):
    v = _public_version(c, app_row)
    if not v:
        return None
    major = _cat(c, app_row["category_id"])
    sub = _cat(c, app_row["subcategory_id"])
    avg = round((app_row["rating_sum"] or 0) / (app_row["rating_count"] or 1), 2) \
        if (app_row["rating_count"] or 0) else 0
    out = {
        "id": app_row["id"],
        "name": app_row["name"],
        "icon": app_row["icon"] or "",
        "platform": app_row["platform"],
        "packageType": app_row["package_type"],
        "packageName": app_row["package_name"],
        "version": v["version_name"],
        "osVersion": v["os_version"] or "",
        "categoryId": app_row["category_id"],
        "subCategoryId": app_row["subcategory_id"],
        "category": major.get("name", ""),
        "subCategory": sub.get("name", ""),
        "description": app_row["description"] or "",
        "shareReason": app_row["share_reason"] or "",
        "downloadCount": app_row["download_count"] or 0,
        "rating": avg,
        "ratingCount": app_row["rating_count"] or 0,
        "favoriteCount": app_row["favorite_count"] or 0,
        "commentCount": app_row["comment_count"] or 0,
        "featured": bool(app_row["featured"]),
        "publishedAt": app_row["published_at"] or 0,
        "downloadUrl": "/community/api/apps/%s/download" % app_row["id"],
        "storeUrl": (v["download_url"] or "")
        if (app_row["package_type"] or "").lower() == "store" else "",
        "author": user_mini(c, app_row["submitter_id"]),
    }
    if detail:
        out["screenshots"] = _json_list(v["screenshots"])
        out["versionId"] = v["id"]
        if viewer_uid:
            r = c.execute("SELECT score FROM community_app_ratings WHERE user_id=? AND app_id=?",
                          (viewer_uid, app_row["id"])).fetchone()
            out["myRating"] = r[0] if r else 0
            out["favorited"] = bool(c.execute(
                "SELECT 1 FROM community_app_favorites WHERE user_id=? AND app_id=?",
                (viewer_uid, app_row["id"])).fetchone())
        else:
            out["myRating"] = 0
            out["favorited"] = False
    return out


def _mine_item(c, app_row):
    v = _version_row(c, app_row["id"], app_row["current_version_id"] or None)
    out = {
        "id": app_row["id"], "name": app_row["name"], "icon": app_row["icon"],
        "platform": app_row["platform"], "packageType": app_row["package_type"],
        "packageName": app_row["package_name"],
        "status": app_row["status"], "statusText": APP_STATUS.get(app_row["status"], ""),
        "created": app_row["created"], "updated": app_row["updated"],
        "categoryId": app_row["category_id"], "subCategoryId": app_row["subcategory_id"],
        "description": app_row["description"], "shareReason": app_row["share_reason"],
        "downloadCount": app_row["download_count"] or 0,
    }
    if v:
        out.update({
            "versionId": v["id"], "version": v["version_name"],
            "osVersion": v["os_version"] or "",
            "downloadUrl": v["download_url"],
            "storeUrl": (v["download_url"] or "")
            if (app_row["package_type"] or "").lower() == "store" else "",
            "screenshots": _json_list(v["screenshots"]),
            "auditStatus": v["status"], "auditStatusText": VER_STATUS.get(v["status"], ""),
            "rejectReason": v["reject_reason"] or "",
        })
    return out


def _version_item(v):
    d = row_dict(v)
    d["screenshots"] = _json_list(d.get("screenshots"))
    d["statusText"] = VER_STATUS.get(d.get("status"), "")
    return d


def _admin_item(c, app_row):
    v = _version_row(c, app_row["id"], app_row["current_version_id"] or None)
    out = {
        "id": app_row["id"], "name": app_row["name"], "icon": app_row["icon"],
        "platform": app_row["platform"], "packageType": app_row["package_type"],
        "packageName": app_row["package_name"],
        "categoryId": app_row["category_id"], "subCategoryId": app_row["subcategory_id"],
        "category": _cat(c, app_row["category_id"]).get("name", ""),
        "subCategory": _cat(c, app_row["subcategory_id"]).get("name", ""),
        "description": app_row["description"], "shareReason": app_row["share_reason"],
        "status": app_row["status"], "statusText": APP_STATUS.get(app_row["status"], ""),
        "featured": bool(app_row["featured"]), "downloadCount": app_row["download_count"] or 0,
        "rating": round((app_row["rating_sum"] or 0) / (app_row["rating_count"] or 1), 2)
        if (app_row["rating_count"] or 0) else 0,
        "ratingCount": app_row["rating_count"] or 0,
        "favoriteCount": app_row["favorite_count"] or 0,
        "commentCount": app_row["comment_count"] or 0,
        "currentVersionId": app_row["current_version_id"] or "",
        "created": app_row["created"], "updated": app_row["updated"],
        "author": user_mini(c, app_row["submitter_id"]),
    }
    if v:
        out["version"] = _version_item(v)
    return out


# ---------------- 投稿 / 版本 ----------------
def create_app(c, uid, body):
    data, err = normalize_payload(c, uid, body)
    if err:
        return None, err
    err = _validate_category(c, data["category_id"], data["subcategory_id"])
    if err:
        return None, err
    dup = c.execute("SELECT id,submitter_id,status FROM community_apps"
                    " WHERE platform=? AND package_name=?",
                    (data["platform"], data["package_name"])).fetchone()
    if dup:
        if dup[1] == uid:
            return None, "该包名已存在投稿（应用 ID：%s），请在我的投稿中编辑或追加版本" % dup[0]
        return None, "该包名已被其他用户投稿"
    now = _now()
    aid = uuid.uuid4().hex
    vid = uuid.uuid4().hex
    c.execute(
        "INSERT INTO community_apps(id,submitter_id,name,icon,platform,package_type,"
        "package_name,category_id,subcategory_id,description,share_reason,status,"
        "featured,download_count,view_count,rating_count,rating_sum,favorite_count,"
        "comment_count,current_version_id,created,updated,published_at)"
        " VALUES(?,?,?,?,?,?,?,?,?,?,?,1,0,0,0,0,0,0,0,?,?,?,0)",
        (aid, uid, data["name"], data["icon"], data["platform"], data["package_type"],
         data["package_name"], data["category_id"], data["subcategory_id"],
         data["description"], data["share_reason"], vid, now, now))
    c.execute(
        "INSERT INTO community_app_versions(id,app_id,version_name,os_version,download_url,"
        "provider,share_code,screenshots,status,reject_reason,created)"
        " VALUES(?,?,?,?,?,?,?,?,1,'',?)",
        (vid, aid, data["version_name"], data["os_version"], data["download_url"],
         data["provider"], data["share_code"], json.dumps(data["screenshots"], ensure_ascii=False), now))
    c.commit()
    return {"id": aid, "versionId": vid, "status": 1}, None


def _merge_app_version(c, app_row, body):
    """更新应用时允许同时更新当前版本字段。"""
    merged = {
        "name": body.get("name", app_row["name"]),
        "icon": body.get("icon", app_row["icon"]),
        "platform": body.get("platform", app_row["platform"]),
        "packageType": body.get("packageType", body.get("package_type", app_row["package_type"])),
        "packageName": body.get("packageName", body.get("package_name", app_row["package_name"])),
        "categoryId": body.get("categoryId", body.get("category_id", app_row["category_id"])),
        "subcategoryId": body.get("subcategoryId", body.get("subcategory_id", app_row["subcategory_id"])),
        "description": body.get("description", app_row["description"]),
        "shareReason": body.get("shareReason", body.get("share_reason", app_row["share_reason"])),
    }
    v = _version_row(c, app_row["id"], app_row["current_version_id"] or None)
    if v:
        merged.update({
            "downloadUrl": body.get("downloadUrl", body.get("download_url", v["download_url"])),
            "versionName": body.get("versionName", body.get("version", v["version_name"])),
            "osVersion": body.get("osVersion", body.get("os_version", v["os_version"])),
            "shareCode": body.get("shareCode", body.get("share_code", v["share_code"])),
        })
        if "screenshots" not in body:
            merged["screenshots"] = _json_list(v["screenshots"])
        else:
            merged["screenshots"] = body.get("screenshots")
    return merged


def update_app(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    if row["submitter_id"] != uid:
        return None, "只能修改自己的投稿"
    if row["status"] not in (0, 3):
        return None, "已提交审核或已上架的应用不能直接改资料"
    merged = _merge_app_version(c, row, body)
    data, err = normalize_payload(c, uid, merged)
    if err:
        return None, err
    err = _validate_category(c, data["category_id"], data["subcategory_id"])
    if err:
        return None, err
    dup = c.execute("SELECT id FROM community_apps WHERE platform=? AND package_name=? AND id<>?",
                    (data["platform"], data["package_name"], app_id)).fetchone()
    if dup:
        return None, "该包名已被其他应用占用"
    v = _version_row(c, app_id, row["current_version_id"] or None)
    if not v:
        return None, "投稿版本不存在"
    now = _now()
    c.execute(
        "UPDATE community_apps SET name=?,icon=?,platform=?,package_type=?,package_name=?,"
        "category_id=?,subcategory_id=?,description=?,share_reason=?,status=0,updated=?"
        " WHERE id=?",
        (data["name"], data["icon"], data["platform"], data["package_type"], data["package_name"],
         data["category_id"], data["subcategory_id"], data["description"], data["share_reason"],
         now, app_id))
    c.execute(
        "UPDATE community_app_versions SET version_name=?,os_version=?,download_url=?,provider=?,"
        "share_code=?,screenshots=?,status=0,reject_reason='',updated=?"
        " WHERE id=?",
        (data["version_name"], data["os_version"], data["download_url"], data["provider"],
         data["share_code"], json.dumps(data["screenshots"], ensure_ascii=False), now, v["id"]))
    c.commit()
    return {"id": app_id, "versionId": v["id"]}, None


def submit_app(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    if row["submitter_id"] != uid:
        return None, "只能提交自己的投稿"
    if row["status"] not in (0, 3):
        return None, "当前状态不能提交审核"
    v = _version_row(c, app_id, body.get("versionId") or row["current_version_id"] or None)
    if not v:
        return None, "投稿版本不存在"
    data, err = normalize_payload(c, uid, _merge_app_version(c, row, {}))
    if err:
        return None, err
    now = _now()
    c.execute("UPDATE community_apps SET status=1,updated=? WHERE id=?", (now, app_id))
    c.execute("UPDATE community_app_versions SET status=1,reject_reason='',updated=? WHERE id=?",
              (now, v["id"]))
    c.commit()
    return {"id": app_id, "versionId": v["id"], "status": 1}, None


def create_version(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    if row["submitter_id"] != uid:
        return None, "只能给自己的应用追加版本"
    if row["status"] != 2:
        return None, "只有已上架应用才能追加版本"
    merged = _merge_app_version(c, row, body)
    data, err = normalize_payload(c, uid, merged)
    if err:
        return None, err
    v = _version_row(c, app_id, row["current_version_id"] or None)
    if not v:
        return None, "当前版本不存在"
    dup = c.execute("SELECT 1 FROM community_app_versions WHERE app_id=? AND version_name=?",
                    (app_id, data["version_name"])).fetchone()
    if dup:
        return None, "该版本号已存在，请填写新的版本号"
    vid = uuid.uuid4().hex
    now = _now()
    c.execute(
        "INSERT INTO community_app_versions(id,app_id,version_name,os_version,download_url,"
        "provider,share_code,screenshots,status,reject_reason,created)"
        " VALUES(?,?,?,?,?,?,?,?,1,'',?)",
        (vid, app_id, data["version_name"], data["os_version"], data["download_url"],
         data["provider"], data["share_code"], json.dumps(data["screenshots"], ensure_ascii=False), now))
    c.execute("UPDATE community_apps SET updated=? WHERE id=?", (now, app_id))
    c.commit()
    return {"id": app_id, "versionId": vid, "status": 1}, None


def update_version(c, uid, app_id, version_id, body):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    if row["submitter_id"] != uid:
        return None, "只能修改自己的版本"
    v = _version_row(c, app_id, version_id)
    if not v:
        return None, "版本不存在"
    if v["status"] not in (0, 3):
        return None, "当前版本状态不能修改"
    merged = _merge_app_version(c, row, body)
    merged.update({
        "downloadUrl": body.get("downloadUrl", body.get("download_url", v["download_url"])),
        "versionName": body.get("versionName", body.get("version", v["version_name"])),
        "osVersion": body.get("osVersion", body.get("os_version", v["os_version"])),
        "shareCode": body.get("shareCode", body.get("share_code", v["share_code"])),
        "screenshots": body.get("screenshots", _json_list(v["screenshots"])),
    })
    data, err = normalize_payload(c, uid, merged)
    if err:
        return None, err
    dup = c.execute("SELECT 1 FROM community_app_versions WHERE app_id=? AND version_name=?"
                    " AND id<>?", (app_id, data["version_name"], v["id"])).fetchone()
    if dup:
        return None, "该版本号已存在，请填写新的版本号"
    now = _now()
    c.execute("UPDATE community_app_versions SET version_name=?,os_version=?,download_url=?,provider=?,"
              "share_code=?,screenshots=?,status=0,reject_reason='',updated=? WHERE id=?",
              (data["version_name"], data["os_version"], data["download_url"], data["provider"],
               data["share_code"], json.dumps(data["screenshots"], ensure_ascii=False), now, v["id"]))
    if row["status"] != 2:
        c.execute("UPDATE community_apps SET status=0,updated=? WHERE id=?", (now, app_id))
    else:
        c.execute("UPDATE community_apps SET updated=? WHERE id=?", (now, app_id))
    c.commit()
    return {"id": app_id, "versionId": v["id"]}, None


def submit_version(c, uid, app_id, version_id, body):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    if row["submitter_id"] != uid:
        return None, "只能提交自己的版本"
    v = _version_row(c, app_id, version_id)
    if not v:
        return None, "版本不存在"
    if v["status"] not in (0, 3):
        return None, "当前版本状态不能提交"
    data, err = normalize_payload(c, uid, _merge_app_version(c, row, {}))
    if err:
        return None, err
    now = _now()
    c.execute("UPDATE community_app_versions SET status=1,reject_reason='',updated=? WHERE id=?",
              (now, v["id"]))
    # 新版本待审时不能把已上架应用藏起来
    if row["status"] != 2:
        c.execute("UPDATE community_apps SET status=1,updated=? WHERE id=?", (now, app_id))
    c.commit()
    return {"id": app_id, "versionId": v["id"], "status": 1}, None


# ---------------- 公开列表 / 详情 ----------------
def list_apps(c, query, viewer_uid=None):
    q = {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(query).items()}
    page = max(1, int(q.get("page") or 1))
    size = min(50, max(1, int(q.get("pageSize") or 20)))
    where = ["a.status=2", "v.status=2"]
    args = []
    cat = q.get("category") or q.get("categoryId")
    if cat:
        # 支持 slug 或 ID
        row = c.execute("SELECT id FROM community_app_categories WHERE id=? OR slug=?",
                        (cat, cat)).fetchone()
        if row:
            where.append("a.category_id=?")
            args.append(row[0])
    sub = q.get("subCategory") or q.get("subCategoryId")
    if sub:
        row = c.execute("SELECT id FROM community_app_categories WHERE id=? OR slug=?",
                        (sub, sub)).fetchone()
        if row:
            where.append("a.subcategory_id=?")
            args.append(row[0])
    platform = q.get("platform")
    if platform:
        where.append("a.platform=?")
        args.append(platform)
    kw = (q.get("q") or "").strip()
    if kw:
        where.append("(a.name LIKE ? OR a.package_name LIKE ? OR a.description LIKE ?)")
        args += ["%" + kw + "%"] * 3
    sort = q.get("sort") or "latest"
    if sort in ("recommend", "for_you"):
        from app_market.personalized import build_app_recommendations, remember_app_pushed
        exclude = [x for x in (q.get("exclude") or "").split(",") if x][:100]
        fresh = (q.get("fresh") or "").strip() in ("1", "true", "yes")
        items, has_more, personalized, pushed = build_app_recommendations(
            c, viewer_uid, size=size, category=cat or "", sub=sub or "",
            platform=platform or "", q=kw, exclude=exclude, fresh=fresh)
        if viewer_uid and page == 1:
            remember_app_pushed(c, viewer_uid, pushed)
        total = c.execute(
            "SELECT COUNT(*) FROM community_apps a JOIN community_app_versions v"
            " ON v.id=a.current_version_id WHERE " + " AND ".join(where), args).fetchone()[0]
        c.commit()
        return {"list": items, "page": 1, "pageSize": size, "total": total,
                "hasMore": has_more, "personalized": personalized, "fresh": fresh}
    order = "a.download_count DESC, a.created DESC" if sort == "hot" else "a.published_at DESC, a.created DESC"
    rows = c.execute(
        "SELECT a.* FROM community_apps a JOIN community_app_versions v"
        " ON v.id=a.current_version_id WHERE " + " AND ".join(where) +
        " ORDER BY " + order + " LIMIT ? OFFSET ?",
        args + [size, (page - 1) * size]).fetchall()
    items = []
    for r in rows:
        item = _public_item(c, r, viewer_uid, detail=False)
        if item:
            item["description"] = item["description"][:120]
            items.append(item)
    total = c.execute(
        "SELECT COUNT(*) FROM community_apps a JOIN community_app_versions v"
        " ON v.id=a.current_version_id WHERE " + " AND ".join(where), args).fetchone()[0]
    c.commit()
    return {"list": items, "page": page, "pageSize": size, "total": total}


def get_detail(c, app_id, viewer_uid=None):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    item = _public_item(c, row, viewer_uid, detail=True)
    if not item:
        return None, "应用版本不可用"
    c.execute("UPDATE community_apps SET view_count=view_count+1 WHERE id=?", (app_id,))
    record_app_behavior(c, viewer_uid, app_id, "view")
    c.commit()
    return item, None


def list_mine(c, uid):
    rows = c.execute("SELECT * FROM community_apps WHERE submitter_id=? ORDER BY updated DESC",
                     (uid,)).fetchall()
    return {"list": [_mine_item(c, r) for r in rows]}


def list_user_apps(c, uid, viewer_uid=None, page=1, page_size=12):
    """公开用户主页的应用投稿：只返回已上架且当前版本可用的应用。"""
    page = max(1, int(page or 1))
    size = min(50, max(1, int(page_size or 12)))
    where = "a.submitter_id=? AND a.status=2 AND v.status=2"
    args = [uid]
    rows = c.execute(
        "SELECT a.* FROM community_apps a JOIN community_app_versions v"
        " ON v.id=a.current_version_id WHERE " + where +
        " ORDER BY a.published_at DESC, a.created DESC LIMIT ? OFFSET ?",
        args + [size, (page - 1) * size]).fetchall()
    items = []
    for r in rows:
        item = _public_item(c, r, viewer_uid, detail=False)
        if item:
            item["description"] = item["description"][:120]
            items.append(item)
    total = c.execute(
        "SELECT COUNT(*) FROM community_apps a JOIN community_app_versions v"
        " ON v.id=a.current_version_id WHERE " + where, args).fetchone()[0]
    c.commit()
    return {"list": items, "page": page, "pageSize": size, "total": total}


def list_favorites(c, uid):
    rows = c.execute(
        "SELECT a.* FROM community_app_favorites f JOIN community_apps a ON a.id=f.app_id"
        " WHERE f.user_id=? AND a.status=2 ORDER BY f.created DESC", (uid,)).fetchall()
    out = []
    for r in rows:
        item = _public_item(c, r, uid)
        if item:
            out.append(item)
    return {"list": out}


# ---------------- 评论 / 评分 / 收藏 / 举报 ----------------
def list_comments(c, app_id, query):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    q = {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(query).items()}
    page = max(1, int(q.get("page") or 1))
    size = min(50, max(1, int(q.get("pageSize") or 20)))
    rows = c.execute("SELECT * FROM community_app_comments WHERE app_id=? AND status=1"
                     " ORDER BY created DESC LIMIT ? OFFSET ?",
                     (app_id, size, (page - 1) * size)).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        d["author"] = user_mini(c, d["user_id"])
        out.append(d)
    total = c.execute("SELECT COUNT(*) FROM community_app_comments WHERE app_id=? AND status=1",
                      (app_id,)).fetchone()[0]
    c.commit()
    return {"list": out, "total": total, "page": page, "pageSize": size}, None


def add_comment(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    content = str(body.get("content") or "").strip()
    if not content or len(content) > 600:
        return None, "评论需为 1–600 字"
    hits = [h["word"] for h in check_sensitive(c, content) if h["level"] == 0]
    if hits:
        return None, "评论包含敏感词：" + "、".join(hits[:5])
    parent_id = str(body.get("parentId") or "").strip()
    if parent_id:
        p = c.execute("SELECT 1 FROM community_app_comments WHERE id=? AND app_id=? AND status=1",
                     (parent_id, app_id)).fetchone()
        if not p:
            return None, "回复的评论不存在"
    now = _now()
    cid = uuid.uuid4().hex
    c.execute("INSERT INTO community_app_comments(id,app_id,user_id,parent_id,content,status,created)"
              " VALUES(?,?,?,?,?,1,?)",
              (cid, app_id, uid, parent_id, content, now))
    c.execute("UPDATE community_apps SET comment_count=comment_count+1 WHERE id=?", (app_id,))
    record_app_behavior(c, uid, app_id, "comment")
    c.commit()
    return {"id": cid, "created": now}, None


def delete_comment(c, uid, app_id, comment_id):
    row = c.execute("SELECT * FROM community_app_comments WHERE id=? AND app_id=?",
                    (comment_id, app_id)).fetchone()
    if not row:
        return None, "评论不存在"
    if row["user_id"] != uid:
        return None, "只能删除自己的评论"
    if row["status"] != 1:
        return {"id": comment_id}, None
    c.execute("UPDATE community_app_comments SET status=0 WHERE id=?", (comment_id,))
    c.execute("UPDATE community_apps SET comment_count=CASE WHEN comment_count>0"
              " THEN comment_count-1 ELSE 0 END WHERE id=?", (app_id,))
    c.commit()
    return {"id": comment_id}, None


def set_rating(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    try:
        score = int(body.get("score") or 0)
    except Exception:
        score = 0
    if score < 1 or score > 5:
        return None, "评分必须为 1–5"
    now = _now()
    old = c.execute("SELECT score FROM community_app_ratings WHERE user_id=? AND app_id=?",
                    (uid, app_id)).fetchone()
    if old:
        c.execute("UPDATE community_app_ratings SET score=?,updated=? WHERE user_id=? AND app_id=?",
                  (score, now, uid, app_id))
        c.execute("UPDATE community_apps SET rating_sum=rating_sum+? WHERE id=?",
                  (score - old[0], app_id))
    else:
        c.execute("INSERT INTO community_app_ratings(user_id,app_id,score,created,updated)"
                  " VALUES(?,?,?,?,?)", (uid, app_id, score, now, now))
        c.execute("UPDATE community_apps SET rating_count=rating_count+1,"
                  "rating_sum=rating_sum+? WHERE id=?", (score, app_id))
    record_app_behavior(c, uid, app_id, "rating")
    c.commit()
    avg = round((c.execute("SELECT rating_sum,rating_count FROM community_apps WHERE id=?",
                           (app_id,)).fetchone()[0] or 0) /
                max(1, c.execute("SELECT rating_count FROM community_apps WHERE id=?",
                                 (app_id,)).fetchone()[0]), 2)
    return {"score": score, "rating": avg}, None


def toggle_favorite(c, uid, app_id, add=True):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    existing = c.execute("SELECT 1 FROM community_app_favorites WHERE user_id=? AND app_id=?",
                         (uid, app_id)).fetchone()
    if add and not existing:
        c.execute("INSERT INTO community_app_favorites(user_id,app_id,created) VALUES(?,?,?)",
                  (uid, app_id, _now()))
        c.execute("UPDATE community_apps SET favorite_count=favorite_count+1 WHERE id=?", (app_id,))
    elif not add and existing:
        c.execute("DELETE FROM community_app_favorites WHERE user_id=? AND app_id=?", (uid, app_id))
        c.execute("UPDATE community_apps SET favorite_count=CASE WHEN favorite_count>0"
                  " THEN favorite_count-1 ELSE 0 END WHERE id=?", (app_id,))
        record_app_behavior(c, uid, app_id, "unfav")
    if add and not existing:
        record_app_behavior(c, uid, app_id, "fav")
    c.commit()
    fav = c.execute("SELECT favorite_count FROM community_apps WHERE id=?", (app_id,)).fetchone()[0]
    return {"favorited": bool(add), "favoriteCount": fav}, None


def add_report(c, uid, app_id, body):
    row = _app_row(c, app_id)
    if not row or row["status"] != 2:
        return None, "应用不存在或未上架"
    reason = str(body.get("reason") or "").strip()
    if len(reason) < 2 or len(reason) > 200:
        return None, "举报原因需为 2–200 字"
    c.execute("INSERT INTO community_reports(id,target_type,target_id,user_id,reason,status,created)"
              " VALUES(?,?,?,?,?,0,?)",
              (uuid.uuid4().hex, "app", app_id, uid, reason, _now()))
    c.commit()
    return {"ok": True}, None


# ---------------- 管理端 ----------------
def admin_list(c, query):
    q = {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(query).items()}
    page = max(1, int(q.get("page") or 1))
    size = min(50, max(1, int(q.get("pageSize") or 20)))
    status = q.get("status")
    where = []
    args = []
    if status not in (None, "", "all"):
        try:
            where.append("a.status=?")
            args.append(int(status))
        except Exception:
            pass
    kw = (q.get("q") or "").strip()
    if kw:
        where.append("(a.name LIKE ? OR a.package_name LIKE ?)")
        args += ["%" + kw + "%"] * 2
    base = "SELECT a.* FROM community_apps a"
    if where:
        base += " WHERE " + " AND ".join(where)
    rows = c.execute(base + " ORDER BY a.created DESC LIMIT ? OFFSET ?",
                     args + [size, (page - 1) * size]).fetchall()
    total = c.execute("SELECT COUNT(*) FROM community_apps a" +
                      (" WHERE " + " AND ".join(where) if where else ""), args).fetchone()[0]
    c.commit()
    return {"list": [_admin_item(c, r) for r in rows], "total": total, "page": page, "pageSize": size}


def admin_detail(c, app_id):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    out = _admin_item(c, row)
    versions = c.execute("SELECT * FROM community_app_versions WHERE app_id=? ORDER BY created DESC",
                         (app_id,)).fetchall()
    out["versions"] = [_version_item(v) for v in versions]
    c.commit()
    return out, None


def review(c, app_id, version_id, action, reason, admin_token):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    v = _version_row(c, app_id, version_id)
    if not v:
        return None, "版本不存在"
    if v["status"] != 1:
        return None, "该版本已被处理，不能重复审核"
    action = (action or "").strip()
    if action not in ("approve", "reject"):
        return None, "审核动作只能是 approve/reject"
    reason = str(reason or "").strip()[:300]
    if action == "reject" and not reason:
        return None, "拒绝必须填写原因"
    now = _now()
    if action == "approve":
        changed = c.execute("UPDATE community_app_versions SET status=2,reject_reason='',approved_at=?"
                            " WHERE id=? AND status=1", (now, v["id"])).rowcount
        if not changed:
            c.rollback()
            return None, "该版本已被其他管理员处理"
        c.execute("UPDATE community_apps SET status=2,current_version_id=?,"
                  "published_at=CASE WHEN published_at>0 THEN published_at ELSE ? END,updated=?"
                  " WHERE id=?", (v["id"], now, now, app_id))
        result = "approved"
    else:
        changed = c.execute("UPDATE community_app_versions SET status=3,reject_reason=?,updated=?"
                            " WHERE id=? AND status=1", (reason, now, v["id"])).rowcount
        if not changed:
            c.rollback()
            return None, "该版本已被其他管理员处理"
        approved = c.execute("SELECT id FROM community_app_versions WHERE app_id=? AND status=2"
                             " ORDER BY approved_at DESC LIMIT 1", (app_id,)).fetchone()
        if approved:
            c.execute("UPDATE community_apps SET status=2,current_version_id=?,updated=? WHERE id=?",
                      (approved[0], now, app_id))
        else:
            c.execute("UPDATE community_apps SET status=3,updated=? WHERE id=?", (now, app_id))
        result = "rejected"
    c.commit()
    return {"appId": app_id, "versionId": v["id"], "action": result,
            "appStatus": _app_row(c, app_id)["status"]}, None


def set_app_state(c, app_id, action, admin_token):
    row = _app_row(c, app_id)
    if not row:
        return None, "应用不存在"
    now = _now()
    if action == "offline":
        c.execute("UPDATE community_apps SET status=4,updated=? WHERE id=?", (now, app_id))
    elif action == "restore":
        approved = c.execute("SELECT id FROM community_app_versions WHERE app_id=? AND status=2"
                             " ORDER BY approved_at DESC LIMIT 1", (app_id,)).fetchone()
        if not approved:
            return None, "没有已通过的版本，不能恢复"
        c.execute("UPDATE community_apps SET status=2,current_version_id=?,updated=? WHERE id=?",
                  (approved[0], now, app_id))
    elif action == "feature":
        c.execute("UPDATE community_apps SET featured=?,updated=? WHERE id=?",
                  (0 if row["featured"] else 1, now, app_id))
    else:
        return None, "未知操作"
    c.commit()
    return {"id": app_id, "status": _app_row(c, app_id)["status"],
            "featured": bool(_app_row(c, app_id)["featured"])}, None


def admin_categories(c):
    return {"list": category_tree(c)}


def admin_category_create(c, body):
    name = str(body.get("name") or "").strip()[:40]
    parent = str(body.get("parentId") or "").strip()
    if not name:
        return None, "分类名必填"
    if parent:
        row = c.execute("SELECT 1 FROM community_app_categories WHERE id=? AND (parent_id='' OR parent_id IS NULL)",
                        (parent,)).fetchone()
        if not row:
            return None, "父分类必须是有效大类"
    slug = str(body.get("slug") or "").strip()[:64]
    if not slug:
        slug = "cat-" + uuid.uuid4().hex[:10]
    try:
        c.execute("INSERT INTO community_app_categories(id,parent_id,name,slug,sort,active,created)"
                  " VALUES(?,?,?,?,?,1,?)",
                  (uuid.uuid4().hex, parent, name, slug, int(body.get("sort") or 0), _now()))
        c.commit()
        return {"ok": True}, None
    except Exception as e:
        return None, "分类创建失败：%s" % e


def admin_category_update(c, cid, body):
    row = c.execute("SELECT * FROM community_app_categories WHERE id=?", (cid,)).fetchone()
    if not row:
        return None, "分类不存在"
    sets, args = [], []
    for key, col in (("name", "name"), ("parentId", "parent_id"), ("slug", "slug"),
                     ("sort", "sort"), ("active", "active")):
        if key in body:
            v = body.get(key)
            if key == "active":
                v = 1 if v else 0
            elif key == "sort":
                v = int(v or 0)
            else:
                v = str(v or "").strip()[:64]
            sets.append(col + "=?")
            args.append(v)
    if sets:
        c.execute("UPDATE community_app_categories SET " + ",".join(sets) + " WHERE id=?",
                  args + [cid])
        c.commit()
    return {"ok": True}, None


def admin_category_delete(c, cid):
    row = c.execute("SELECT parent_id FROM community_app_categories WHERE id=?", (cid,)).fetchone()
    if not row:
        return None, "分类不存在"
    if not (row[0] or ""):
        if c.execute("SELECT 1 FROM community_app_categories WHERE parent_id=?", (cid,)).fetchone():
            return None, "请先删除子分类"
    if c.execute("SELECT 1 FROM community_apps WHERE category_id=? OR subcategory_id=?",
                 (cid, cid)).fetchone():
        return None, "仍有应用使用该分类，不能删除"
    c.execute("DELETE FROM community_app_categories WHERE id=?", (cid,))
    c.commit()
    return {"ok": True}, None


def admin_comments(c, query):
    q = {k: (v[0] if v else "") for k, v in urllib.parse.parse_qs(query).items()}
    page = max(1, int(q.get("page") or 1))
    size = min(50, max(1, int(q.get("pageSize") or 20)))
    app_id = (q.get("appId") or "").strip()
    where = ["status=1"]
    args = []
    if app_id:
        where.append("app_id=?")
        args.append(app_id)
    rows = c.execute("SELECT * FROM community_app_comments WHERE " + " AND ".join(where) +
                     " ORDER BY created DESC LIMIT ? OFFSET ?",
                     args + [size, (page - 1) * size]).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        d["author"] = user_mini(c, d["user_id"])
        out.append(d)
    c.commit()
    return {"list": out, "page": page, "pageSize": size}


def admin_comment_state(c, comment_id, action):
    row = c.execute("SELECT * FROM community_app_comments WHERE id=?", (comment_id,)).fetchone()
    if not row:
        return None, "评论不存在"
    if action not in ("hide", "show"):
        return None, "未知操作"
    new_status = 0 if action == "hide" else 1
    if row["status"] != new_status:
        c.execute("UPDATE community_app_comments SET status=? WHERE id=?", (new_status, comment_id))
        delta = -1 if new_status == 0 else 1
        c.execute("UPDATE community_apps SET comment_count=CASE WHEN comment_count+?>0"
                  " THEN comment_count+? ELSE 0 END WHERE id=?", (delta, delta, row["app_id"]))
    c.commit()
    return {"id": comment_id, "status": new_status}, None


def admin_app_reports(c, status=0):
    rows = c.execute("SELECT * FROM community_reports WHERE target_type='app' AND status=?"
                     " ORDER BY created DESC LIMIT 100", (status,)).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        app = _app_row(c, d["target_id"])
        d["target"] = {"type": "app", "name": app["name"] if app else "已删除应用",
                       "packageName": app["package_name"] if app else ""}
        out.append(d)
    c.commit()
    return {"list": out}
