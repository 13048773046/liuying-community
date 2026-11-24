# -*- coding: utf-8 -*-
"""邀请好友赚现金 · /invite/*

链路：
- 公开：规则、点击归因、邀请二维码；
- 登录：我的邀请码/邀请记录/手机号验证/提现；
- 管理：提现审核。
"""
import logging
import os
import time
import urllib.parse

import invite_core as IC
import captcha
from common import db, resolve_token, client_ip, rate_limit, admin_required

log = logging.getLogger("community.invite")


def _uid(c, h):
    return resolve_token(c, h.headers.get("Authorization", ""))


def _body(h):
    return h._json_body() or {}


def _q(h):
    return urllib.parse.parse_qs(urllib.parse.urlparse(h.path).query)


def _one(q, key, default=""):
    return (q.get(key) or [default])[0]


def _admin(c, h):
    row = admin_required(c, h)
    if not row:
        h._err(401, "管理员令牌无效")
        return None
    if int(row[1] or 2) != 1:
        h._err(403, "提现审核仅超级管理员可操作")
        return None
    return row


def _avatar(c, uid):
    row = c.execute("SELECT avatar FROM users WHERE id=?", (uid,)).fetchone()
    return row[0] if row else ""


def dispatch(self, c, u, api, method):
    q = _q(self)
    ip = client_ip(self)
    ua = self.headers.get("User-Agent", "")

    # ---------------- 公开规则 ----------------
    if api == "/invite/info" and method == "GET":
        if not rate_limit(self, "invite_info"):
            self._err(429, "请求太频繁，稍后再试")
            return True
        info = IC.public_info(c)
        ref = _one(q, "ref").strip().upper()
        inviter = None
        if ref:
            row = c.execute(
                "SELECT p.user_id, COALESCE(u.name,''), COALESCE(u.avatar,'') "
                "FROM community_invite_profiles p LEFT JOIN users u ON u.id=p.user_id "
                "WHERE p.code=?", (ref,)).fetchone()
            if row:
                inviter = {"name": row[1] or "流萤好友", "avatar": row[2] or ""}
        info["inviter"] = inviter
        self._ok(info)
        return True

    if api == "/invite/click" and method == "POST":
        if not rate_limit(self, "invite_click"):
            self._err(429, "点击太频繁，稍后再试")
            return True
        b = _body(self)
        ref = (b.get("ref") or "").strip().upper()
        got = IC.record_click(c, ref, ip, ua)
        if not got:
            self._err(404, "邀请码无效或已失效")
            return True
        self._ok(got)
        return True

    if api == "/invite/share" and method == "POST":
        if not rate_limit(self, "invite_share"):
            self._err(429, "操作太频繁，稍后再试")
            return True
        b = _body(self)
        ref = (b.get("ref") or "").strip().upper()
        got = IC.record_share(c, ref, b.get("action") or "copy", ip, ua)
        if not got:
            self._err(404, "邀请码无效")
            return True
        self._ok(got)
        return True

    if api == "/invite/qr" and method == "GET":
        if not rate_limit(self, "invite_qr"):
            self._err(429, "二维码生成太频繁，稍后再试")
            return True
        ref = _one(q, "ref").strip().upper()
        if not c.execute("SELECT 1 FROM community_invite_profiles WHERE code=?", (ref,)).fetchone():
            self._err(404, "邀请码无效")
            return True
        try:
            png = IC.qr_png(ref)
        except Exception:
            log.exception("invite qr generation failed ref=%s", ref)
            self._err(500, "二维码生成失败")
            return True
        self._send(200, png, "image/png")
        return True

    # ---------------- 登录用户 ----------------
    uid = _uid(c, self)
    if api == "/invite/bind" and method == "POST":
        if not uid:
            self._err(401, "请先登录或注册")
            return True
        b = _body(self)
        code = (b.get("ref") or b.get("code") or "").strip().upper()
        click_id = (b.get("click_id") or "").strip()
        if not click_id and code:
            got = IC.record_click(c, code, ip, ua)
            click_id = (got or {}).get("click_id", "")
        ok, res = IC.bind_invite(c, uid, code, click_id, ip, ua)
        if not ok:
            msg = {
                "missing_code": "缺少邀请码",
                "invalid_code": "邀请码无效",
                "self_invite": "不能邀请自己",
                "already_bound": "这个账号已经绑定过邀请关系",
                "invalid_click": "邀请链接已失效，请让好友重新分享",
                "click_used": "这个邀请链接已经被使用",
                "click_expired": "邀请链接已过期，请让好友重新分享",
                "not_new_user": "只有新注册用户才能接受邀请",
                "user_not_found": "账号不存在",
            }.get(res, "邀请绑定失败")
            self._err(400, msg)
            return True
        self._ok(res)
        return True

    if api == "/invite/me" and method == "GET":
        if not uid:
            self._err(401, "请先登录")
            return True
        snap = IC.user_snapshot(c, uid)
        self._ok(snap)
        return True

    if api == "/invite/phone/send" and method == "POST":
        if not uid:
            self._err(401, "请先登录")
            return True
        if not rate_limit(self, "invite_phone_send"):
            self._err(429, "发送太频繁，稍后再试")
            return True
        b = _body(self)
        if not captcha.require(self, c, b):
            return True
        ok, err = IC.send_phone_code(c, uid, b.get("phone"), ip)
        if not ok:
            msg = {
                "invalid_phone": "手机号格式不正确",
                "phone_in_use": "这个手机号已经绑定过其他账号",
                "too_frequent": "验证码 60 秒内只能发一次",
                "daily_limit": "这个手机号今天发送次数已达上限",
                "sms_not_configured": "短信通道还没配置，请联系管理员",
            }.get(err, "验证码发送失败：" + err)
            self._err(400, msg)
            return True
        self._ok({"sent": True, "expires": 300})
        return True

    if api == "/invite/phone/confirm" and method == "POST":
        if not uid:
            self._err(401, "请先登录")
            return True
        if not rate_limit(self, "invite_phone_confirm"):
            self._err(429, "尝试太频繁，稍后再试")
            return True
        b = _body(self)
        ok, res = IC.confirm_phone(c, uid, b.get("phone"), b.get("code"), ip)
        if not ok:
            msg = {
                "invalid_phone": "手机号格式不正确",
                "code_not_found": "请先获取验证码",
                "code_expired": "验证码已过期，请重新获取",
                "too_many_attempts": "验证码错误次数过多，请重新获取",
                "code_error": "验证码错误",
                "phone_in_use": "这个手机号已经绑定过其他账号",
            }.get(res, "手机号验证失败")
            self._err(400, msg)
            return True
        self._ok(res)
        return True

    if api == "/invite/withdraw" and method == "POST":
        if not uid:
            self._err(401, "请先登录")
            return True
        if not rate_limit(self, "invite_withdraw"):
            self._err(429, "提交太频繁，稍后再试")
            return True
        b = _body(self)
        amount = b.get("amount_cents")
        if amount is None:
            try:
                amount = int(round(float(b.get("amount_yuan") or 0) * 100))
            except Exception:
                amount = 0
        ok, res = IC.request_withdraw(c, uid, amount, b.get("name"), b.get("phone"),
                                      b.get("qr"))
        if not ok:
            msg = {
                "invalid_phone": "手机号格式不正确",
                "invalid_name": "请填写 2–30 个字的真实姓名",
                "below_min": "提现金额未达到门槛",
                "phone_not_verified": "请先完成手机号验证再提现",
                "pending_exists": "已有一笔提现在审核中，请等处理完再提",
                "insufficient": "可提现余额不足",
                "bad_image": "收款码图片无法识别",
                "image_too_large": "收款码图片超过 3MB，请压缩后重传",
            }.get(res, "提现申请提交失败")
            self._err(400, msg)
            return True
        self._ok(res)
        return True

    # ---------------- 管理审核 ----------------
    if api.startswith("/invite/admin/"):
        if not _admin(c, self):
            return True
        if api == "/invite/admin/list" and method == "GET":
            status = _one(q, "status", "pending")
            if status not in ("pending", "approved", "paid", "rejected", "all"):
                status = "pending"
            sql = ("SELECT w.id,w.user_id,w.amount_cents,w.name,w.phone,w.status,w.created,"
                   " COALESCE(u.name,''), COALESCE(u.account,''), w.admin_note, w.qr_path "
                   "FROM community_invite_withdrawals w LEFT JOIN users u ON u.id=w.user_id ")
            if status == "all":
                rows = c.execute(sql + "ORDER BY w.created DESC LIMIT 100").fetchall()
            else:
                rows = c.execute(sql + "WHERE w.status=? ORDER BY w.created DESC LIMIT 100",
                                 (status,)).fetchall()
            self._ok({"list": [{
                "id": r[0], "user_id": r[1], "amount_yuan": round((r[2] or 0) / 100, 2),
                "name": r[3] or "", "phone": r[4] or "", "status": r[5], "created": r[6],
                "user_name": r[7] or "", "account": r[8] or "", "note": r[9] or "",
                "has_qr": bool(r[10]),
            } for r in rows]})
            return True

        if api == "/invite/admin/qr" and method == "GET":
            wid = _one(q, "id")
            row = c.execute("SELECT qr_path FROM community_invite_withdrawals WHERE id=?",
                            (wid,)).fetchone()
            if not row or not row[0] or not os.path.isfile(row[0]):
                self._err(404, "收款码不存在")
                return True
            path = os.path.abspath(row[0])
            if not path.startswith(os.path.abspath(IC.QR_DIR) + os.sep):
                self._err(403, "非法路径")
                return True
            with open(path, "rb") as f:
                self._send(200, f.read(), "image/jpeg")
            return True

        if api == "/invite/admin/review" and method == "POST":
            b = _body(self)
            wid = (b.get("id") or "").strip()
            action = (b.get("action") or "").strip()
            if action not in ("approve", "paid", "reject"):
                self._err(400, "action 只能是 approve/paid/reject")
                return True
            row = c.execute("SELECT user_id,amount_cents,status FROM community_invite_withdrawals "
                            "WHERE id=?", (wid,)).fetchone()
            if not row:
                self._err(404, "提现记录不存在")
                return True
            user_id, amount, status = row[0], int(row[1] or 0), row[2]
            if status in ("paid", "rejected"):
                self._err(400, "这笔提现已经处理完了")
                return True
            now = time.time()
            note = (b.get("note") or "").strip()[:200]
            if action == "reject":
                c.execute("UPDATE community_invite_withdrawals SET status='rejected', reviewed_at=?, "
                          "admin_note=? WHERE id=?", (now, note, wid))
                c.execute("UPDATE community_invite_ledger SET status='rejected' "
                          "WHERE ref_id=? AND kind='withdraw'", (wid,))
            elif action == "approve":
                c.execute("UPDATE community_invite_withdrawals SET status='approved', reviewed_at=?, "
                          "admin_note=? WHERE id=?", (now, note, wid))
                c.execute("UPDATE community_invite_ledger SET status='approved' "
                          "WHERE ref_id=? AND kind='withdraw'", (wid,))
            else:
                ref = (b.get("transfer_ref") or "").strip()[:120]
                c.execute("UPDATE community_invite_withdrawals SET status='paid', reviewed_at=?, "
                          "paid_at=?, admin_note=?, transfer_ref=? WHERE id=?",
                          (now, now, note, ref, wid))
                c.execute("UPDATE community_invite_ledger SET status='paid' "
                          "WHERE ref_id=? AND kind='withdraw'", (wid,))
                c.execute("UPDATE community_invite_profiles SET total_withdrawn_cents="
                          "COALESCE(total_withdrawn_cents,0)+?, updated=? WHERE user_id=?",
                          (amount, now, user_id))
            c.commit()
            self._ok({"id": wid, "status": action})
            return True

        if api == "/invite/admin/overview" and method == "GET":
            pending = c.execute("SELECT COUNT(*), COALESCE(SUM(amount_cents),0) "
                                "FROM community_invite_withdrawals WHERE status='pending'").fetchone()
            approved = c.execute("SELECT COUNT(*), COALESCE(SUM(amount_cents),0) "
                                 "FROM community_invite_withdrawals WHERE status='approved'").fetchone()
            paid = c.execute("SELECT COUNT(*), COALESCE(SUM(amount_cents),0) "
                             "FROM community_invite_withdrawals WHERE status='paid'").fetchone()
            valid = c.execute("SELECT COUNT(*) FROM community_invite_bindings WHERE status='valid'").fetchone()[0]
            fixed = c.execute("SELECT COALESCE(SUM(amount_cents),0) FROM community_invite_ledger "
                              "WHERE kind='fixed' AND amount_cents>0").fetchone()[0]
            comm = c.execute("SELECT COALESCE(SUM(amount_cents),0) FROM community_invite_ledger "
                             "WHERE kind='commission' AND amount_cents>0").fetchone()[0]
            self._ok({
                "pending_count": pending[0], "pending_yuan": round((pending[1] or 0) / 100, 2),
                "approved_count": approved[0], "approved_yuan": round((approved[1] or 0) / 100, 2),
                "paid_count": paid[0], "paid_yuan": round((paid[1] or 0) / 100, 2),
                "valid_invites": valid,
                "fixed_yuan": round((fixed or 0) / 100, 2),
                "commission_yuan": round((comm or 0) / 100, 2),
                "settings": IC.public_info(c),
            })
            return True

        if api == "/invite/admin/settings" and method == "POST":
            b = _body(self)
            mapping = {
                "fixed_reward_yuan": ("fixed_reward_cents", 100),
                "commission_percent": ("commission_bps", 100),
                "min_withdraw_yuan": ("min_withdraw_cents", 100),
                "monthly_invite_cap": ("monthly_invite_cap", 1),
                "monthly_budget_yuan": ("monthly_budget_cents", 100),
                "settle_days": ("settle_days", 1),
            }
            for k, (sk, mult) in mapping.items():
                if k in b:
                    try:
                        IC.set_setting(c, sk, int(round(float(b[k]) * mult)))
                    except Exception:
                        pass
            for sk in ("download_ios", "download_android", "enabled", "rule_version"):
                if sk in b:
                    IC.set_setting(c, sk, str(b[sk])[:500])
            c.commit()
            self._ok(IC.public_info(c))
            return True

    return False
