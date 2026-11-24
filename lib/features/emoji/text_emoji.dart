/// 流萤文字表情：正文里的 [表情名] 直接按小图内嵌渲染，
/// 与 😜 一样属于文本的一部分，不是单独图片消息。
library;

import 'package:flutter/material.dart';

class TextEmojiDef {
  const TextEmojiDef({
    required this.id,
    required this.code,
    required this.asset,
  });

  final String id;
  final String code;
  final String asset;

  /// 同一张表情在服务端的图片路径：私信/评论按“正常图片表情”发送时用它。
  /// 本地 asset 只负责面板里的秒开预览，不参与消息落库。
  String get imagePath => 'emoji_official/liuying/$id.webp';
}

/// 历史私信/评论里存的是 128 PNG 路径；渲染时换成同 id 的 1024 WebP，
/// 让旧内容也走高清资源。服务端保留旧 PNG，老客户端不会 404。
String upgradeEmojiMediaPath(String path) {
  final match = RegExp(
    r'emoji_official/liuying/(ly\d{2})\.png$',
  ).firstMatch(path);
  if (match == null) return path;
  return 'emoji_official/liuying/${match.group(1)}.webp';
}

const String kTextEmojiCategory = '流萤表情';

const List<TextEmojiDef> kTextEmojis = [
  TextEmojiDef(
    id: 'ly01',
    code: '开心大笑',
    asset: 'assets/emoji_text/01_开心大笑.webp',
  ),
  TextEmojiDef(
    id: 'ly02',
    code: '温柔微笑',
    asset: 'assets/emoji_text/02_温柔微笑.webp',
  ),
  TextEmojiDef(
    id: 'ly03',
    code: '兴奋雀跃',
    asset: 'assets/emoji_text/03_兴奋雀跃.webp',
  ),
  TextEmojiDef(
    id: 'ly04',
    code: '眨眼比耶',
    asset: 'assets/emoji_text/04_眨眼比耶.webp',
  ),
  TextEmojiDef(id: 'ly05', code: '星星眼', asset: 'assets/emoji_text/05_星星眼.webp'),
  TextEmojiDef(
    id: 'ly06',
    code: '害羞捂脸',
    asset: 'assets/emoji_text/06_害羞捂脸.webp',
  ),
  TextEmojiDef(
    id: 'ly07',
    code: '心动喜欢',
    asset: 'assets/emoji_text/07_心动喜欢.webp',
  ),
  TextEmojiDef(
    id: 'ly08',
    code: '生气鼓脸',
    asset: 'assets/emoji_text/08_生气鼓脸.webp',
  ),
  TextEmojiDef(
    id: 'ly09',
    code: '愤怒大吼',
    asset: 'assets/emoji_text/09_愤怒大吼.webp',
  ),
  TextEmojiDef(
    id: 'ly10',
    code: '委屈巴巴',
    asset: 'assets/emoji_text/10_委屈巴巴.webp',
  ),
  TextEmojiDef(
    id: 'ly11',
    code: '放声大哭',
    asset: 'assets/emoji_text/11_放声大哭.webp',
  ),
  TextEmojiDef(
    id: 'ly12',
    code: '抽泣哽咽',
    asset: 'assets/emoji_text/12_抽泣哽咽.webp',
  ),
  TextEmojiDef(id: 'ly13', code: '惊讶', asset: 'assets/emoji_text/13_惊讶.webp'),
  TextEmojiDef(
    id: 'ly14',
    code: '震惊失色',
    asset: 'assets/emoji_text/14_震惊失色.webp',
  ),
  TextEmojiDef(
    id: 'ly15',
    code: '疑惑问号',
    asset: 'assets/emoji_text/15_疑惑问号.webp',
  ),
  TextEmojiDef(
    id: 'ly16',
    code: '无语汗颜',
    asset: 'assets/emoji_text/16_无语汗颜.webp',
  ),
  TextEmojiDef(
    id: 'ly17',
    code: '得意叉腰',
    asset: 'assets/emoji_text/17_得意叉腰.webp',
  ),
  TextEmojiDef(id: 'ly18', code: '打哈欠', asset: 'assets/emoji_text/18_打哈欠.webp'),
  TextEmojiDef(
    id: 'ly19',
    code: '困倦睡着',
    asset: 'assets/emoji_text/19_困倦睡着.webp',
  ),
  TextEmojiDef(
    id: 'ly20',
    code: '生病发烧',
    asset: 'assets/emoji_text/20_生病发烧.webp',
  ),
  TextEmojiDef(
    id: 'ly21',
    code: '头晕目眩',
    asset: 'assets/emoji_text/21_头晕目眩.webp',
  ),
  TextEmojiDef(id: 'ly22', code: '比心', asset: 'assets/emoji_text/22_比心.webp'),
  TextEmojiDef(id: 'ly23', code: '点赞', asset: 'assets/emoji_text/23_点赞.webp'),
  TextEmojiDef(
    id: 'ly24',
    code: '挥手打招呼',
    asset: 'assets/emoji_text/24_挥手打招呼.webp',
  ),
  TextEmojiDef(
    id: 'ly25',
    code: '握拳加油',
    asset: 'assets/emoji_text/25_握拳加油.webp',
  ),
  TextEmojiDef(id: 'ly26', code: '抱抱', asset: 'assets/emoji_text/26_抱抱.webp'),
  TextEmojiDef(id: 'ly27', code: '送花', asset: 'assets/emoji_text/27_送花.webp'),
  TextEmojiDef(
    id: 'ly28',
    code: '鞠躬道歉',
    asset: 'assets/emoji_text/28_鞠躬道歉.webp',
  ),
  TextEmojiDef(
    id: 'ly29',
    code: '托腮思考',
    asset: 'assets/emoji_text/29_托腮思考.webp',
  ),
  TextEmojiDef(
    id: 'ly30',
    code: '听歌陶醉',
    asset: 'assets/emoji_text/30_听歌陶醉.webp',
  ),
  TextEmojiDef(
    id: 'ly31',
    code: '开心唱歌',
    asset: 'assets/emoji_text/31_开心唱歌.webp',
  ),
  TextEmojiDef(id: 'ly32', code: '吃饼干', asset: 'assets/emoji_text/32_吃饼干.webp'),
  TextEmojiDef(id: 'ly33', code: '喝饮料', asset: 'assets/emoji_text/33_喝饮料.webp'),
  TextEmojiDef(id: 'ly34', code: '打游戏', asset: 'assets/emoji_text/34_打游戏.webp'),
  TextEmojiDef(id: 'ly35', code: '刷手机', asset: 'assets/emoji_text/35_刷手机.webp'),
  TextEmojiDef(id: 'ly36', code: '看书', asset: 'assets/emoji_text/36_看书.webp'),
  TextEmojiDef(id: 'ly37', code: '撑伞', asset: 'assets/emoji_text/37_撑伞.webp'),
  TextEmojiDef(
    id: 'ly38',
    code: '抱枕睡觉',
    asset: 'assets/emoji_text/38_抱枕睡觉.webp',
  ),
  TextEmojiDef(id: 'ly39', code: '坏笑', asset: 'assets/emoji_text/39_坏笑.webp'),
  TextEmojiDef(
    id: 'ly40',
    code: '调皮吐舌',
    asset: 'assets/emoji_text/40_调皮吐舌.webp',
  ),
  TextEmojiDef(
    id: 'ly41',
    code: '卖萌猫爪',
    asset: 'assets/emoji_text/41_卖萌猫爪.webp',
  ),
  TextEmojiDef(id: 'ly42', code: '撒娇', asset: 'assets/emoji_text/42_撒娇.webp'),
  TextEmojiDef(
    id: 'ly43',
    code: '骄傲挺胸',
    asset: 'assets/emoji_text/43_骄傲挺胸.webp',
  ),
  TextEmojiDef(
    id: 'ly44',
    code: '无奈摊手',
    asset: 'assets/emoji_text/44_无奈摊手.webp',
  ),
  TextEmojiDef(
    id: 'ly45',
    code: '惊恐尖叫',
    asset: 'assets/emoji_text/45_惊恐尖叫.webp',
  ),
  TextEmojiDef(
    id: 'ly46',
    code: '呆滞放空',
    asset: 'assets/emoji_text/46_呆滞放空.webp',
  ),
  TextEmojiDef(
    id: 'ly47',
    code: '花痴爱心',
    asset: 'assets/emoji_text/47_花痴爱心.webp',
  ),
  TextEmojiDef(
    id: 'ly48',
    code: '欢呼跳跃',
    asset: 'assets/emoji_text/48_欢呼跳跃.webp',
  ),
  TextEmojiDef(id: 'ly49', code: '嫌弃', asset: 'assets/emoji_text/49_嫌弃.webp'),
  TextEmojiDef(
    id: 'ly50',
    code: '庆祝撒花',
    asset: 'assets/emoji_text/50_庆祝撒花.webp',
  ),
];

