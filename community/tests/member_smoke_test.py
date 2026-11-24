# -*- coding: utf-8 -*-
"""流萤社区 · 会员域专项测试（VIP/SVIP 双档 · 兑换码 · 权益门禁 · 音乐会员隔离）。

用法：
  python3 community/tests/member_smoke_test.py
"""
import os
import sys
import json
import sqlite3
import time
import urllib.request
import urllib.parse
import subprocess

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

PORT = 8792
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


def req(method, path, body=None, token=None, adm=None):
    url = BASE_URL + path
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if adm:
        headers["X-Community-Admin-Token"] = adm
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=12) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"_err": str(e)}


def main():
    from prepare_db import make_db, seed
    db_path = make_db()
    os.environ["COMMUNITY_DB"] = db_path
    os.environ["COMMUNITY_PORT"] = str(PORT)
    os.environ["COMMUNITY_HOST"] = "127.0.0.1"
    users, tokens, adm_tok = seed()

    subprocess.run(["pkill", "-f", "community/server.py"], capture_output=True)
    time.sleep(1.0)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(BASE, "server.py")],
        env=dict(os.environ), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    try:
        run(users, tokens, adm_tok, db_path)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    print("\n===== 会员专项结果：PASS %d / FAIL %d =====" % (PASS, FAIL))
    if FAILED:
        print("失败项：")
        for f in FAILED:
            print(" -", f)
    sys.exit(1 if FAIL else 0)


