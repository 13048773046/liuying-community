// 首次进入的 3 页引导：像翻一本有层次的立体绘本。
//
// 插画、标题、卡片各自用不同的视差系数；底部胶囊指示器跟手伸缩，
// 最后一页的「开始使用」从下方弹起。用户随时可以跳过。
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';

class WelcomeGuidePage extends StatefulWidget {
  const WelcomeGuidePage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<WelcomeGuidePage> createState() => _WelcomeGuidePageState();
}

class _WelcomeGuidePageState extends State<WelcomeGuidePage> {
  final PageController _pc = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  double get _page {
    if (!_pc.hasClients) return _index.toDouble();
    return _pc.page ?? _index.toDouble();
  }

  void _finish() => widget.onDone();

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      topScrim: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _GuideBackdrop(),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _topBar(),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _pc,
                    builder: (context, _) {
                      final page = _page;
                      return PageView(
                        controller: _pc,
                        physics: const BouncingScrollPhysics(
                          parent: PageScrollPhysics(),
                        ),
                        onPageChanged: (i) => setState(() => _index = i),
                        children: [
                          for (var i = 0; i < 3; i++)
                            _GuidePage(
                              index: i,
                              page: page,
                              title: _titles[i],
                              body: _bodies[i],
                              scene: _scene(i, page),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                _bottom(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return AnimatedBuilder(
      animation: _pc,
      builder: (context, _) {
        final page = _page;
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 18, 0),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.22),
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 15,
                  color: Color(AppColors.accent),
                ),
              ),
              const SizedBox(width: 9),
              const Text(
                '流萤社区',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.textSecondary),
                ),
              ),
              const Spacer(),
              IgnorePointer(
                ignoring: page >= 1.7,
                child: AnimatedOpacity(
                  opacity: page < 1.7 ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _finish,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 4,
                      ),
                      child: Text(
                        '跳过',
                        style: AppType.caption.copyWith(
                          color: const Color(AppColors.textTertiary),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bottom() {
    return AnimatedBuilder(
      animation: _pc,
      builder: (context, _) {
        final page = _page;
        final atEnd = page > 1.72;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            26,
            2,
            26,
            18 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dots(page),
              const SizedBox(height: 16),
              if (!atEnd)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '左右滑动，翻一页',
                      style: AppType.caption.copyWith(
                        color: const Color(AppColors.textTertiary),
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 13,
                      color: Color(AppColors.textTertiary),
                    ),
                  ],
                ),
              AnimatedSlide(
                offset: Offset(0, atEnd ? 0 : 0.9),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: atEnd ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _finish,
                    child: Container(
                      width: double.infinity,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(AppColors.accent),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(AppColors.accent)
                                .withValues(alpha: 0.28),
                            blurRadius: 22,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '开始使用',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(AppColors.onAccent),
                              letterSpacing: 0.4,
                            ),
                          ),
                          SizedBox(width: 7),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 17,
                            color: Color(AppColors.onAccent),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _dots(double page) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 3; i++)
          AnimatedBuilder(
            animation: _pc,
            builder: (context, _) {
              final d = (page - i).abs();
              final near = (1 - d).clamp(0.0, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 6 + 16 * near,
                height: 6,
                decoration: BoxDecoration(
                  color: Color.lerp(
                    const Color(AppColors.textTertiary),
                    const Color(AppColors.accent),
                    near,
                  ),
                  borderRadius: BorderRadius.circular(99),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _scene(int i, double page) {
    final d = page - i;
    switch (i) {
      case 0:
        return _SceneBook(
          delta: d,
          back: _PostCard(
            width: 212,
            height: 150,
            angle: -0.10,
            color: const Color(0xFF151C1B),
            label: '今晚，去花甸听风',
            tone: const Color(0xFF4CD9A5),
          ),
        );
      case 1:
        return _ScenePeople(delta: d);
      default:
        return _SceneStart(delta: d);
    }
  }

  static const _titles = ['把喜欢的事\n留在流萤', '在同一条时间线\n遇见同频的人', '从今天开始\n留下第一行'];
  static const _bodies = [
    '记录一朵花、一首歌、一个不想睡的夜晚。这里没有陌生人，只有还没遇见的同频。',
    '关注喜欢的人，发现新的版块，也把今天的小事写进社区。',
    '拍一张照片，写一句话。你的主页会慢慢长成你的样子。',
  ];
}

class _GuidePage extends StatelessWidget {
  const _GuidePage({
    required this.index,
    required this.page,
    required this.title,
    required this.body,
    required this.scene,
  });

  final int index;
  final double page;
  final String title;
  final String body;
  final Widget scene;

  @override
  Widget build(BuildContext context) {
    final d = (page - index).abs();
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            '0${index + 1} / 03',
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 2.2,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 338,
            width: double.infinity,
            child: Transform.translate(
              offset: Offset(d * -22, 0),
              child: scene,
            ),
          ),
          const SizedBox(height: 18),
          Transform.translate(
            offset: Offset(d * -30, 0),
            child: Opacity(
              opacity: (1 - d).clamp(0.0, 1.0),
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 28,
                  height: 1.2,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Opacity(
            opacity: (1 - d).clamp(0.0, 1.0),
            child: Text(
              body,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.72,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 场景 01
class _SceneBook extends StatelessWidget {
  const _SceneBook({required this.delta, required this.back});

  final double delta;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          top: 42,
          left: 16,
          child: Transform.translate(
            offset: Offset(delta * -38, 0),
            child: Transform.rotate(angle: -0.015, child: back),
          ),
        ),
        Positioned(
          top: 0,
          right: 6,
          child: Transform.translate(
            offset: Offset(delta * -58, 0),
            child: Image.asset(
              'assets/characters_v2/c01_mint.png',
              height: 324,
              fit: BoxFit.contain,
            ),
          ),
        ),
        Positioned(
          left: 0,
          bottom: 2,
          child: Transform.translate(
            offset: Offset(delta * -20, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.nightlight_round,
                    size: 12,
                    color: Color(AppColors.lilac),
                  ),
                  SizedBox(width: 6),
                  Text(
                    '今晚 01:24 · 夜航',
                    style: TextStyle(fontSize: 9.5, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 4,
          top: 4,
          child: Transform.translate(
            offset: Offset(delta * -72, 0),
            child: Image.asset('assets/deco/sakura.png', width: 38),
          ),
        ),
      ],
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.width,
    required this.height,
    required this.angle,
    required this.color,
    required this.label,
    required this.tone,
  });

  final double width;
  final double height;
  final double angle;
  final Color color;
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 86,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tone.withValues(alpha: 0.55),
                    const Color(0xFF10221C),
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: 8,
                    top: 7,
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 14,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '山栀 · 刚刚',
              style: TextStyle(
                fontSize: 8,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 场景 02
class _ScenePeople extends StatelessWidget {
  const _ScenePeople({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 0,
          top: 32,
          child: Transform.translate(
            offset: Offset(delta * -32, 0),
            child: Transform.rotate(
              angle: -0.04,
              child: _MiniPerson(
                name: '山栀',
                line: '把风声收进照片墙',
                tone: const Color(0xFF4CD9A5),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 30,
          child: Transform.translate(
            offset: Offset(delta * -54, 0),
            child: Transform.rotate(
              angle: 0.05,
              child: _MiniPerson(
                name: '阿萤',
                line: '今晚想写一首短短的歌。',
                tone: const Color(0xFF9D8CFF),
                alignEnd: true,
              ),
            ),
          ),
        ),
        Positioned(
          top: 82,
          right: 82,
          child: Transform.translate(
            offset: Offset(delta * -78, 0),
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFF263D35), Color(0xFF101615)],
                ),
                border: Border.all(
                  color: const Color(AppColors.accent).withValues(alpha: 0.55),
                  width: 1.5,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x664CD9A5),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset('assets/ai/xiaoying.png', fit: BoxFit.cover),
            ),
          ),
        ),
        Positioned(
          top: 30,
          right: 26,
          child: Transform.translate(
            offset: Offset(delta * -60, 0),
            child: Container(
              padding: const EdgeInsets.fromLTRB(11, 9, 12, 9),
              decoration: BoxDecoration(
                color: const Color(0xFF161C1B),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: const Color(0x22FFFFFF)),
              ),
              child: const Text(
                '晚上好，\n今天想记录什么？',
                style: TextStyle(
                  fontSize: 9.5,
                  height: 1.45,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 18,
          child: Image.asset('assets/deco/stars.png', width: 52),
        ),
      ],
    );
  }
}

class _MiniPerson extends StatelessWidget {
  const _MiniPerson({
    required this.name,
    required this.line,
    required this.tone,
    this.alignEnd = false,
  });

  final String name;
  final String line;
  final Color tone;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 174,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF141918),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        textDirection: alignEnd ? TextDirection.rtl : TextDirection.ltr,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [tone.withValues(alpha: 0.55), const Color(0xFF202825)],
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              name.characters.first,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: tone,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: alignEnd
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 场景 03
class _SceneStart extends StatelessWidget {
  const _SceneStart({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          top: 30,
          child: Transform.translate(
            offset: Offset(delta * -40, 0),
            child: Container(
              width: 232,
              height: 232,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(AppColors.accent).withValues(alpha: 0.20),
                    const Color(AppColors.accent).withValues(alpha: 0.03),
                    Colors.transparent,
                  ],
                  stops: const [0.1, 0.6, 1],
                ),
                border: Border.all(
                  color: const Color(AppColors.accent).withValues(alpha: 0.16),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 74,
          left: 56,
          child: Transform.translate(
            offset: Offset(delta * -56, 0),
            child: Transform.rotate(
              angle: -0.10,
              child: _Polaroid(tone: const Color(0xFF4CD9A5), label: '我的第一条动态'),
            ),
          ),
        ),
        Positioned(
          top: 54,
          right: 34,
          child: Transform.translate(
            offset: Offset(delta * -74, 0),
            child: Transform.rotate(
              angle: 0.10,
              child: _Polaroid(tone: const Color(0xFF9D8CFF), label: '今天的风'),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          right: 8,
          child: Transform.translate(
            offset: Offset(delta * -92, 0),
            child: Image.asset('assets/deco/notes.png', width: 72),
          ),
        ),
        Positioned(
          top: 2,
          left: 14,
          child: Image.asset('assets/deco/moon.png', width: 46),
        ),
      ],
    );
  }
}

class _Polaroid extends StatelessWidget {
  const _Polaroid({required this.tone, required this.label});

  final Color tone;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      padding: const EdgeInsets.fromLTRB(7, 7, 7, 9),
      decoration: BoxDecoration(
        color: const Color(0xFFEDEAE2),
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 94,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tone.withValues(alpha: 0.62), const Color(0xFF18211F)],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 20,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w600,
              color: Color(0xFF33352F),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideBackdrop extends StatelessWidget {
  const _GuideBackdrop();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(AppColors.bg)),
        Positioned(
          top: -120,
          left: -90,
          child: _orb(320, const Color(0xFF4CD9A5), 0.11),
        ),
        Positioned(
          bottom: -90,
          right: -110,
          child: _orb(360, const Color(0xFF9D8CFF), 0.10),
        ),
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xCC0A0B0C)],
                  stops: [0.55, 1],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _orb(double size, Color color, double alpha) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}
