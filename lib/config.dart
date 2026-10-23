/// 流萤社区 · 全局配置
/// 生产环境与音乐站零侵入共存：社区 API 前缀 /community/api，媒体 /community/api/media/。
library;

/// 后端基地址（生产：www.dbmt999.asia；本地调试可改 http://127.0.0.1:8790/community）
const String kApiBase = 'https://www.dbmt999.asia/community/api';

/// 音乐站基地址（账号登录互通：读音乐 users/tokens，登录仍走音乐登录接口）
const String kMusicBase = 'https://www.dbmt999.asia/music';

/// 媒体 URL 拼接
String mediaUrl(String name) => '$kApiBase/media/$name';

/// 头像 URL（可能为空串 → 用默认占位）
String avatarUrl(String raw) => raw.isEmpty ? '' : raw;

/// 流萤系列视觉
class AppTheme {
  /// 主色：萤火虫紫
  static const int accent = 0xFF7C4DFF;

  /// 深色背景（沉浸）
  static const int bg = 0xFF0D0D12;

  /// 卡片底色
  static const int card = 0xFF17171E;

  /// 分隔线
  static const int border = 0xFF26262E;

  /// 次级文字
  static const int textSecondary = 0xFF9A9AA5;

  /// 渐变起点 / 终点
  static const int gradStart = 0xFF7C4DFF;
  static const int gradEnd = 0xFF4A90E2;
}