def run(users, tokens, adm_tok, db_path):
    u1, u2, u3 = users
    t1, t2, t3 = tokens

    # ===== 套餐与初始状态 =====
    s, r = req("GET", "/member/plans", token=t1)
    plans = r.get("plans") or []
    check("套餐列表 6 档", s == 200 and len(plans) == 6, r)
    check("套餐含 VIP 与 SVIP", s == 200
          and len([p for p in plans if p.get("level") == "member"]) == 3
          and len([p for p in plans if p.get("level") == "svip"]) == 3, plans)
    me = r.get("me") or {}
    check("初始未开通", s == 200 and me.get("level") == "" and me.get("expire") == 0, me)
    check("未开通表情上限 500", me.get("emojiLimit") == 500, me)
    check("权益四项", len(me.get("benefits") or []) == 4, me)

    # ===== 后台生成兑换码（VIP 30 天） =====
    s, r = req("POST", "/admin/member/codes", {"level": "member", "days": 30, "count": 3},
               adm=adm_tok)
    codes = r.get("codes") or []
    check("生成 3 个兑换码", s == 200 and len(codes) == 3, r)
    check("码格式 LYVP-", s == 200 and codes and codes[0].startswith("LYVP-"), codes)
    vip_code = codes[0]
    dup_code = codes[1]

    # ===== 兑换 =====
    s, r = req("POST", "/member/redeem", {"code": vip_code.lower()}, token=t1)
    check("小写码也能兑换", s == 200 and r.get("redeemed") is True, r)
    check("兑换后为 VIP", s == 200 and r.get("level") == "member" and r.get("label") == "VIP", r)
    exp1 = r.get("expire") or 0
    check("到期约 30 天后", abs(exp1 - (time.time() + 30 * 86400)) < 600, exp1)
    st = r.get("me") or {}
    check("状态同步 label", st.get("label") == "VIP" and st.get("daysLeft") == 29, st)
    check("会员表情上限 2000", st.get("emojiLimit") == 2000, st)

    s, r = req("POST", "/member/redeem", {"code": vip_code}, token=t2)
    check("重复兑换被拒", s == 400, r)

    s, r = req("POST", "/member/redeem", {"code": "LYVP-XXXX-YYYY-ZZZZ"}, token=t2)
    check("无效码 404", s == 404, r)

    s, r = req("POST", "/member/redeem", {"code": "abc"}, token=t2)
    check("过短码 400", s == 400, r)

    # ===== 同档续期叠加 =====
    s, r = req("POST", "/member/redeem", {"code": dup_code}, token=t1)
    exp2 = r.get("expire") or 0
    check("续期叠加 60 天", s == 200 and abs(exp2 - (exp1 + 30 * 86400)) < 60, (exp1, exp2, r))

    # ===== 升级 SVIP（剩余时长顺延） =====
    s, r = req("POST", "/admin/member/codes", {"level": "svip", "days": 30, "count": 2},
               adm=adm_tok)
    sv_code = (r.get("codes") or [""])[0]
    s, r = req("POST", "/member/redeem", {"code": sv_code}, token=t1)
    check("升级 SVIP", s == 200 and r.get("level") == "svip" and r.get("label") == "SVIP", r)
    exp3 = r.get("expire") or 0
    check("升级后剩余时长顺延", abs(exp3 - (exp2 + 30 * 86400)) < 60, (exp2, exp3))
    st = r.get("me") or {}
    check("SVIP 表情上限 5000", st.get("emojiLimit") == 5000, st)

    # ===== 降档拒绝 =====
    s, r = req("POST", "/admin/member/codes", {"level": "member", "days": 30, "count": 1},
               adm=adm_tok)
    low_code = (r.get("codes") or [""])[0]
    s, r = req("POST", "/member/redeem", {"code": low_code}, token=t1)
    check("SVIP 不能降档", s == 400 and "降档" in (r.get("error") or r.get("msg") or ""), r)

    # ===== 音乐会员不进入社区 =====
    c = sqlite3.connect(db_path, timeout=10)
    c.execute("UPDATE users SET member='vip', member_expire=?, svip_expire=? WHERE id=?",
              (time.time() + 365 * 86400, time.time() + 365 * 86400, u2))
    c.commit()
    c.close()
    s, r = req("GET", "/user/%s/profile" % u2, token=t3)
    u2p = r.get("user") or {}
    check("音乐会员不输出 member", s == 200 and (u2p.get("member") or "") == "", r)
    check("音乐会员不产生 cMember", s == 200 and (u2p.get("cMember") or "") == "", r)
    s, r = req("GET", "/user/%s/profile" % u1, token=t3)
    u1p = r.get("user") or {}
    check("社区会员 cMember=svip", s == 200 and u1p.get("cMember") == "svip", r)
    check("社区会员到期时间输出", s == 200 and (u1p.get("cMemberExpire") or 0) > time.time(), r)

    # ===== 表情收藏上限（普通 500 / 会员 2000 / SVIP 5000） =====
    c = sqlite3.connect(db_path, timeout=10)
    c.execute("INSERT OR IGNORE INTO community_emojis(id,code,image,category,sort,active,created)"
              " VALUES('e_mem_test','[测试]','/community/files/emoji/t.png','默认',0,1,?)",
              (time.time(),))
    c.commit()
    c.close()
    s, r = req("GET", "/emojis", token=t2)
    emo = (r.get("list") or [{}])[0]
    emo_id = "e_mem_test"
    check("表情库可用", s == 200 and len(r.get("list") or []) >= 1, r)

    # u2 普通用户：先塞 500 条收藏，再收藏应被拒
    c = sqlite3.connect(db_path, timeout=10)
    c.executemany("INSERT OR IGNORE INTO community_user_emojis(user_id,emoji_id,created) VALUES(?,?,?)",
                  [(u2, "pad_%d" % i, time.time()) for i in range(500)])
    c.commit()
    c.close()
    s, r = req("POST", "/emoji/fav", {"emojiId": emo_id}, token=t2)
    check("普通用户收藏满 500 被拒", s == 400 and "500" in (r.get("error") or r.get("msg") or ""), r)
    s, r = req("GET", "/emojis/favs", token=t2)
    check("收藏列表返回 limit=500", s == 200 and r.get("limit") == 500, r)
    s, r = req("GET", "/emojis/favs", token=t1)
    check("SVIP 收藏 limit=5000", s == 200 and r.get("limit") == 5000, r)
    s, r = req("POST", "/emoji/fav", {"emojiId": emo_id}, token=t1)
    check("SVIP 可继续收藏", s == 200, r)

    # ===== 会员头像框门禁 =====
    s, r = req("POST", "/admin/frames", {"name": "SVIP 星轨", "image": "/community/files/frames/svip.png",
                                         "memberLevel": "svip"}, adm=adm_tok)
    fid = r.get("id") or ""
    check("后台建 SVIP 框", s == 200 and fid != "", r)
    s, r = req("POST", "/admin/frames", {"name": "VIP 薄荷", "image": "/community/files/frames/vip.png",
                                         "memberLevel": "member"}, adm=adm_tok)
    fid_vip = r.get("id") or ""
    s, r = req("POST", "/admin/frames", {"name": "公开框", "image": "/community/files/frames/open.png"},
               adm=adm_tok)
    fid_open = r.get("id") or ""

    s, r = req("POST", "/frame/equip", {"frameId": fid}, token=t2)
    check("普通用户不能戴 SVIP 框", s == 403, r)
    s, r = req("POST", "/frame/equip", {"frameId": fid_open}, token=t2)
    check("普通用户可戴公开框", s == 200, r)
    s, r = req("POST", "/frame/equip", {"frameId": fid}, token=t1)
    check("SVIP 可戴 SVIP 框", s == 200, r)
    s, r = req("POST", "/frame/equip", {"frameId": fid_vip}, token=t1)
    check("SVIP 可戴 VIP 框（向下兼容）", s == 200, r)
    s, r = req("GET", "/frames")
    check("框列表带 memberLevel", s == 200 and any((f.get("member_level") == "svip") for f in (r.get("list") or [])), r)

    # ===== 开通申请 → 后台审核 =====
    s, r = req("POST", "/member/apply", {"planId": "p_svip_1", "contact": "微信 test", "note": "测试"},
               token=t3)
    check("提交开通申请", s == 200 and r.get("applied") is True, r)
    s, r = req("POST", "/member/apply", {"planId": "p_svip_1"}, token=t3)
    check("重复申请被拒", s == 400, r)
    s, r = req("GET", "/admin/member/orders?status=0", adm=adm_tok)
    orders = r.get("list") or []
    check("后台看到待处理申请", s == 200 and len(orders) >= 1, r)
    oid = orders[0]["id"] if orders else ""
    s, r = req("POST", "/admin/member/orders/%s/approve" % oid, {}, adm=adm_tok)
    check("审核通过", s == 200 and r.get("approved") is True, r)
    s, r = req("GET", "/member/status", token=t3)
    check("审核后 SVIP 生效", s == 200 and r.get("level") == "svip", r)

    # ===== 我的开通记录 =====
    s, r = req("GET", "/member/orders", token=t1)
    lst = r.get("list") or []
    check("开通记录三条（兑换2+升级1+...）", s == 200 and len(lst) >= 3, r)
    check("记录带档位与渠道", s == 200 and lst[0].get("channel") in ("code", "apply", "admin"), lst[:2])

    # ===== 过期自动失效 =====
    c = sqlite3.connect(db_path, timeout=10)
    c.execute("UPDATE community_members SET expire=? WHERE user_id=?", (time.time() - 10, u1))
    c.commit()
    c.close()
    s, r = req("GET", "/member/status", token=t1)
    check("过期即失效", s == 200 and r.get("level") == "" and r.get("emojiLimit") == 500, r)
    s, r = req("GET", "/user/%s/profile" % u1, token=t3)
    check("过期后 cMember 清空", s == 200 and ((r.get("user") or {}).get("cMember") or "") == "", r)
    s, r = req("POST", "/frame/equip", {"frameId": fid}, token=t1)
    check("过期后会员框被收回", s == 403, r)

    # ===== 兑换码管理 =====
    s, r = req("GET", "/admin/member/codes?state=used", adm=adm_tok)
    check("已用码列表", s == 200 and len(r.get("list") or []) >= 3, r)
    s, r = req("GET", "/admin/member/codes?state=unused", adm=adm_tok)
    unused = (r.get("list") or [])
    uc = unused[0]["code"] if unused else ""
    if uc:
        s, r = req("DELETE", "/admin/member/codes/%s" % uc, adm=adm_tok)
        check("作废未用码", s == 200 and r.get("deleted") is True, r)
    s, r = req("DELETE", "/admin/member/codes/%s" % vip_code, adm=adm_tok)
    check("已用码不能删", s == 400, r)

    # ===== 套餐后台可配 =====
    s, r = req("POST", "/admin/member/plans", {"level": "svip", "name": "SVIP · 周卡", "days": 7,
                                               "price": 900, "sort": 70}, adm=adm_tok)
    check("新增套餐", s == 200, r)
    s, r = req("GET", "/member/plans", token=t2)
    check("前台可见 7 档", s == 200 and len(r.get("plans") or []) == 7, r)

    # ===== 越权 =====
    s, r = req("POST", "/admin/member/codes", {"level": "member", "days": 30}, token=t2)
    check("普通用户不能生成码", s in (401, 403), r)


if __name__ == "__main__":
    main()
