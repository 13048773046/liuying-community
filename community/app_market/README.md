# 流萤社区 · 应用市场（后端）

这是应用市场后端的实现说明。应用市场与社区/音乐主服务共享 `tracks.db`，但代码、解析和下载链路独立成模块，避免把网盘解析器、下载代理和后台页面全部堆进 `server.py`。

## 1. 服务拆分

| 组件 | 目录/文件 | 监听 | 责任 |
|---|---|---|---|
| 社区主服务 | `community/` | `127.0.0.1:8790` | 应用数据、投稿、审核、评论、评分、收藏、举报、管理 API、下载 ticket 签发 |
| 应用领域包 | `community/app_market/` | 进程内 | Schema、输入校验、业务 service、公开/管理 API、ticket |
| 应用解析服务 | `services/app_resolver/app.py` | `127.0.0.1:8793` | 把官网/GitHub/网盘分享链接解析成短时直链；不访问数据库 |
| 下载网关 | `services/app_delivery/app.py` | `127.0.0.1:8792` | 校验 ticket、取内部 manifest、调用 resolver、按 Range 转发；不访问数据库 |
| 应用市场工作区 | `community/templates/admin.html` | `/community/admin.html#apps` | 社区后台内的概览、审核、分类、评论、举报；不再使用独立页面 |

主服务的 `handlers/apps.py`、`handlers/admin_apps.py` 只做薄路由；`server.py` 只增加路由和静态页入口。应用市场不导入任何第三方网盘解析库。

## 2. 下载链路

```text
客户端
  → GET/HEAD /community/api/apps/{id}/download
  → 主服务校验应用和版本均可用，签发 HMAC ticket
  → 302 /community/dl/{ticket}
  → Nginx 精确反代 /community/dl/ 到 app-delivery:8792
  → gateway 校验 ticket，请求主服务内部 manifest（X-Internal-Token）
  → gateway 调用 app-resolver（原始链接只存在于服务端）
  → gateway 按客户端 Range 转发上游字节
```

- 详情接口只返回稳定入口 `downloadUrl: /community/api/apps/{id}/download`，不返回网盘原始地址。
- ticket 默认 30 分钟，payload 为 `{v: versionId, a: appId, exp}`，使用 `APP_TICKET_SECRET` 做 HMAC-SHA256。
- 支持 `GET`、`HEAD`、`Range: bytes=start-end`、`bytes=start-`、`bytes=-suffix`；合法范围返回上游实际状态（通常 206）。
- 非法 Range 返回 416；上游忽略 Range 时如实返回 200 全量，不伪造 206。
- 正常响应包含 `Content-Range`（206 时）、`Content-Length`、`Accept-Ranges`、`ETag`、`Content-Disposition`。
- 主服务在签发 ticket 时计一次下载；同一 ticket 的多段 Range 不重复计数。
- `APP_ALLOW_PRIVATE` 只用于本地测试，生产必须为 `0` 或不设置，避免 SSRF。

## 3. 应用状态

应用：

- `0` 草稿
- `1` 待审核（**新投稿默认状态**）
- `2` 已上架
- `3` 已拒绝
- `4` 已下架

版本：

- `0` 草稿
- `1` 待审核
- `2` 已通过
- `3` 已拒绝

首次投稿时应用和版本一起进入待审。管理员通过版本后应用上架并设置 `current_version_id`。已上架应用追加新版本时，旧版本继续在线；新版本通过后切换，拒绝则保留旧版本。管理员可下架、恢复、精选；举报处理可以下架应用。

## 4. 网盘解析边界

内置 provider：

- `official`：官网直链；如果 HEAD 是 HTML 落地页，会从页面提取明确的 `.apk/.ipa/.hap/.exe/.msi/.zip` 等资源链接。
- `github`：GitHub Releases 页面/资产直链。
- `lanzou`：蓝奏云公开分享，实验性。
- `pan123`：123 云盘公开页，实验性。
- 通用公开页提取：奶牛、小飞机、139、坚果云、超星、Google Drive、Dropbox 等识别后按官网页提取处理；页面结构变化时返回明确错误，不伪造直链。
- 登录型：百度、夸克、UC、阿里、迅雷、115、光鸭、天翼。默认**不做匿名绕过、不保存共享 Cookie**；如果部署方有合法授权的解析服务，可配置 `APP_NFD_BASE_URL` 接入（需要自行审计第三方服务，不能把凭据暴露给公共端点）。

因此“支持大部分网盘”分为两种情况：公开直链/公开分享型开箱可用；登录型需要官方授权或单独的授权适配器，不能靠匿名抓取绕过。

## 5. 环境变量

复制 `deploy/app-market/env.example` 为服务端受保护的环境文件，至少设置：

| 变量 | 说明 |
|---|---|
| `APP_TICKET_SECRET` | 主服务和 gateway 必须一致；生产必须强随机 |
| `APP_INTERNAL_TOKEN` | 主服务和 gateway 必须一致；生产必须强随机 |
| `APP_TICKET_TTL` | ticket 有效期秒数，默认 1800 |
| `APP_MANIFEST_URL` | 默认 `http://127.0.0.1:8790/community/api/internal/app-download/manifest` |
| `APP_RESOLVER_URL` | 默认 `http://127.0.0.1:8793/resolve` |
| `APP_ALLOW_PRIVATE` | 生产 `0`；本地测试可临时 `1` |
| `APP_NFD_BASE_URL` | 可选；合法授权的登录型网盘解析服务 |
| `APP_NFD_PARSE_PATH` | 可选，默认 `/api/parse` |
| `APP_NFD_TOKEN` | 可选，外部解析服务内部 token |

