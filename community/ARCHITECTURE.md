# 流萤社区后端架构

> 目标：让请求入口、领域边界、配置、日志、错误和事务都有唯一归属；新增功能不需要改 `server.py`，排障不需要靠 grep。

## 1. 分层

```
HTTP socket
   │
server.py                 只做 HTTP 传输：解析、请求体、CORS、响应写回
   │
app.py                    应用层：请求 ID、访问日志、health/ready/version、
   │                      静态页、请求级事务、统一异常、404
   │
core/router.py            模块级路由：按 routes.py 的前缀清单选择领域
   │
routes.py                 领域所有权的唯一事实来源
   │
handlers/<domain>.py      领域内精确路由 + 参数校验 + 业务编排
   │
common.py / schema.py     共享数据访问、装饰器、建表与迁移
```

约束：

- `server.py` 不出现业务路径、不直接调用 handler。
- `routes.py` 不写业务逻辑，只登记 `ModuleSpec(name, module, prefixes, description)`。
- 同一路径命中多个前缀时，按 `MODULES` 顺序决定优先级；重叠必须在 `routes.py` 注释说明。
- handler 仍返回 `True/False`：`True` 表示已消费并已写响应，`False` 交给后续匹配模块。

## 2. 请求生命周期

1. `Handler._route` 记录 `Content-Length`，调用 `Application.handle`。
2. `Application` 生成/透传 `X-Request-Id`，写入日志上下文。
3. 非 API 路径：health/ready/version → 静态页 → 404。
4. API 路径：打开请求级连接，解析 uid（仅用于日志），按路由清单分发。
5. handler 内可自行 `commit`；请求结束时 `request_connection` 统一 `commit`，异常统一 `rollback` 并 close。
6. 无论成功/失败，`finally` 排空未读请求体，避免 HTTP/1.1 keep-alive 被污染。
7. 访问日志统一字段：`method/path/status/duration_ms/ip/uid/route/request_id`。

## 3. 新增接口

1. 判断领域：已有 handler 能覆盖就在原文件加精确路由；新领域新建 `handlers/<domain>.py`。
2. 实现 `dispatch(self, c, u, api, method) -> bool`，路径必须精确匹配，不要写宽泛 `startswith` 兜底。
3. 在 `routes.py` 登记 `ModuleSpec`，写清 `name`、`prefixes`、`description`。
4. 鉴权、限流、参数校验在 handler 内完成；跨表事务沿用 `c.commit()` 或 `core.db.request_connection`。
5. 错误优先抛 `core.errors.ApiError(status, message, code)`；旧接口继续 `_err` 也可。
6. 至少补一个架构自检或冒烟断言；涉及持久写/权限/外部副作用时补真实链路验证。

## 4. 配置

全部环境变量在 `core/settings.py` 读取，启动时校验：

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMMUNITY_DB` | `/www/wwwroot/yosar-data/db/tracks.db` | SQLite 路径 |
| `COMMUNITY_HOST` | `127.0.0.1` | 监听地址 |
| `COMMUNITY_PORT` | `8790` | 监听端口，非法整数启动失败 |
| `COMMUNITY_API_PREFIX` | `/community/api` | 必须以 `/` 开头 |
| `COMMUNITY_VERSION` | `0.9.21` | `/version` 返回 |
| `COMMUNITY_SMTP_CONFIG` | `/www/wwwroot/yosar-data/config/smtp.json` | 社区发验证码的 SMTP 配置 |
| `COMMUNITY_INSTANCE_ID` | 主机名 | 多机排障标识 |
| `COMMUNITY_LOG_LEVEL` | `INFO` | DEBUG/INFO/WARNING/ERROR/CRITICAL |
| `COMMUNITY_LOG_JSON` | `true` | true 输出 JSON 行日志 |
| `COMMUNITY_MAX_JSON_BODY` | 1 MiB | JSON 请求体上限 |
| `COMMUNITY_MAX_UPLOAD_BODY` | 64 MiB | multipart 上限 |
| `COMMUNITY_REQUEST_ID_HEADER` | `X-Request-Id` | 透传/生成请求 ID |
| `COMMUNITY_MUSIC_API` | `http://127.0.0.1:8788` | 音乐社区曲库代理上游；测试可指向不可达端口 |
| `COMMUNITY_MUSIC_PUBLIC_BASE` | `https://www.yosar.cloud/music` | 曲库兜底生成封面 URL 的公开前缀 |

