# -*- coding: utf-8 -*-
"""流萤社区 · 会员域：套餐 / 开通 / 兑换码 / 我的开通记录。

社区会员独立于音乐会员（不读 users.member*），双档：
- member → 展示名 VIP
- svip   → 展示名 SVIP

对外接口：
- GET  /member/plans      套餐列表 + 我的状态
- GET  /member/status     我的状态 + 权益 + 表情额度
- POST /member/redeem     兑换码开通 / 续期 / 升级
- POST /member/apply      提交开通申请（等管理员发放）
- GET  /member/orders     我的开通记录
"""
import json
import time
import urllib.parse
import uuid

import epay
import invite_core
from core.settings import settings
from common import (resolve_token, row_dict, member_level_now, member_rank,
                    member_emoji_limit, MEMBER_LABEL, MEMBER_LEVELS, notify, client_ip)

CODE_MIN_LEN = 8
CODE_MAX_LEN = 32


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _body(h):
    return h._json_body() or {}


def _benefits(level, expire):
    """当前档位权益清单。每项都对应后端真实能力，不做空头承诺。"""
    lv = level or ""
    on = bool(lv) and expire > time.time()
    limit = member_emoji_limit(lv)
    return [
        {"key": "badge", "name": "会员徽章", "desc": "昵称旁常驻 VIP / SVIP 标识", "on": on},
        {"key": "frame", "name": "会员头像框", "desc": "装扮页可使用会员专属框位", "on": on},
        {"key": "emoji", "name": "表情收藏扩容", "desc": "收藏上限 %d 个" % limit, "on": on, "limit": limit},
        {"key": "nick", "name": "昵称高亮", "desc": "资料卡与评论区昵称走薄荷色", "on": on},
    ]