## 6. 公开 API

所有路径前缀 `/community/api`。

- `GET /apps/categories`：大类/子分类树。
- `GET /apps?page=&pageSize=&category=&subCategory=&platform=&q=&sort=latest|hot`：已上架应用列表。
- `GET /apps/{id}`：公开详情；登录时附带 `myRating`、`favorited`。
- `GET /apps/by-user/{uid}?page=&pageSize=`：某位用户已上架的投稿应用（公开主页用，不暴露草稿/待审/驳回状态）。
- `GET/HEAD /apps/{id}/download`：下载入口，302 到 ticket 网关。
- `GET/POST /apps`：列表/投稿（投稿需登录，创建即待审核）。
- `GET /apps/mine`：我的投稿。
- `PUT /apps/{id}`：修改自己的草稿/被拒投稿。
- `POST /apps/{id}/submit`：草稿/被拒投稿提交审核。
- `GET/POST /apps/{id}/comments`；`DELETE /apps/{id}/comments/{commentId}`。
- `GET/POST /apps/{id}/rating`：评分 1–5。
- `POST/DELETE /apps/{id}/favorite`：收藏/取消收藏。
- `GET /apps/mine/favorites`：我的收藏。
- `POST /apps/{id}/report`：举报。
- `POST /apps/{id}/versions`；`PUT /apps/{id}/versions/{versionId}`；`POST /apps/{id}/versions/{versionId}/submit`。

投稿字段（camelCase）：

`name, icon, packageType（apk/ipa/hap/app/exe/msi）, packageName, categoryId, subcategoryId, screenshots[3..9], description, shareReason, downloadUrl, versionName, osVersion, shareCode`

图标和截图必须先用 `POST /community/api/upload-image` 上传，路径为 `community_img_<uid前8位>_<随机>.<ext>`；服务端不接受外部图片地址作为应用图标/截图。

## 7. 管理 API

统一使用 `X-Community-Admin-Token`（也兼容 App 登录 token 对应的管理员）。模块权限 `apps` 已在 `ADMIN_MODULES` 和前缀表中登记；已有 super/admin 默认获得，auditor 需后台勾选。

- `GET /admin/apps/stats`
- `GET /admin/apps?page=&pageSize=&status=&q=`
- `GET /admin/apps/{id}`：含版本列表
- `POST /admin/apps/{id}/review`：`{versionId, action: approve|reject, reason}`
- `POST /admin/apps/{id}/state`：`{action: offline|restore|feature}`
- `GET/POST /admin/app-categories`
- `PUT/DELETE /admin/app-categories/{id}`
- `GET /admin/app-comments`
- `POST /admin/app-comments/{id}`：`{action: hide|show}`
- `GET /admin/app-reports?status=0`
- `POST /admin/app-reports/{id}/handle`：`{action: ignore|offline}`

后台入口：`https://www.yosar.cloud/community/admin.html#apps`。应用市场已并入社区后台左侧导航的“应用市场”分组；token 存在浏览器 `localStorage` 的 `liuying_comm_admin`；提供概览、应用审核、分类、评论、举报。旧 `/community/admin-apps.html` 仅做兼容跳转，不再维护独立界面。

## 8. 部署顺序

1. 备份数据库：`tracks.db` 用 SQLite backup API 备份到同目录 `.bak-app-market-*`，不要直接复制正在写入的 WAL 主文件。
2. 上传 `app_market/`、`handlers/apps.py`、`handlers/admin_apps.py`，并更新 `schema.py`、`server.py`、`handlers/admin_api.py`、`templates/admin.html`；旧的 `templates/admin-apps.html` 替换为兼容跳转页。
3. 上传 `services/app_resolver`、`services/app_delivery`，创建受保护 env 文件。
4. 启动前执行 `init_schema()`；主服务启动时也会幂等执行。
5. 安装 `app-resolver.service`、`app-delivery.service`；重启 `community.service`。
6. Nginx 在 `/community/` 之前增加 `/community/dl/` 精确反代到 `8792`，`nginx -t` 后 reload。
7. 验证 `/health`、分类、投稿、审核、公开详情、评论/评分/收藏、`/community/api/apps/{id}/download` 和 Range。
8. 验证社区后台 `admin.html` 左侧“应用市场”分组：概览、待审核列表、审核通过/拒绝、分类、评论、举报；旧 `admin-apps.html` 只验证兼容跳转。

## 9. 已知边界

- 蓝奏/123/公开页适配依赖对方页面结构，属于实验性；失败时返回错误，不伪造成功。
- 登录型网盘不做匿名绕过；没有合法授权解析服务时，投稿仍可保存链接，但点击下载会返回“需要配置授权解析服务”。
- 不镜像安装包字节；网关只做实时转发。
- 下载 ticket 目前是无状态 HMAC；同一 ticket 在有效期内可重复使用，适合多段 Range，但无法主动吊销单张 ticket；应用下架/版本变化会在 manifest 校验时失效。
- 生产部署必须替换默认 fallback secret/token，并限制 `APP_ALLOW_PRIVATE=0`。

## 10. 本地验证

```bash
# 启动本地测试服务（需要 handlers.dm 桩，见 /tmp/run_comm_test.py）
python3 /tmp/run_comm_test.py

# 分类
curl -s http://127.0.0.1:8799/community/api/apps/categories

# 健康
curl -s http://127.0.0.1:8793/health
curl -s http://127.0.0.1:8792/health

# Range（先拿到 ticket）
curl -sI http://127.0.0.1:8799/community/api/apps/<id>/download
curl -s -D - -H 'Range: bytes=0-15' http://127.0.0.1:8792/community/dl/<ticket>
```