## 5. 健康检查

- `GET /health`、`GET /community/api/health`：进程存活，不查库。
- `GET /ready`、`GET /community/api/ready`：连接 DB + 校验 `community_posts` 存在；失败 503。
- `GET /version`、`GET /community/api/version`：版本、API 前缀、实例、uptime。

登录兜底：`POST /community/api/auth/login`，body `{account,password}`，成功直接返回用户资料 + `token`（与音乐 token 互通）；音乐接口 5xx/不可达时客户端自动回退。

## 6. 日志与错误

- 只记录元数据，不记录 `Authorization`、请求体、密码、支付签名。
- 未预期异常：`unhandled_error` + traceback，返回 `{ok:false,error:"server error",code:"internal_error"}`。
- 路由不存在：`{ok:false,error:"api not found: ...",code:"route_not_found"}`。
- 旧客户端依赖 `ok/error`，`code` 是增量字段，不得删除旧字段。

## 7. 数据库与迁移纪律

- `community_*` 表由 `schema.py` 管理；共享 `users/tokens/follows/notifications` 只读或按授权写。
- 新表/新列必须幂等；迁移不要依赖异常吞掉失败。
- 共享表可选列（如 `users.email`）必须运行时探测，不能假设音乐库永远有该列。
- 当前 `_migrate()` 仍是 `ALTER TABLE` try 形式；下一阶段应引入 `community_schema_migrations` 版本账本，禁止直接改历史迁移。

## 8. 验证命令

```bash
python3 -m py_compile community/server.py community/app.py community/routes.py community/core/*.py
python3 -m unittest community/tests/test_architecture.py -v
python3 community/tests/community_smoke_test.py
python3 community/tests/member_smoke_test.py
python3 community/tests/app_market_smoke.py
python3 -m unittest community/tests/test_music_down_fallback.py -v
/home/user/flutter/bin/flutter test --no-pub test/message_e2e_test.dart
```

## 9. 音乐项目停服隔离（已落地）

共享数据平面（运维细节见 `docs/shared-data-plane.md`）：主库已迁到 `/www/wwwroot/yosar-data/db/tracks.db`，音乐与社区通过同一文件共享 `users/tokens/tracks/notifications`，但社区进程不依赖音乐进程。音乐 `config.json paths.db` 与 `community.service COMMUNITY_DB` 都指向该路径。

音乐进程停掉后，社区已做到（已停服实测）：

- `/music/tracks` 代理失败时直接读共享 `tracks` 表，曲库列表/搜索/分页不 502。
- 头像、背景、曲库封面、配乐由社区 `/music/{avatar,background,cover,files}` 代理，直接读 `/data-music/files`，不依赖音乐 HTTP。
- `/auth/login` 用共享 `users/tokens` 校验账号密码并签发 token；`/auth/send-email-code` + `/auth/login-email` 用共享 `email_codes` 发码/校验，新邮箱自动注册；客户端在音乐接口 5xx/不可达时自动回退。
- SMTP 配置读 `/www/wwwroot/yosar-data/config/smtp.json`，不经过音乐进程。
- 通知、关注、用户资料继续读共享表；已实测停止 `music.service` 后，社区登录、`/user/me`、`/feed`、`/music/tracks`、通知未读、头像/封面/配乐全部可用。
- 数据平面是共同依赖：如果 `/www/wwwroot/yosar-data/db/tracks.db` 被删除或损坏，社区仍无法启动；需要独立数据库服务/备份恢复，而不是音乐代码目录。

下一阶段（真正零依赖）：

1. 社区自有 `community_users` / `community_tokens`，迁移期双读，写只写社区表。
2. `community_tracks` 缓存曲库、封面与播放地址，彻底移除运行时音乐 HTTP 依赖。
3. 通知写社区自有表 + WS，不再写共享 `notifications`。
4. 全量 backfill + 观察窗口后移除对音乐 DB 的运行时读取。

两台服务器全量负载均衡前，必须把 SQLite 换成共享数据库（PostgreSQL/MySQL）或独立 DB 服务；SQLite 单文件不能跨机共享。

## 10. 回滚

- 代码回滚：保留部署前 `server.py`/`common.py`/`schema.py` 备份，`systemctl restart community.service`。
- 数据回滚：本轮架构改动不新增表、不改共享表结构；若后续引入社区自有权表，按迁移账本逐版本回退，不删除旧路径直到观察窗口结束。
