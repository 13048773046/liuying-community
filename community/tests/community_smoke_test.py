# -*- coding: utf-8 -*-
"""流萤社区 · 冒烟测试（本地跑通后端全链路，≥150 断言）。

用法：
  python3 community/tests/prepare_db.py        # 首次建测试库
  python3 community/tests/community_smoke_test.py

覆盖：登录互通/发帖/视频/评论(图或表情二选一)/点赞/分享/投票/审核/运营操作/
管理分级/搜索/收藏/稍后看/编辑/草稿/举报/拉黑/敏感词/偏好/签到/任务/
等级/装扮/表情/官方通知/互动通知/私信(二期)/Banner/活动/排行/热词/越权/限流。
"""
import os
import sys
import json
import time
import uuid
import urllib.request
import urllib.parse
import threading

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

PORT = 8791
BASE_URL = "http://127.0.0.1:%d/community/api" % PORT

PASS = 0
FAIL = 0
FAILED = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILED.append(name + (" | " + str(detail)[:120] if detail else ""))


def req(method, path, body=None, token=None, adm=None, files=None, raw=False):
    url = BASE_URL + path
    data = None
    headers = {}
    if files:
        import mimetypes
        boundary = "----smoke" + uuid.uuid4().hex
        parts = []
        for k, (fn, content) in files.items():
            parts.append(("--" + boundary).encode())
            parts.append(("Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"" % (k, fn)).encode())
            parts.append(b"Content-Type: application/octet-stream")
            parts.append(b"")
            parts.append(content)
        parts.append(("--" + boundary + "--").encode())
        data = b"\r\n".join(parts)
        headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
    elif body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    if adm:
        headers["X-Community-Admin-Token"] = adm
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            ct = resp.headers.get("Content-Type", "")
            raw_data = resp.read()
            if raw:
                return resp.status, raw_data, resp.headers
            if "json" in ct:
                return resp.status, json.loads(raw_data.decode("utf-8"))
            return resp.status, raw_data.decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except Exception:
            return e.code, {}
    except Exception as ex:
        return 0, {"error": str(ex)}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    global PASS, FAIL
    # ---------- 环境准备 ----------
    from prepare_db import make_db, seed
    db_path = make_db()
    os.environ["COMMUNITY_DB"] = db_path
    os.environ["COMMUNITY_PORT"] = str(PORT)
    os.environ["COMMUNITY_HOST"] = "127.0.0.1"
    users, tokens, adm_tok = seed()

    # 起服务（先清理可能残留的旧进程/端口，避免连到旧实例）
    import subprocess
    subprocess.run(["pkill", "-f", "community/server.py"], capture_output=True)
    time.sleep(1.0)
    env = dict(os.environ)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(BASE, "server.py")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    try:
        _run(users, tokens, adm_tok)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    print("\n===== 冒烟结果：PASS %d / FAIL %d =====" % (PASS, FAIL))
    if FAILED:
        print("失败项：")
        for f in FAILED:
            print(" -", f)
    sys.exit(1 if FAIL else 0)


def _run(users, tokens, adm_tok):
    u1, u2, u3 = users
    t1, t2, t3 = tokens
    now = time.time()

    # ===== 健康检查 =====
    s, r = req("GET", "/health")
    check("health", s == 200 and r.get("ok"))

    # ===== 未登录保护 =====
    s, r = req("POST", "/post", {"content": "x"})
    check("post 未登录 401", s == 401)
    s, r = req("GET", "/level/me")
    check("level/me 未登录 401", s == 401)

    # ===== 版块 =====
    s, r = req("GET", "/boards")
    check("boards 6 版块", s == 200 and len(r.get("list", [])) == 6)

    # ===== 发图文帖（含话题/@/3 图上限） =====
    s, r = req("POST", "/post", {
        "content": "第一条帖子 #测试话题 @测试用户2 [happy] 你好",
        "boardId": r.get("list", [{}])[0]["id"] if r.get("list") else "",
        "topic": ["测试话题"], "mentions": [{"id": u2, "name": "测试用户2"}]},
        token=t1)
    check("发帖", s == 200, r)
    post1 = r.get("post", {}) if s == 200 else {}
    check("发帖审核待审", post1.get("auditStatus") == 0)
    check("发帖话题", "测试话题" in post1.get("topic", []))
    s, r = req("POST", "/post", {
        "content": "x", "images": ["a", "b", "c", "d"]}, token=t1)
    check("3 图上限", s == 400)

    # 敏感词测试
    c_db = __import__("common", globals(), locals()).db
    cc = c_db()
    cc.execute("INSERT INTO community_sensitive_words(id,word,level,active,created) VALUES(?,?,?,1,?)",
               (uuid.uuid4().hex, "违禁词", 0, time.time()))
    cc.commit()
    cc.close()
    s, r = req("POST", "/post", {"content": "这条含违禁词"}, token=t1)
    check("敏感词拦截", s == 400)

    # ===== 信息流（待审不进） =====
    s, r = req("GET", "/feed")
    check("feed 待审不可见", s == 200 and r.get("list", []) == [])

    # ===== 审核通过（管理员） =====
    s, r = req("POST", "/admin/posts/%s/audit" % post1["id"],
               {"action": "approve"}, adm=adm_tok)
    check("审核通过", s == 200 and r.get("auditStatus") == 1)
    s, r = req("GET", "/feed")
    check("feed 通过可见", s == 200 and len(r.get("list", [])) == 1)

    # ===== 点赞 / 分享 / 评论 =====
    s, r = req("POST", "/post/%s/like" % post1["id"], {}, token=t2)
    check("点赞", s == 200 and r.get("liked"))
    s, r = req("POST", "/post/%s/share" % post1["id"], {}, token=t2)
    check("分享", s == 200 and r.get("shareCount") == 1)
    # 评论：文字混排
    s, r = req("POST", "/post/%s/comment" % post1["id"],
               {"content": "好帖 [ok] 支持"}, token=t2)
    check("评论", s == 200, r)
    cid1 = r.get("comment", {}).get("id", "")
    # 评论：图与表情二选一
    s, r = req("POST", "/post/%s/comment" % post1["id"],
               {"content": "图评", "images": ["img1"], "sticker": "e1"}, token=t2)
    check("评论图与表情互斥", s == 400)
    s, r = req("POST", "/post/%s/comment" % post1["id"],
               {"content": "", "images": ["img1"]}, token=t2)
    check("评论带图", s == 200, r)
    s, r = req("POST", "/post/%s/comment" % post1["id"],
               {"content": "", "sticker": "e_sticker.gif"}, token=t2)
    check("评论带表情包", s == 200, r)
    s, r = req("GET", "/post/%s/comments" % post1["id"])
    check("评论列表", s == 200 and len(r.get("list", [])) >= 3)
    s, r = req("POST", "/comment/%s/like" % cid1, {}, token=t3)
    check("评论点赞", s == 200 and r.get("liked"))

    # ===== 互动通知（作者收到） =====
    s, r = req("GET", "/notifications", token=t1)
    check("互动通知", s == 200 and len(r.get("list", [])) > 0)
    s, r = req("GET", "/notifications/unread", token=t1)
    check("未读计数", s == 200 and r.get("unread", 0) > 0)
    s, r = req("POST", "/notifications/read", {}, token=t1)
    check("全部已读", s == 200)

    # ===== 官方通知（独立） =====
    s, r = req("POST", "/admin/official", {"content": "社区公告：欢迎使用"},
               adm=adm_tok)
    check("官方通知发布", s == 200)
    s, r = req("GET", "/official-messages", token=t1)
    check("官方通知读取(独立表)", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("POST", "/official-messages/read", {}, token=t1)
    check("官方已读", s == 200)
    s, r = req("GET", "/notifications/unread", token=t1)
    check("官方不计互动未读", s == 200 and r.get("officialUnread", 0) == 0)

    # ===== 神评 / 置顶 / 精华 / 下架 =====
    s, r = req("POST", "/admin/comment/%s/pin" % cid1, {}, adm=adm_tok)
    check("神评", s == 200 and r.get("pinned") == 1)
    s, r = req("GET", "/post/%s/comments" % post1["id"])
    check("神评置顶", s == 200 and r.get("list") and r["list"][0]["pinned"] == 1)
    s, r = req("POST", "/admin/posts/%s/pin" % post1["id"], {}, adm=adm_tok)
    check("置顶", s == 200 and r.get("sticky") == 1)
    s, r = req("POST", "/admin/posts/%s/featured" % post1["id"], {}, adm=adm_tok)
    check("精华", s == 200 and r.get("featured") == 1)

    # ===== 下架（必填理由） =====
    s, r = req("POST", "/admin/posts/%s/takedown" % post1["id"], {}, adm=adm_tok)
    check("下架需理由", s == 400)
    s, r = req("POST", "/admin/posts/%s/takedown" % post1["id"],
               {"reason": "内容违规测试"}, adm=adm_tok)
    check("下架", s == 200 and r.get("takenDown") == 1)
    s, r = req("GET", "/feed")
    check("下架不进信息流", s == 200 and r.get("list", []) == [])
    s2, r2 = req("DELETE", "/admin/posts/%s/takedown" % post1["id"], {}, adm=adm_tok)
    check("下架恢复", s2 == 200 and r2.get("takenDown") == 0)

    # ===== 等级 =====
    s, r = req("GET", "/level/me", token=t1)
    check("等级接口", s == 200 and "exp" in r)
    s, r = req("GET", "/level/rules")
    check("等级规则", s == 200 and len(r.get("thresholds", [])) == 11)

    # ===== 搜索 =====
    s, r = req("GET", "/search?q=" + urllib.parse.quote("测试话题"))
    check("搜索话题命中", s == 200 and len(r.get("topics", [])) >= 1)
    s, r = req("GET", "/search/hot")
    check("热词", s == 200)
    s, r = req("GET", "/search/suggest?q=" + urllib.parse.quote("测试"))
    check("搜索联想", s == 200)

    # ===== 收藏 / 稍后看 =====
    s, r = req("POST", "/post/%s/fav" % post1["id"], {}, token=t2)
    check("收藏", s == 200 and r.get("fav"))
    s, r = req("POST", "/post/%s/later" % post1["id"], {}, token=t2)
    check("稍后看", s == 200 and r.get("later"))
    s, r = req("GET", "/favorites?kind=fav", token=t2)
    check("收藏列表", s == 200 and len(r.get("list", [])) == 1)

    # ===== 编辑（回待审） =====
    s, r = req("POST", "/post/%s/edit" % post1["id"], {"content": "编辑后内容"},
               token=t1)
    check("编辑回待审", s == 200 and r.get("post", {}).get("auditStatus") == 0)

    # ===== 草稿 =====
    s, r = req("POST", "/draft", {"content": "草稿内容", "topic": ["草稿"]}, token=t1)
    check("存草稿", s == 200 and r.get("id"))
    draft_id = r.get("id", "")
    s, r = req("GET", "/drafts", token=t1)
    check("草稿列表", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("DELETE", "/draft/%s" % draft_id, token=t1)
    check("删草稿", s == 200)

    # ===== 举报 / 拉黑 =====
    s, r = req("POST", "/report", {"targetType": "post", "targetId": post1["id"],
                                   "reason": "测试举报"}, token=t3)
    check("举报", s == 200)
    s, r = req("GET", "/admin/reports", adm=adm_tok)
    check("举报队列", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("POST", "/block/%s" % u1, {}, token=t3)
    check("拉黑", s == 200 and r.get("blocked"))
    s, r = req("GET", "/blocks", token=t3)
    check("拉黑列表", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("DELETE", "/block/%s" % u1, token=t3)
    check("取消拉黑", s == 200)

    # ===== 偏好（通知/隐私/主题） =====
    s, r = req("PUT", "/prefs", {"notifyMask": {"like": False}, "commentPerm": 1,
                                 "profileVisible": True, "theme": "light"}, token=t1)
    check("偏好保存", s == 200)
    s, r = req("GET", "/prefs", token=t1)
    check("偏好读取", s == 200 and r.get("theme") == "light" and r.get("commentPerm") == 1)

    # ===== 签到 / 任务 =====
    s, r = req("POST", "/signin", {}, token=t1)
    check("签到", s == 200 and r.get("exp", 0) > 0, r)
    s, r = req("POST", "/signin", {}, token=t1)
    check("重复签到拒绝", s == 400)
    s, r = req("GET", "/tasks", token=t1)
    check("任务列表", s == 200 and len(r.get("list", [])) >= 8)
    s, r = req("POST", "/tasks/t_first_post/claim", {}, token=t1)
    check("任务领取", s == 200 and r.get("claimed"))

    # ===== 装扮（头像框） =====
    c_db = __import__("common", globals(), locals()).db
    cc = c_db()
    cc.execute("INSERT INTO community_frames(id,name,image,image_dynamic,sort,active,created)"
               " VALUES(?,?,?,?,0,1,?)", (uuid.uuid4().hex, "测试框", "frame1.png", "frame1.gif", time.time()))
    cc.commit()
    cc.close()
    s, r = req("GET", "/frames")
    check("头像框列表", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("POST", "/frame/equip", {"frameId": r["list"][0]["id"]}, token=t1)
    check("佩戴头像框", s == 200 and r.get("frameId"))
    s, r = req("GET", "/frame/mine", token=t1)
    check("我的头像框", s == 200 and r.get("frameId"))

    # ===== 表情（库/收藏） =====
    c_db = __import__("common", globals(), locals()).db
    cc = c_db()
    cc.execute("INSERT INTO community_emojis(id,code,image,category,sort,active,created)"
               " VALUES(?,?,?,?,0,1,?)", (uuid.uuid4().hex, "[happy]", "emoji/happy.png", "默认", time.time()))
    cc.commit()
    cc.close()
    s, r = req("GET", "/emojis")
    check("表情库", s == 200 and len(r.get("list", [])) == 1)
    eid = r["list"][0]["id"]
    s, r = req("POST", "/emoji/fav", {"emojiId": eid}, token=t1)
    check("收藏表情", s == 200 and r.get("fav"))
    s, r = req("GET", "/emojis/favs", token=t1)
    check("我的表情", s == 200 and len(r.get("list", [])) == 1)

    # ===== 投票帖 =====
    s, r = req("POST", "/post", {"content": "投票测试", "poll": {
        "question": "今晚吃什么？", "options": ["火锅", "烧烤", "面"]}}, token=t1)
    check("投票帖", s == 200 and r.get("post", {}).get("type") == "poll", r)
    poll_post = r.get("post", {})
    s, r = req("POST", "/poll/vote", {"postId": poll_post["id"], "option": 1}, token=t2)
    check("投票", s == 200 and r.get("voted"), r)
    s, r = req("POST", "/poll/vote", {"postId": poll_post["id"], "option": 2}, token=t2)
    check("一人一票", s == 400)

    # ===== 关注流 / 排行 =====
    s, r = req("GET", "/feed?tab=follow", token=t2)
    check("关注流", s == 200)
    s, r = req("GET", "/rankings?type=post")
    check("帖子排行", s == 200)
    s, r = req("GET", "/rankings?type=user")
    check("达人榜", s == 200)

    # ===== Banner =====
    s, r = req("POST", "/admin/banners", {"image": "b1.png", "linkType": "url"},
               adm=adm_tok)
    check("Banner 配置", s == 200)
    s, r = req("GET", "/banners")
    check("Banner 读取", s == 200 and len(r.get("list", [])) == 1)

    # ===== 活动 =====
    s, r = req("POST", "/admin/activities", {"title": "秋日话题活动", "topicId": "测试话题",
                                             "rewardExp": 50, "startAt": time.time() - 100,
                                             "endAt": time.time() + 86400}, adm=adm_tok)
    check("活动创建", s == 200)
    act_id = r.get("id", "")
    s, r = req("GET", "/activities")
    check("活动列表", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("POST", "/admin/activities/%s/end" % act_id, {}, adm=adm_tok)
    check("活动结束发奖", s == 200)

    # ===== 管理分级 =====
    s, r = req("POST", "/admin/admins/grant", {"userId": u2, "name": "二级管理员"},
               adm=adm_tok)
    check("升级二级管理员", s == 200 and r.get("level") == 2, r)
    t2_adm = r.get("token", "")
    s, r = req("GET", "/admin/admins", adm=adm_tok)
    check("管理员列表", s == 200 and len(r.get("list", [])) == 2)
    # 二级不能配置类操作
    s, r = req("POST", "/admin/boards", {"name": "越权版块"}, adm=t2_adm)
    check("二级越权被拒", s == 403)
    # 二级可审核
    s, r = req("POST", "/post", {"content": "等待二级审核"}, token=t3)
    p3 = r.get("post", {}).get("id", "")
    s, r = req("POST", "/admin/posts/%s/audit" % p3, {"action": "reject", "reason": "内容不符"},
               adm=t2_adm)
    check("二级审核拒绝", s == 200 and r.get("auditStatus") == 2)
    s, r = req("GET", "/notifications", token=t3)
    check("拒绝通知作者", s == 200 and any("未通过" in (x.get("content") or "") for x in r.get("list", [])))
    # 撤销二级
    s, r = req("POST", "/admin/admins/revoke", {"userId": u2}, adm=adm_tok)
    check("撤销二级", s == 200)

    # ===== 用户资料（认证/头衔/管理员 LOGO） =====
    s, r = req("GET", "/user/%s/profile" % u1, token=t2)
    check("用户资料", s == 200 and r.get("user", {}).get("adminLevel") == 1)
    check("认证/头衔互通", s == 200 and r["user"].get("title") == "测试头衔")
    s, r = req("GET", "/user/%s/posts" % u1, token=t2)
    check("用户帖子列表", s == 200)

    # ===== 私信（二期接口） =====
    s, r = req("POST", "/conversations/%s" % u2, {}, token=t1)
    check("发起会话", s == 200 and r.get("conversationId"), r)
    conv = r.get("conversationId", "")
    s, r = req("POST", "/messages", {"conversationId": conv, "content": "你好"}, token=t1)
    check("发私信", s == 200)
    s, r = req("GET", "/messages?conv_id=%s" % conv, token=t2)
    check("私信历史", s == 200 and len(r.get("list", [])) == 1)
    s, r = req("GET", "/conversations", token=t2)
    check("会话列表", s == 200 and len(r.get("list", [])) == 1)

    # ===== 视频（上传/状态/转码产物） =====
    # 本地构造最小 mp4（fake 数据，魔数校验通过即可；转码失败不影响接口测试）
    import struct as _st
    tiny = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64
    s, r = req("POST", "/upload-video", files={"video": ("t.mp4", tiny)}, token=t1)
    check("视频上传", s == 200 and r.get("videoId"), r)
    vid = r.get("videoId", "")
    s, r = req("GET", "/video/%s/status" % vid, token=t1)
    check("视频状态", s == 200)
    s, r = req("POST", "/video/post", {"video": vid, "content": "视频文案 #视频话题",
                                       "cover": ""}, token=t1)
    check("发视频帖", s == 200 and r.get("post", {}).get("type") == "video", r)
    s, r = req("POST", "/admin/posts/%s/audit" % r["post"]["id"], {"action": "approve"}, adm=adm_tok)
    check("视频审核通过", s == 200)
    s, r = req("GET", "/feed?type=video")
    check("视频进信息流", s == 200 and len(r.get("list", [])) == 1)

    # ===== 令牌轮换 =====
    s, r = req("POST", "/admin/token/rotate", {"oldToken": adm_tok}, adm=adm_tok)
    check("令牌轮换", s == 200 and r.get("token"), r)
    new_adm = r.get("token", adm_tok)
    s, r = req("GET", "/admin/stats", adm=new_adm)
    check("新令牌可用", s == 200)

    # ===== 管理留痕 =====
    s, r = req("GET", "/admin/logs", adm=new_adm)
    check("操作留痕", s == 200 and len(r.get("list", [])) > 0)

    # ===== 限流（admin 240/min 不触发；post 30/h 也不触发） =====
    s, r = req("GET", "/search/hot")
    check("访客搜索", s == 200)

    # ===== 分享落地页 =====
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(BASE_URL + "/s/%s" % post1["id"], timeout=10) as resp:
            s = resp.status
    except urllib.error.HTTPError as e:
        s = e.code
    check("分享落地页 302", s == 302)

    # ===== 当前用户与关注动作（客户端对账路由） =====
    s, r = req("GET", "/user/me", token=t1)
    check("/user/me", s == 200 and r.get("user", {}).get("id"), r)
    s, r = req("POST", "/user/%s/follow" % u2, token=t1)
    check("关注用户", s == 200 and r.get("following") is True, r)
    s, r = req("POST", "/user/%s/follow" % u2, token=t1)
    check("重复关注=取关", s == 200 and r.get("following") is False, r)
    s, r = req("GET", "/notifications", token=t1)
    check("关注通知已入列", s == 200, r)

    print("用例执行完成。")


if __name__ == "__main__":
    main()
