# 流萤社区 · UI 重做说明（沉浸黑）

- 版本：v1（2026-11-04）
- 范围：Flutter 客户端（`liuying-community/lib`）全部页面
- 原则：**只重做视觉与版式，数据请求 / 状态逻辑 / 路由目标 / 接口参数一律不动**

## 1. 设计语言

抖音式沉浸黑：

| 维度 | 做法 |
|---|---|
| 画布 | 纯黑 `#000000`，内容全幅延伸到状态栏/导航栏下方 |
| 层级 | 不靠阴影，靠白色透明度叠层：`card #101012` / `elevated #17171A` / `border 8%白` / `hairline 5%白` |
| 主色 | 薄荷绿 `#45E0AE`，只用于主按钮、选中态、进度、关键数字，面积 ≤10% |
| 文字 | 三级白：100% / 70% / 45%；大标题 800 字重、负字距 |
| 媒体 | 全幅图/视频 + 上下渐变遮罩（保证叠加文字可读） |
| 圆角 | 卡片 20 / 弹层顶部 24 / 标签胶囊 999 |
| 动效 | 140 / 200 / 320ms，easeOutCubic 为主；点击统一 `PressableScale` 缩放反馈 |
| 弹层 | 统一底部弹层（抓手 + 标题 + 关闭），黑底 24 圆角 |

## 2. 新增文件

| 文件 | 内容 |
|---|---|
| `lib/design/tokens.dart` | 设计令牌：`AppColors` `AppType` `AppSpace` `AppRadius` `AppMotion` `AppEffects` + 全局 `ThemeData`（`buildImmersiveTheme()`） |
| `lib/design/components.dart` | 通用组件：`ImmersivePage` `ImmersiveScroll` `GlassTopBar` `PillButton` `IconCircleButton` `PressableScale` `TagPill/TagRail` `FeedTabs` `AppAvatar` `SkeletonBox/FeedSkeleton` `EmptyState` `ErrorState` `LoadMoreFooter` `SheetShell` `SectionHeader` `ListRow` `StatTile` `SearchPill` `Hairline` `showAppToast()` `formatCount()` |
| `lib/widgets/post_card.dart` | 沉浸式内容卡 `PostCard`（全幅媒体 + 底部作者/正文/话题 + 右侧竖排操作栏）+ 网格小卡 `PostGridTile` |
| `DESIGN_SYSTEM.md` | 设计系统规则（后续改 UI 必读） |
| `UI_REDESIGN.md` | 本文档 |

`lib/config.dart` 里的 `AppTheme` 退化为**兼容别名层**（值全部指向 `AppColors`），旧页面无需一次性迁移即可继承新配色；新代码一律直接用 `AppColors/AppType/AppSpace/AppRadius`。

## 3. 页面改造清单（全部页面）

| 页面 | 改了什么 |
|---|---|
| 启动页 `main.dart` | 纯黑 + 薄荷光晕 + 圆角 Logo + 字距标语；420ms 最短展示 → 380ms 交叉淡化进主界面；全局 `ThemeData` 换 `buildImmersiveTheme()`；系统栏 edge-to-edge 全透明；渲染异常页同步改黑 |
| 底部导航 `root_page.dart` | 毛玻璃半透明导航条（短视频页全透明只留渐变）+ 中间薄荷绿圆钮（短视频/发布二态）+ 消息未读红点；高度统一 58；保留 `shortsCenterBtn` Key |
| 首页 `home_page.dart` | 品牌标题 + 任务/搜索/发布三圆钮 → 关注·推荐大标题分段（下划线指示器）→ 运营胶囊（话题/排行榜/签到）→ 全幅 Banner → 单列沉浸 `PostCard` 信息流；骨架/空态/错误态组件化 |
| 短视频 `shorts_page.dart` | `ImmersivePage` + 悬浮顶栏 + 骨架/空态；`PageView` 垂直滚动 / `allowImplicitScrolling` / `onPageChanged` 原样 |
| 视频卡 `video_card.dart` | 只换令牌（颜色/字阶/间距、`withOpacity → withValues`）；控制器生命周期、BGM 同步、图集 `1/3` 页码未动 |
| 帖子详情 `post_detail.dart` | `ImmersivePage`；玻璃浮层顶栏（作者头像 + 关注胶囊 + 圆形返回）；图片媒体 16 边距 + 20 圆角（视频仍全幅）；底部胶囊输入 + 心疼/评论/收藏/分享同排；评论行 `AppAvatar`；收藏/分享弹层改 `SheetShell` |
| 发布页 `post_editor.dart` | 黑底无边框编辑区 + 玻璃顶栏（关闭）+ 图文/短视频分段 + 3 列图片网格（角标删除）+ 版块/话题/投票/配乐统一 `SheetShell` + 底部固定发布条；上传/转码轮询/校验流程原样 |
| 评论弹窗 `comment_sheet.dart` | `SheetShell(title: '评论 N')` + 新评论行 + 黑底胶囊输入；`pureInput`/`light`/`autoInputWhenEmpty` 三模式保留 |
| 消息 `message_page.dart` | 大标题「消息」+ `FeedTabs(全部/私信)` + 互动/官方入口 `ListRow`（未读 `CountBadge`）+ 私信会话平铺；WS 订阅逻辑不变 |
| 互动通知 `notif_list_page.dart` | `GlassTopBar` + `ListRow` 行（字母头像/类型图标 + 未读点 + 时间）+ `Hairline` 分隔；`buildNotifTile` 签名未变 |
| 官方通知 `official_messages_page.dart` | `GlassTopBar` + 常驻提示 + 左对齐气泡卡 + 空/错态 |
| 私信列表/聊天 `dm_conversations_page.dart` / `dm_chat_page.dart` | `ListRow` 会话行（`CountBadge`/未读点）；聊天页纯黑 + 悬浮顶栏 + 时间分组气泡（我薄荷实心右 / 对方 `elevated` 左）+ 贴底胶囊输入；图片/视频/定位/名片渲染保留 |
| 定位选点 `location_picker_page.dart` | 黑底 `flutter_map` + 悬浮顶栏/搜索胶囊 + 底部确认区 `PillButton` |
| 我的 `mine_page.dart` | 大标题 + 头像/昵称/签名（保留用户背景图 + 黑蒙层）+ `StatTile` 统计行 + `FeedTabs`（作品/收藏/稍后看）+ 三列 `PostGridTile` |
| 资料编辑 / 审核 / 头像框 / 任务中心 / 用户列表 / 登录 / 设置 | 统一 `GlassTopBar` + 分组卡片 + `ListRow`/`TagRail`/`PillButton`；拒绝审核改 `SheetShell`；设置页危险操作 `PillVariant.danger`；业务逻辑未动 |
| 版块 `boards_page.dart` / `board_feed_page.dart` | 一级 `TagRail` + 二级 `TagPill` + 三列 `PostGridTile`；`BoardFeedGrid` 接口与分页不变 |
| 发现 `ranking_page.dart` / `topic_page.dart` / `topic_detail_page.dart` | 排行榜前三名大号数字 + `ListRow`；话题云 `TagPill`；话题详情 `PostCard` 单列 |
| 搜索 `search_page.dart` | 顶部悬浮黑底圆角输入框（280ms 防抖/联想/历史逻辑原样）+ 热词与历史 `TagPill` + 结果 `ListRow` |
| 收藏 `favorites_page.dart` | `FeedTabs`（收藏/稍后看）+ 三列 `PostGridTile` + `EmptyState` |
| 反馈 `feedback_page.dart` | `GlassTopBar` + 黑底描边表单卡 + 类型 `TagPill` + `PillButton(expand)` |
| 用户主页 `user_profile.dart` | `GlassTopBar` + `AppAvatar`/`StatTile` + 关注·私信 `PillButton` + `FeedTabs` + 三列网格 |
| 通用 widget | `waterfall_card` 黑底无边框 14 圆角；`user_avatar` 委托 `AppAvatar`；`image_box` 用 `ImagePlaceholder`；`video_controls_bar` 细白进度条 + 黑底胶囊；`emoji_panel` 分类 + 4 列网格；`poll_card` 比例进度条；`input_panel_host` 仅换底色 |
| 原生层 | Android 启动主题/窗口背景纯黑（含 night / v31，消除启动白闪）；iOS `LaunchScreen` 背景纯黑 |