def _my_status(c, uid):
    level, expire = member_level_now(c, uid)
    used = 0
    if uid:
        used = c.execute("SELECT COUNT(*) FROM community_user_emojis WHERE user_id=?",
                         (uid,)).fetchone()[0]
    now = time.time()
    days_left = max(0, int((expire - now) // 86400)) if expire else 0
    return {
        "level": level,
        "label": MEMBER_LABEL.get(level, ""),
        "expire": int(expire or 0),
        "daysLeft": days_left,
        "expiring": bool(level) and 0 < expire - now <= 7 * 86400,
        "emojiLimit": member_emoji_limit(level),
        "emojiUsed": used,
        "benefits": _benefits(level, expire),
    }


def _plans(c):
    rows = c.execute("SELECT id, level, name, days, price FROM community_member_plans"
                     " WHERE active=1 ORDER BY sort ASC").fetchall()
    return [{"id": r[0], "level": r[1], "label": MEMBER_LABEL.get(r[1], ""),
             "name": r[2], "days": r[3], "price": r[4]} for r in rows]


def _activate(c, uid, level, days):
    """开通 / 续期 / 升级会员（不写订单），返回新的 (level, expire)。"""
    if level not in MEMBER_LEVELS:
        raise ValueError("档位不存在")
    days = int(days)
    if days <= 0:
        raise ValueError("时长不合法")
    now = time.time()
    row = c.execute("SELECT level, expire FROM community_members WHERE user_id=?", (uid,)).fetchone()
    old_level, old_expire = "", 0.0
    if row:
        old_level = row[0] or ""
        old_expire = row[1] or 0
    if old_expire > now and old_level in MEMBER_LEVELS and member_rank(level) < member_rank(old_level):
        raise ValueError("已有更高档会员，不能降档")
    base = max(now, old_expire if old_level in MEMBER_LEVELS else 0)
    expire = base + days * 86400
    if row:
        c.execute("UPDATE community_members SET level=?, expire=?, updated=? WHERE user_id=?",
                  (level, expire, now, uid))
    else:
        c.execute("INSERT INTO community_members(user_id,level,expire,created,updated)"
                  " VALUES(?,?,?,?,?)", (uid, level, expire, now, now))
    return level, expire


def _grant(c, uid, level, days, channel, code="", price=0):
    """开通 / 续期 / 升级，并写一条已生效订单，返回新的 (level, expire)。"""
    now = time.time()
    lv, expire = _activate(c, uid, level, days)
    c.execute("INSERT INTO community_member_orders(id,user_id,level,days,price,channel,code,status,created,updated)"
              " VALUES(?,?,?,?,?,?,?,1,?,?)",
              (uuid.uuid4().hex, uid, level, days, price, channel, code, now, now))
    return lv, expire


def _ext_url(self, path):
    """当前站点外部地址：只使用服务端配置，不信任请求 Host/X-Forwarded-*。"""
    return settings.public_base + path


def _notify_params(self, u):
    """易支付回调参数：GET query 与 POST form 都支持。"""
    params = {}
    for k, v in urllib.parse.parse_qs(u.query or "").items():
        if v:
            params[k] = v[0]
    if not params:
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(min(length, 32 * 1024)) if length else b""
            if raw:
                if "application/json" in (self.headers.get("Content-Type") or ""):
                    data = json.loads(raw.decode("utf-8") or "{}")
                    if isinstance(data, dict):
                        params = {str(k): str(v) for k, v in data.items()}
                else:
                    for k, v in urllib.parse.parse_qs(raw.decode("utf-8", "replace")).items():
                        if v:
                            params[k] = v[0]
        except Exception:
            params = {}
    return params


def _text(self, body):
    self._send(200, body.encode("utf-8"), "text/plain; charset=utf-8")


def _pay_return_page(ok=True):
    title = "支付完成" if ok else "支付未完成"
    desc = "请返回流萤社区 App，会员状态会自动刷新。" if ok else "如已扣款，请稍等片刻或联系管理员。"
    color = "#3DE0B0" if ok else "#FFB86B"
    return """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s</title><style>
html,body{height:100%%;margin:0;background:#070808;color:#F2F5F4;font-family:-apple-system,"PingFang SC",sans-serif}
.wrap{height:100%%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;box-sizing:border-box}
.dot{width:64px;height:64px;border-radius:50%%;background:%s1A;border:1px solid %s55;display:flex;align-items:center;justify-content:center;font-size:30px;color:%s}
h1{font-size:20px;margin:18px 0 8px}p{font-size:13px;line-height:1.7;color:#8A9490;text-align:center;margin:0}
</style></head><body><div class="wrap"><div class="dot">✓</div><h1>%s</h1><p>%s</p></div></body></html>""" % (
        title, color, color, color, title, desc)


def _handle_member(self, c, u, api, method):
    uid = _uid(c, self)

    # ---------------- 易支付：异步通知 ----------------
    if api == "/member/epay/notify" and method in ("GET", "POST"):
        params = _notify_params(self, u)
        cfg = epay.settings()
        if not cfg["enabled"] or not epay.verify(params, cfg["key"]):
            self._send(403, b"fail", "text/plain; charset=utf-8")
            return True
        if str(params.get("trade_status") or "") != "TRADE_SUCCESS":
            _text(self, "fail")
            return True
        order_id = str(params.get("out_trade_no") or "").strip()
        row = c.execute("SELECT id,user_id,level,days,price,status FROM community_member_orders"
                        " WHERE id=?", (order_id,)).fetchone()
        if not row:
            _text(self, "fail")
            return True
        if int(row[5] or 0) == 1:
            c.commit()
            _text(self, "success")
            return True
        try:
            paid_money = float(params.get("money") or 0)
        except (TypeError, ValueError):
            paid_money = 0.0
        expected = float(row[4] or 0) / 100.0
        if abs(paid_money - expected) > 0.01:
            _text(self, "fail")
            return True
        # 抢占处理权，避免重复回调重复加时长
        claimed = c.execute("UPDATE community_member_orders SET status=9, updated=?"
                            " WHERE id=? AND status=0", (time.time(), order_id)).rowcount
        if not claimed:
            c.commit()
            _text(self, "success")
            return True
        try:
            _activate(c, row[1], row[2], int(row[3]))
            invite_core.credit_membership(c, row[1], order_id, int(row[4] or 0))
            c.execute("UPDATE community_member_orders SET status=1, trade_no=?, paid_at=?,"
                      " updated=? WHERE id=?",
                      (str(params.get("trade_no") or ""), time.time(), time.time(), order_id))
            c.commit()
        except Exception:
            c.execute("UPDATE community_member_orders SET status=0 WHERE id=? AND status=9",
                      (order_id,))
            c.commit()
            _text(self, "fail")
            return True
        try:
            notify(c, row[1], "member", "会员开通成功",
                   "支付已到账，%s 会员已自动生效。" % MEMBER_LABEL.get(row[2], "会员"))
            c.commit()
        except Exception:
            pass
        _text(self, "success")
        return True

    # ---------------- 易支付：页面跳转回站点 ----------------
    if api == "/member/epay/return" and method == "GET":
        self._send(200, _pay_return_page(True).encode("utf-8"),
                   "text/html; charset=utf-8")
        return True

    # ---------------- 易支付：下单 ----------------
    if api == "/member/pay-create" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        plan_id = str(body.get("planId") or "").strip()
        channel = str(body.get("channel") or "wxpay").strip()
        if channel not in ("wxpay", "alipay"):
            self._err(400, "请选择微信或支付宝")
            return True
        plan = c.execute("SELECT id,level,name,days,price FROM community_member_plans"
                         " WHERE id=? AND active=1", (plan_id,)).fetchone()
        if not plan:
            self._err(400, "套餐不存在")
            return True
        level, days, price = plan[1], int(plan[3]), int(plan[4])
        if price <= 0:
            self._err(400, "套餐价格未配置")
            return True
        order_id = "LC" + uuid.uuid4().hex[:30]
        now = time.time()
        c.execute("INSERT INTO community_member_orders(id,user_id,level,days,price,channel,status,created,updated)"
                  " VALUES(?,?,?,?,?,?,0,?,?)",
                  (order_id, uid, level, days, price, "epay_" + channel, now, now))
        c.commit()
        try:
            pay = epay.create(
                order_id, price, "流萤社区%s（%s天）" % (MEMBER_LABEL.get(level, level), days),
                channel, client_ip(self), _ext_url(self, "/member/epay/notify"),
                _ext_url(self, "/member/epay/return"))
        except epay.EpayError as e:
            c.execute("DELETE FROM community_member_orders WHERE id=? AND status=0", (order_id,))
            c.commit()
            msg = str(e)
            if "实名" in msg:
                msg = "在线支付暂未开通：商户未完成实名认证，请改用凭证人工开通"
            elif "审核" in msg:
                msg = "在线支付暂未开通：支付商户未通过审核，请改用凭证人工开通"
            elif "连接失败" in msg or "timed out" in msg or "URL" in msg:
                msg = "支付网关连接失败，请稍后重试或改用凭证人工开通"
            elif "网关返回异常" in msg:
                msg = "支付网关返回异常，请稍后重试或改用凭证人工开通"
            self._err(400, msg)
            return True
        c.execute("UPDATE community_member_orders SET trade_no=?, note=? WHERE id=?",
                  (pay.get("trade_no") or "", "epay:" + pay.get("pay_type", ""), order_id))
        c.commit()
        self._ok({
            "orderId": order_id,
            "money": "%.2f" % (price / 100.0),
            "level": level,
            "days": days,
            "channel": channel,
            "payType": pay.get("pay_type"),
            "payUrl": pay.get("pay_info"),
        })
        return True

    # ---------------- 易支付：查单 ----------------
    if api == "/member/pay-status" and method in ("GET", "POST"):
        if not uid:
            self._err(401, "未登录")
            return True
        order_id = ""
        if method == "GET":
            qs = urllib.parse.parse_qs(u.query or "")
            order_id = (qs.get("orderId") or [""])[0]
        else:
            order_id = str(_body(self).get("orderId") or "")
        row = c.execute("SELECT level,days,price,status FROM community_member_orders"
                        " WHERE id=? AND user_id=?", (order_id, uid)).fetchone()
        if not row:
            self._err(404, "订单不存在")
            return True
        me = _my_status(c, uid)
        c.commit()
        self._ok({"orderId": order_id, "status": int(row[3] or 0),
                  "paid": int(row[3] or 0) == 1, "level": row[0], "days": row[1],
                  "money": "%.2f" % (int(row[2] or 0) / 100.0), "me": me})
        return True

    # ---------------- 套餐 + 我的状态 ----------------
    if api == "/member/plans" and method == "GET":
        plans = _plans(c)
        me = _my_status(c, uid)
        c.commit()
        self._ok({"plans": plans, "me": me})
        return True

    if api == "/member/status" and method == "GET":
        me = _my_status(c, uid)
        c.commit()
        self._ok(me)
        return True

    # ---------------- 兑换码开通 ----------------
    if api == "/member/redeem" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        code = (body.get("code") or "").strip().upper()
        if len(code) < CODE_MIN_LEN or len(code) > CODE_MAX_LEN:
            self._err(400, "兑换码格式不正确")
            return True
        row = c.execute("SELECT level, days, used_by, used_at FROM community_member_codes"
                        " WHERE code=?", (code,)).fetchone()
        if not row:
            c.commit()
            self._err(404, "兑换码不存在")
            return True
        if row[2]:
            c.commit()
            self._err(400, "该兑换码已被使用")
            return True
        level, days = row[0], int(row[1])
        try:
            lv, expire = _grant(c, uid, level, days, "code", code=code)
        except ValueError as e:
            c.commit()
            self._err(400, str(e))
            return True
        c.execute("UPDATE community_member_codes SET used_by=?, used_at=? WHERE code=?",
                  (uid, time.time(), code))
        c.commit()
        me = _my_status(c, uid)
        self._ok({"redeemed": True, "level": lv, "label": MEMBER_LABEL.get(lv, ""),
                  "expire": int(expire), "days": days, "me": me})
        return True

    # ---------------- 提交开通申请（管理员审核后发放） ----------------
    if api == "/member/apply" and method == "POST":
        if not uid:
            self._err(401, "未登录")
            return True
        body = _body(self)
        plan_id = (body.get("planId") or "").strip()
        contact = (body.get("contact") or "").strip()[:120]
        note = (body.get("note") or "").strip()[:200]
        proof = (body.get("proof") or "").strip()[:300]
        plan = c.execute("SELECT level, days, price FROM community_member_plans WHERE id=? AND active=1",
                         (plan_id,)).fetchone()
        if not plan:
            c.commit()
            self._err(400, "套餐不存在")
            return True
        level, days, price = plan[0], int(plan[1]), int(plan[2])
        pending = c.execute("SELECT 1 FROM community_member_orders WHERE user_id=? AND status=0",
                            (uid,)).fetchone()
        if pending:
            c.commit()
            self._err(400, "已有一条申请在处理中，请等管理员处理")
            return True
        now = time.time()
        try:
            c.execute("ALTER TABLE community_member_orders ADD COLUMN proof TEXT DEFAULT ''")
        except Exception:
            pass
        c.execute("INSERT INTO community_member_orders(id,user_id,level,days,price,channel,contact,note,proof,status,created,updated)"
                  " VALUES(?,?,?,?,?,?,?,?,?,0,?,?)",
                  (uuid.uuid4().hex, uid, level, days, price, "apply", contact, note, proof, now, now))
        c.commit()
        try:
            notify(c, uid, "member", "开通申请已提交", "管理员会尽快处理，处理完成后会员立即生效。")
            c.commit()
        except Exception:
            pass
        self._ok({"applied": True, "level": level, "days": days})
        return True

    # ---------------- 我的开通记录 ----------------
    if api == "/member/orders" and method == "GET":
        if not uid:
            self._err(401, "未登录")
            return True
        rows = c.execute("SELECT id, level, days, price, channel, status, created, proof FROM community_member_orders"
                         " WHERE user_id=? ORDER BY created DESC LIMIT 30", (uid,)).fetchall()
        c.commit()
        self._ok({"list": [{"id": r[0], "level": r[1], "label": MEMBER_LABEL.get(r[1], ""),
                            "days": r[2], "price": r[3], "channel": r[4],
                            "status": r[5], "created": r[6]} for r in rows]})
        return True

    return False


def dispatch(self, c, u, api, method):
    if _handle_member(self, c, u, api, method):
        return True
    return False