final Map<String, TextEmojiDef> kTextEmojiByCode = {
  for (final e in kTextEmojis) e.code: e,
};

final RegExp _kEmojiToken = RegExp(r'\[([^\[\]\n]{1,12})\]');

/// 把正文切成普通文字 + 内嵌表情小图。
/// 只有命中内置表情代码才替换，普通方括号文本原样保留。
List<InlineSpan> textEmojiSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var cursor = 0;
  final size = ((base.fontSize ?? 14) * 1.38).clamp(18.0, 32.0).toDouble();
  for (final m in _kEmojiToken.allMatches(text)) {
    final code = m.group(1) ?? '';
    final def = kTextEmojiByCode[code];
    if (def == null) continue;
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start)));
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: SizedBox(
            width: size,
            height: size,
            child: Image.asset(
              def.asset,
              fit: BoxFit.contain,
              semanticLabel: code,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
    cursor = m.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  if (spans.isEmpty) spans.add(TextSpan(text: text));
  return spans;
}

/// 正文/评论/私信统一用的内嵌表情文本。
class TextEmojiText extends StatelessWidget {
  const TextEmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(style: base, children: textEmojiSpans(text, base)),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}

/// 输入框控制器：插入 [表情名]；退格落在一个完整表情内部时整段删除。
class TextEmojiEditingController extends TextEditingController {
  TextEmojiEditingController({super.text});

  bool _adjusting = false;

  void insertEmojiCode(String code) {
    if (code.isEmpty) return;
    final token = '[$code]';
    final raw = text;
    final sel = selection;
    final start = sel.isValid ? sel.start : raw.length;
    final end = sel.isValid ? sel.end : raw.length;
    value = TextEditingValue(
      text: raw.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  @override
  set value(TextEditingValue newValue) {
    if (!_adjusting && newValue.composing.isValid == false) {
      final old = super.value;
      final removed = _singleRemoved(old.text, newValue.text);
      if (removed != null) {
        final token = _tokenAround(old.text, removed);
        if (token != null) {
          final next =
              old.text.substring(0, token[0]) + old.text.substring(token[1]);
          final offset = token[0].clamp(0, next.length);
          _adjusting = true;
          super.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: offset),
          );
          _adjusting = false;
          return;
        }
      }
    }
    super.value = newValue;
  }

  /// 只处理“删掉一个字符”的退格/删除；选择整段替换走默认行为。
  List<int>? _singleRemoved(String old, String next) {
    if (old.length - next.length != 1) return null;
    var p = 0;
    while (p < old.length && p < next.length && old[p] == next[p]) {
      p++;
    }
    var s = 0;
    while (s < old.length - p &&
        s < next.length - p &&
        old[old.length - 1 - s] == next[next.length - 1 - s]) {
      s++;
    }
    final start = p;
    final end = old.length - s;
    if (end - start != 1) return null;
    return [start, end];
  }

  /// 删除字符完全落在一个已知 [表情名] 内时，返回 token 的起止。
  List<int>? _tokenAround(String text, List<int> removed) {
    if (removed[0] < 0 || removed[0] >= text.length) return null;
    var start = removed[0];
    while (start >= 0 && text[start] != '[') {
      if (text[start] == '\n') return null;
      start--;
    }
    if (start < 0) return null;
    final close = text.indexOf(']', start + 1);
    if (close < 0) return null;
    final code = text.substring(start + 1, close);
    if (kTextEmojiByCode[code] == null) return null;
    if (removed[0] < start || removed[1] > close + 1) return null;
    return [start, close + 1];
  }
}
