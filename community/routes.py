# -*- coding: utf-8 -*-
"""社区 API 领域清单（路由所有权的唯一事实来源）。

新增接口时，先判断它属于哪个领域：
1. 已有领域能覆盖 -> 在对应 handler 内加精确路由；
2. 新领域 -> 新建 handlers/<domain>.py，实现 dispatch(self, c, u, api, method) -> bool，
   再在本文件登记 ModuleSpec，写清 name/prefixes/description。
不要让新模块靠“排在最后兜底”接请求；前缀必须可解释。
"""
from __future__ import annotations

from core.router import ModuleSpec
from handlers import (
    af as H_AF,
    ai_bot as H_AI_BOT,
    site_admin as H_SITE_ADMIN,
    app_release as H_APP_RELEASE,
    app_hot_update as H_APP_HOT_UPDATE,
    admin_api as H_ADMIN,
    admin_apps as H_ADMIN_APPS,
    auth as H_AUTH,
    captcha as H_CAPTCHA,
    apps as H_APPS,
    content as H_CONTENT,
    dm as H_DM,
    feed as H_FEED,
    feedback as H_FEEDBACK,
    invite as H_INVITE,
    member as H_MEMBER,
    upload as H_UPLOAD,
    user as H_USER,
    ws as H_WS,
)

MODULES = (
    ModuleSpec(
        "captcha",
        H_CAPTCHA,
        ("/captcha",),
        "人机验证：图片挑战，发送短信/邮件验证码前必须通过",
    ),
    ModuleSpec(
        "auth",
        H_AUTH,
        ("/auth",),
        "社区登录兜底：音乐停服时已有账号仍可登录，token 与音乐互通",
    ),
    ModuleSpec(
        "apps",
        H_APPS,
        ("/apps", "/internal/app-download"),
        "应用市场：应用列表/详情/投稿/评论/下载票据、内部下载清单",
    ),
    ModuleSpec(
        "admin_apps",
        H_ADMIN_APPS,
        ("/admin/apps", "/admin/app-categories", "/admin/app-comments", "/admin/app-reports"),
        "应用市场后台：审核、分类、评论与举报处理",
    ),
    ModuleSpec(
        "content",
        H_CONTENT,
        ("/post", "/music/tracks", "/draft", "/drafts", "/comment", "/poll", "/favorites", "/user", "/video"),
        "内容域：帖子、视频、评论、点赞、投票、收藏/稍后看、草稿、用户帖子列表",
    ),
    ModuleSpec(
        "feed",
        H_FEED,
        ("/feed", "/rankings", "/search", "/banners"),
        "发现域：信息流、榜单、搜索与热词、Banner",
    ),
    ModuleSpec(
        "user",
        H_USER,
        (
            "/boards", "/topics", "/level", "/frames", "/frame", "/emojis", "/emoji", "/prefs",
            "/signins", "/signin", "/tasks", "/report", "/blocks", "/block", "/notifications",
            "/official-messages", "/activities", "/conversations", "/messages", "/user",
            "/me", "/follow",
        ),
        "用户域：资料、关注、等级/装扮、签到任务、通知、官方消息、会话入口",
    ),
    ModuleSpec(
        "upload",
        H_UPLOAD,
        ("/upload-image", "/upload-file", "/upload-attachment", "/upload-video", "/video", "/media", "/s", "/music"),
        "媒体域：上传、转码状态、封面帧、文件/视频读取、分享页",
    ),
    ModuleSpec(
        "member",
        H_MEMBER,
        ("/member",),
        "社区会员：套餐、支付、兑换码、订单与权益",
    ),
    ModuleSpec(
        "feedback",
        H_FEEDBACK,
        ("/feedback",),
        "用户反馈",
    ),
    ModuleSpec(
        "invite",
        H_INVITE,
        ("/invite",),
        "邀请返现：邀请码、点击归因、手机号验证、返佣台账、提现与审核",
    ),
    ModuleSpec(
        "af",
        H_AF,
        ("/af",),
        "AI 助手：会话、消息、模型/供应商、额度、文件、账单",
    ),
    ModuleSpec(
        "ai_bot",
        H_AI_BOT,
        ("/ai-bot", "/admin/ai-bot"),
        "流小萤社区 AI：公开资料、自主发布策略、排期与动作记录",
    ),
    ModuleSpec(
        "site",
        H_SITE_ADMIN,
        ("/site", "/admin/site"),
        "官网内容：公开读取站点配置，管理端编辑品牌、首屏、栏目、客户端与页脚",
    ),
    ModuleSpec(
        "app_release",
        H_APP_RELEASE,
        ("/app/version", "/admin/app-releases", "/admin/upload-package"),
        "客户端版本：公开检查更新、Android/iOS 发布记录、安装包上传",
    ),
    ModuleSpec(
        "app_hot_update",
        H_APP_HOT_UPDATE,
        ("/app/hot-update", "/admin/hot-update"),
        "客户端热更新配置：维护模式、公告、功能开关、灰度与双端远程配置",
    ),
    ModuleSpec(
        "dm",
        H_DM,
        ("/dm",),
        "私信：会话、消息、已读回执",
    ),
    ModuleSpec(
        "ws",
        H_WS,
        ("/ws",),
        "WebSocket：通知与私信实时推送",
    ),
    ModuleSpec(
        "admin_api",
        H_ADMIN,
        ("/admin",),
        "社区后台：运营、审核、用户与权限（admin_apps 优先匹配）",
    ),
)

# 预留但当前无路由的领域，保留名字避免后续重复创建。
RESERVED_MODULES = (
    {
        "name": "official",
        "reason": "预留系统广播/定时消息；目前仅 common.official_msg 写库，无独立 HTTP 路由",
    },
)
