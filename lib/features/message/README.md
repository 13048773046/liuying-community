# 消息域前端分层（试点）

## 目录

```
lib/features/message/
  data/message_repository.dart   # 唯一数据入口，封装 ApiClient
  README.md
```

## 规则

1. 页面禁止直接调用 `ApiClient` 的通知/私信方法；统一走 `MessageRepository.instance`。
2. 页面只负责渲染、交互和本地 UI 状态；请求参数、错误、缓存、重试属于 repository。
3. 新增消息接口时先加 repository 方法，再改页面；不要在页面里拼 URL。
4. 保持 `ApiClient.baseOverride` 能力，E2E 仍可通过它把整个仓库接到真实本地后端。
5. 下一阶段把 `message_page`、`notif_list_page`、`dm_chat_page` 的请求状态收进 Controller；本轮先完成数据层收口，降低迁移风险。

## 迁移顺序

- 消息域（本试点）
- 首页/发现域
- 发布域
- 我的/资料域
- 应用市场域

每个域迁完必须跑对应 widget/golden 与 `test/message_e2e_test.dart`，避免只改目录不改行为。
