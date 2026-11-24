/// 官方通知富文本气泡：客户端只消费后端白名单 JSON，不解析 HTML。
///
/// 兼容：
/// - 旧通知没有 `rich`，继续按纯文本渲染；
/// - 新通知 `rich` 结构损坏时回退到 `content` / `plainText`；
/// - 链接只允许 http/https，点击走系统浏览器。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/secure_links.dart';

import '../../../design/tokens.dart';
import '../../../widgets/image_box.dart';

class OfficialRichBubble extends StatelessWidget {
  const OfficialRichBubble({
    super.key,
    required this.messageId,
    this.rich,
    required this.fallback,
  });

  final String messageId;
  final Map<String, dynamic>? rich;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks();
    if (blocks.isEmpty) {
      return Text(fallback, style: AppType.body.copyWith(height: 1.55));
    }
    final maxW = (MediaQuery.sizeOf(context).width * 0.78)
        .clamp(220.0, 620.0)
        .toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < blocks.length; i++) _block(blocks[i], i),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _blocks() {
    final raw = rich?['blocks'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) {
      return e.map((k, v) => MapEntry(k.toString(), v));
    }).toList();
  }

  Widget _block(Map<String, dynamic> block, int index) {
    final type = (block['type'] ?? '').toString();
    if (type == 'divider') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.x2),
        child: Container(height: 1, color: const Color(AppColors.border)),
      );
    }
    if (type == 'image') {
      final url = (block['url'] ?? '').toString();
      if (url.isEmpty) return const SizedBox.shrink();
      return Padding(
        key: ValueKey('official-rich-image-$messageId-$index'),
        padding: const EdgeInsets.only(
          top: AppSpace.x1,
          bottom: AppSpace.x1 + 2,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: CachedNetworkImageCompat(
            url: url,
            fit: BoxFit.fitWidth,
            borderRadius: AppRadius.sm,
            memCacheWidth: 1200,
            errorWidget: Container(
              width: 220,
              height: 110,
              color: const Color(AppColors.elevated),
              alignment: Alignment.center,
              child: Text('图片加载失败', style: AppType.micro),
            ),
          ),
        ),
      );
    }
    final spans = block['spans'];
    if (spans is! List || spans.isEmpty) return const SizedBox.shrink();
    if (type == 'quote') {
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpace.x2),
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: Color(AppColors.accent), width: 3),
          ),
        ),
        child: _RichLine(
          messageId: messageId,
          blockIndex: index,
          spans: spans,
          baseStyle: AppType.body.copyWith(
            height: 1.55,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      );
    }
    if (type == 'bullet') {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.x1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(top: 8, right: 8),
              decoration: const BoxDecoration(
                color: Color(AppColors.accent),
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: _RichLine(
                messageId: messageId,
                blockIndex: index,
                spans: spans,
                baseStyle: AppType.body.copyWith(height: 1.55),
              ),
            ),
          ],
        ),
      );
    }
    if (type == 'heading') {
      final level = block['level'] == 3 ? 3 : 2;
      return Padding(
        padding: EdgeInsets.only(
          top: index == 0 ? 0 : AppSpace.x1,
          bottom: AppSpace.x1,
        ),
        child: _RichLine(
          messageId: messageId,
          blockIndex: index,
          spans: spans,
          baseStyle: AppType.title.copyWith(
            fontSize: level == 3 ? 15.5 : 17,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.x1),
      child: _RichLine(
        messageId: messageId,
        blockIndex: index,
        spans: spans,
        baseStyle: AppType.body.copyWith(height: 1.55),
      ),
    );
  }
}

class _RichLine extends StatefulWidget {
  const _RichLine({
    required this.messageId,
    required this.blockIndex,
    required this.spans,
    required this.baseStyle,
  });

  final String messageId;
  final int blockIndex;
  final List spans;
  final TextStyle baseStyle;

  @override
  State<_RichLine> createState() => _RichLineState();
}

class _RichLineState extends State<_RichLine> {
  final _taps = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(covariant _RichLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spans != widget.spans) {
      _disposeTaps();
    }
  }

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  void _disposeTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 只在新 spans 上创建 recognizer；旧的在 didUpdateWidget 已释放。
    final built = _taps.isEmpty ? _parse() : _parse(fromCache: true);
    return Text.rich(
      TextSpan(children: built),
      key: ValueKey(
        'official-rich-line-${widget.messageId}-${widget.blockIndex}',
      ),
      style: widget.baseStyle,
    );
  }

  List<InlineSpan> _parse({bool fromCache = false}) {
    if (!fromCache) {
      for (final s in widget.spans) {
        if (s is! Map) continue;
        final url = _safeUrl(s['url']);
        if (url != null) {
          final tap = TapGestureRecognizer()
            ..onTap = () async {
              try {
                await launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {}
            };
          _taps.add(tap);
        }
      }
    }
    final out = <InlineSpan>[];
    var tapIndex = 0;
    for (final raw in widget.spans) {
      if (raw is! Map) continue;
      final text = (raw['text'] ?? '').toString();
      if (text.isEmpty) continue;
      final url = _safeUrl(raw['url']);
      final style = _spanStyle(raw);
      if (url != null) {
        final tap = tapIndex < _taps.length ? _taps[tapIndex] : null;
        tapIndex++;
        out.add(
          TextSpan(
            text: text,
            recognizer: tap,
            style: style.copyWith(
              color: const Color(AppColors.accent),
              decoration: TextDecoration.underline,
              decorationColor: const Color(AppColors.accent),
            ),
          ),
        );
      } else {
        out.add(TextSpan(text: text, style: style));
      }
    }
    return out;
  }

  TextStyle _spanStyle(Map raw) {
    var style = widget.baseStyle;
    if (raw['bold'] == true) {
      style = style.copyWith(fontWeight: FontWeight.w700);
    }
    if (raw['italic'] == true) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    if (raw['underline'] == true) {
      style = style.copyWith(decoration: TextDecoration.underline);
    }
    switch (raw['color']) {
      case 'accent':
        style = style.copyWith(color: const Color(AppColors.accent));
      case 'warning':
        style = style.copyWith(color: const Color(AppColors.warning));
      case 'danger':
        style = style.copyWith(color: const Color(AppColors.danger));
      case 'muted':
        style = style.copyWith(color: const Color(AppColors.textTertiary));
    }
    return style;
  }

  String? _safeUrl(Object? raw) {
    // 官方富文本只能跳 HTTPS；禁止 http 明文、userinfo 和 javascript/file/intent。
    return SecureLinks.httpsUrl((raw ?? '').toString());
  }
}