## 4. 一致性规则（摘）

1. 页面骨架只用 `ImmersivePage`；二级页顶栏只用 `GlassTopBar`。
2. 按钮只用 `PillButton` / `IconCircleButton`；可点元素包 `PressableScale`。
3. 空态/错误/加载更多只用 `EmptyState` / `ErrorState` / `LoadMoreFooter`。
4. 弹层只用 `showModalBottomSheet(backgroundColor: Colors.transparent)` + `SheetShell`。
5. 颜色/字号/间距/圆角一律走令牌；禁止 `withOpacity`（用 `.withValues(alpha:)`）。
6. 帖子内容卡只有 `PostCard` 一种形态；网格只有 `PostGridTile` 一种。

## 5. 验证（本机实测通过）

本机装了 Flutter 3.47.7（`_tools/flutter`，pub 走国内镜像），实际执行结果：

| 校验 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **exit 0 —— "No issues found!"** |
| Widget 测试 | `flutter test` | **exit 0 —— 14 passed / 0 failed** |
| 自动修复 | `dart fix --apply` | 修掉 74 条 info（underscores / null-aware / final 字段等），剩 1 条文档注释手动修 |
| 结构体检 | `_dl/dart_sanity.py` | 52 个 Dart 文件 0 问题 |
| 页面覆盖 | — | 30 文件用 `ImmersivePage`、22 用 `GlassTopBar` |
| CI 打包 | `build-community` @ `ui/immersive-black` | Android APK + iOS 未签名 IPA |

> 环境小坑：项目路径含中文时，`flutter analyze` 内置 LSP 通道会 `FormatException`、`flutter test` 的 impellerc 找不到 shader include。用 `subst X: <workspace>` 映射一个 ASCII 盘符后两者均正常（CI 在 ASCII 路径下无此问题）。

> 顺带修复：仓库快照里 `lib/widgets/poll_card.dart` 的 import 层级写错（`../../` 应为 `../`），会导致编译失败，已修正；`lib/pages/shorts/comment_sheet.dart`（337 行死代码）已删除。

## 6. 已知风险 / 后续

- 已推送分支 `ui/immersive-black`（最终 commit `9ab37d7`）并触发 `build-community`：Android APK + iOS 未签名 IPA 由仓库 CI 产出。
- 提交内容不含本地生成物（`GeneratedPluginRegistrant.*`、`Generated.xcconfig`、`pubspec.lock`、测试库均保持远端原样）。
- 深色单主题：暂未做浅色模式与主题切换。
- 真机验收建议：iPhone 刘海机型看顶栏避让、Android 看键盘弹出时底部输入条、低端机看首页大图滚动帧率。
- 设计系统预览页（styleguide）未加；需要可视化验收时建议单独加 `lib/pages/dev/ui_kit_page.dart`。
