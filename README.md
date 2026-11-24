# 流萤社区 (Liuying Community)

短视频 + 图文混合社区 App。Flutter 单代码库，一套代码同时产出 **Android APK** 与 **iOS（未签名）IPA**。

## 产品定位

- **账号互通**：登录走流萤音乐账号体系（`/music/api/login`），同一 token 双端可用
- **认证/头衔互通**：只读音乐 `users` 表，管理员认证 LOGO、头衔在社区全链路展示
- **会员独立**：社区会员单独一套（`community_members`），不与音乐会员互通
- **官方通知完全分离**：社区独立官方通知（`community_official_messages`），与音乐官方通知互不干扰
- **后端零侵入**：独立 `community.service`（127.0.0.1:8790），只新增 `community_*` 表与 API，不改动音乐任何表/代码，两套服务可同时运行

## 核心功能（P0）

| 模块 | 说明 |
| --- | --- |
| 短视频 | 沉浸式上下滑动切换（复刻音乐 iOS VerticalPager 交互），封面可选自传/视频抽帧 |
| 图文帖子 | 富文本 + 话题 + @提及 + 最多 3 图，可加表情包 |
| 评论 | 帖子评论与短视频评论共用，可发图、可发表情包（文字混排） |
| 互动通知 | 点赞 / 评论 / @提及 / 审核结果 / 关注，两边列表可见 |
| 等级系统 | 0~10 级，发帖/评论/视频/点赞/评论/分享按比例得经验 |
| 个性装扮 | 头像框（动/静态），H5 后台可上传素材 |
| 版块 | 多级自定义分类（子级可自由增删），首发 6 版块 |
| 管理后台 | H5 后台：审核（帖子/视频，拒绝必填理由）、置顶/精华/下架、神评、二级管理员、Banner/话题/敏感词/表情包导入、会员开通、官方通知、操作日志 |

## 配乐与音量（短视频 / 图集）

| 项 | 行为 |
| --- | --- |
| 配乐加载 | 选中配乐即刻加载并自动播放；同页切卡秒切歌，不停旧曲不叠音 |
| 原声 + 配乐 | 两者**同时播放**（不再把原声静音），直接混音 |
| 视频类配乐 | 配乐与视频**同时间轴**：视频起播配乐从 0 秒开始；视频循环回 0 时配乐同步回 0 重来 |
| 图集 / 图文配乐 | **整首无限循环**，轮播换图不重置进度 |
| 音量 | **发布者**在发布页自调：原声音量 + 配乐音量（0~100% 双滑杆），随作品存后端（`audio_volume` / `music_volume`），观众端按该比例播放 |
| 音源 | 走音乐项目 `/music/files/<name>`（支持 HTTP Range），不复制音频 |

## 目录结构

```
lib/
  api/        # HTTP 客户端（社区 + 音乐登录）
  models/     # 数据模型
  pages/
    shorts/   # 短视频页（VerticalPager 复刻）
    home/     # 首页信息流
    boards/   # 版块
    message/  # 消息（官方通知独立）
    mine/     # 我的 + 登录
    root_page # 底部导航（中间短视频入口）
community/    # 后端（Python + SQLite，独立服务）
  app_market/ # 应用市场领域包（Schema / service / API / ticket）
  handlers/   # content / feed / user / upload / ws / official / admin / apps
  templates/  # admin.html（H5 管理后台，含应用市场工作区）+ admin-apps.html（兼容跳转）+ share.html
  tests/      # 冒烟测试（98 用例）
```

## 构建

```bash
flutter pub get
flutter analyze
flutter build apk --debug        # Android
flutter build ios --release --no-codesign   # iOS 未签名（macOS）
```

CI（GitHub Actions）自动产出双端安装包：
- `community-android-apk`：Android APK
- `community-ios-unsigned-ipa`：iOS 未签名 IPA（可 sideload / 自签）

## 后端部署

独立 `community.service`，与音乐服务并存：

```bash
# 服务器（systemd）
/usr/bin/python3 /www/wwwroot/music/community/server.py   # 127.0.0.1:8790

# Nginx 追加 location（零侵入，不动音乐站点）
location /community/ { proxy_pass http://127.0.0.1:8790; ... }
```

## 应用市场（App Market）

应用市场是独立模块，不把解析器、下载代理和后台页面堆进 `community` 主服务：

| 组件 | 职责 | 默认端口 |
| --- | --- | --- |
| `community` + `app_market/` | 应用/版本/审核/评论/评分/收藏/举报/管理 API、下载 ticket 签发 | 8790 |
| `services/app_resolver/` | 网盘/官网短时直链解析，不访问数据库 | 8793 |
| `services/app_delivery/` | ticket 校验、Range 代理、内部 manifest，不访问数据库 | 8792 |
| `templates/admin.html` | 社区管理后台，内含应用市场工作区 | — |

下载链路：详情只返回稳定入口 `GET /community/api/apps/{id}/download`；点击后主服务签发 HMAC ticket 并 302 到 `/community/dl/{ticket}`；网关校验 ticket → 主服务内部 manifest → resolver 解析临时直链 → 按客户端 `Range` 转发。原始网盘地址不暴露给客户端。

投稿字段：名称、图标、安装包类型（APK/IPA/鸿蒙 HAP/Windows）、包名、版本号、大类/子类、3–9 张截图、介绍、分享感言、外部下载链接（官网/网盘）。全部投稿默认待审核，人工审核通过后上架；已上架应用追加新版本时旧版本保持在线，新版本通过后切换。

公开/用户 API：分类、投稿、我的投稿、收藏、详情、版本、评论、评分、收藏、举报、下载入口。
管理 API：统计、应用列表/详情、审核、上下架/精选、分类、评论隐藏、举报处理。
后台入口：`/community/admin.html#apps`（应用审核 / 分类 / 评论 / 举报）。旧 `/community/admin-apps.html` 仅做兼容跳转。

解析边界：官网直链、GitHub Releases 直接支持；蓝奏云/123 云盘等公开分享为实验性适配；登录型网盘（百度/夸克/UC/阿里/115/迅雷/光鸭/天翼等）不匿名绕过，配置 `APP_NFD_BASE_URL` 后走自建/授权解析服务。生产环境禁止预解析、预镜像和共享登录 Cookie。

部署与验证步骤见 `community/app_market/README.md`、`deploy/app-market/README.md`，端到端冒烟见 `community/tests/app_market_smoke.py`。
