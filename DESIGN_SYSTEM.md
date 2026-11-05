# 流萤社区 · 沉浸黑设计系统（重构必读）

> 目标：把现有 Flutter 客户端全部页面改成「抖音式沉浸黑」。
> **只改视觉与版式；数据请求、状态逻辑、路由目标、参数语义一律不动。**

## 1. 设计令牌（唯一来源：`lib/design/tokens.dart`）

| 类别 | 令牌 | 说明 |
|---|---|---|
| 画布 | `AppColors.bg` `#000` | 所有页面底色，禁止再用其它背景色 |
| 抬升 | `AppColors.card` / `elevated` / `glass` | 卡片、输入框、弹层 |
| 描边 | `AppColors.border` `0x14FFFFFF` / `hairline` `0x0DFFFFFF` | 只用 0.5~1px |
| 文字 | `textPrimary` 白 / `textSecondary` 70% / `textTertiary` 45% | 三级足够 |
| 主色 | `AppColors.accent` 薄荷绿 | **只用于**：主按钮、选中态、进度、关键数字；面积 ≤10% |
| 语义 | `heart` 点赞 / `warning` 收藏 / `danger` 错误 | |
| 圆角 | `AppRadius.xs 8` / `sm 12` / `md 16` / `lg 20` / `xl 28` / `pill` | 卡片用 `lg`，弹层顶部 `24` |
| 间距 | `AppSpace.x1..x8`（4/8/12/16/20/24/32/40）、`gutter=16` | 页面左右边距固定 16 |
| 字阶 | `AppType.display/h1/h2/title/body/bodySm/label/caption/micro/numeric` | 禁止页面内写字号字面量 |
| 动效 | `AppMotion.fast 140` / `base 200` / `slow 320`；曲线 `standard` / `emphasized` | 统一 `AnimatedContainer`/`AnimatedSwitcher` |

## 2. 通用组件（唯一来源：`lib/design/components.dart`）

| 组件 | 用途 |
|---|---|
| `ImmersivePage` | 页面骨架：纯黑 + 透明系统栏（替代 `Scaffold`） |
| `ImmersiveScroll` | 内容页滚动容器（自动处理顶部安全区 + 底部导航留白） |
| `GlassTopBar` | 顶栏：透明/毛玻璃/悬浮胶囊三种形态（`showBack`、`actions`） |
| `PillButton` | 唯一按钮形态：`primary/tonal/ghost/danger` × `sm/md/lg`，含 `loading` |
| `IconCircleButton` | 圆形图标按钮（顶栏、悬浮操作） |
| `PressableScale` | 点击缩放反馈（所有可点元素外层） |
| `TagPill` / `TagRail` | 话题、版块、筛选标签 |
| `FeedTabs` | 大标题分段（关注/推荐式，带下划线指示） |
| `AppAvatar` | 头像（`ring` 管理员描边、`name` 占位字） |
| `SkeletonBox` / `FeedSkeleton` | 骨架屏 |
| `EmptyState` / `ErrorState` / `LoadMoreFooter` | 空态 / 错误 / 加载更多 |
| `SheetShell` | 底部弹层外壳（抓手 + 标题 + 关闭） |
| `SectionHeader` / `ListRow` / `Hairline` / `StatTile` / `SearchPill` | 通用块 |
| `showAppToast(context, msg)` | 轻提示（替代裸 SnackBar） |
| `formatCount(n)` | 1.2万 缩写 |

## 3. 内容卡片

- 信息流统一用 `lib/widgets/post_card.dart` 的 `PostCard`（全幅媒体 + 底部渐变叠加 + 右侧竖排操作栏）。
- 网格（我的作品/收藏）用 `PostGridTile`。
- 不允许再新建第二套帖子卡片样式。

## 4. 硬性规则

1. **不新增依赖**（`pubspec.yaml` 不动）。
2. **不改** `lib/api/**`、`lib/models/**`、`lib/services/**` 的逻辑与签名。
3. **不改** 页面类的类名、构造参数、公开方法名（其它页面在 import / push）。
4. 页面内禁止 `Colors.black`/`Colors.white` 之外的硬编码颜色；要透明用 `Colors.white.withValues(alpha: x)`（**不要** `withOpacity`，已弃用）。
5. 字号/圆角/间距一律走 `AppType` / `AppRadius` / `AppSpace`。
6. 所有可点元素包 `PressableScale` 或使用现成组件，保留原有点击回调。
7. 空态/错误态用 `EmptyState` / `ErrorState`，不要自己写居中大图标 + 文案。
8. 弹层统一 `showModalBottomSheet(isScrollControlled: true, backgroundColor: Colors.transparent, builder: (_) => SheetShell(...))`。
9. 顶栏统一 `GlassTopBar`（沉浸页用 `floating: true`，二级页用 `solid: true`）。
10. 保持原有 `const`/`const` 可行性，减少无谓重建；列表项尽量 `RepaintBoundary`。

## 5. 参考实现（已完成，照此风格）

- `lib/main.dart`（启动页：纯黑 + 薄荷光晕 + 交叉淡化）
- `lib/pages/root_page.dart`（底部导航：毛玻璃 + 中间薄荷圆钮）
- `lib/pages/home/home_page.dart`（首页：标题 + 分段 + 运营胶囊 + 全幅 PostCard）
- `lib/widgets/post_card.dart`（沉浸卡）
- `lib/widgets/banner_carousel.dart`（全幅 Banner）

## 6. 页面版式基线

- **列表页**：`ImmersivePage` + `GlassTopBar(solid: true)` + 16 边距列表；行高 ≥56，行间用 `Hairline` 或 12 间距。
- **详情页**：全幅媒体置顶 + 浮动返回按钮（`GlassTopBar(floating: true)`）+ 正文 16 边距 + 底部输入条（贴底、黑底、圆角胶囊）。
- **我的页**：大标题 + 头像/昵称/签名 + 统计行（`StatTile`）+ 分段（作品/收藏/稍后看）+ `PostGridTile` 三列网格。
- **消息页**：会话/通知用 `ListRow`（头像 + 标题 + 摘要 + 时间 + 未读 `CountBadge`）；分组用 `FeedTabs`。
- **表单页**：黑底 + 分组卡片（`AppColors.card` + `border` + `AppRadius.lg`）+ 底部主按钮 `PillButton(expand: true)`。
