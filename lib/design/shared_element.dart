/// 流萤社区 · 共享元素与页面转场
///
/// 只允许从这里取 Hero tag / 路由 / 飞行壳，避免各页各写一套：
/// - [SharedElementTags]：封面、头像、应用图标、图集、话题、音乐封面；
/// - [AppHero]：统一 tag + 减弱动态效果降级；
/// - [AppPageRoute]：前进 260ms、返回 220ms，非共享内容 120ms 淡入。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class SharedElementTags {
  const SharedElementTags._();

  static String postCover(String postId) => 'post-cover-$postId';
  static String postAvatar(String uid, String postId) =>
      'post-avatar-$uid-$postId';
  static String commentAvatar(String uid, String commentId) =>
      'comment-avatar-$uid-$commentId';
  static String appIcon(String appId) => 'app-icon-$appId';
  static String galleryImage(String postId, int index) =>
      'gallery-image-$postId-$index';
  static String topicChip(String name) => 'topic-chip-$name';
  static String musicCover(String trackId) => 'music-cover-$trackId';
}

/// 共享元素飞行壳：只做透明度过渡，避免飞行中把两棵不同尺寸的子树强行拉伸。
class AppSharedElement {
  const AppSharedElement._();

  static Widget flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final toHero = toHeroContext.widget as Hero;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: toHero.child,
    );
  }
}

/// 统一 Hero 包装。系统「减弱动态效果」开启时直接返回 child，不注册飞行。
class AppHero extends StatelessWidget {
  const AppHero({
    super.key,
    required this.tag,
    required this.child,
    this.enabled = true,
  });

  final String tag;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || MediaQuery.disableAnimationsOf(context)) return child;
    return Hero(
      tag: tag,
      flightShuttleBuilder: AppSharedElement.flightShuttle,
      child: child,
    );
  }
}

/// 全站页面路由：前进 260 / 返回 220；内容整体淡入，共享元素交给 Hero。
///
/// iOS / macOS 保留系统侧滑返回：继承 [MaterialPageRoute] 后走平台自带的
/// Cupertino 手势检测，避免自定义 PageRouteBuilder 把边缘返回手势弄丢。
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog = false,
  });

  @override
  Duration get transitionDuration => AppMotion.sharedForward;

  @override
  Duration get reverseTransitionDuration => AppMotion.sharedBack;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      // 系统滑动转场 + 左边缘返回手势；时长仍由上面的 getter 控制。
      return super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(opacity: curved, child: child);
  }
}
