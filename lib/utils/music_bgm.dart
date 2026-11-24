/// 配乐单例：图文详情 / 短视频共用，切歌即停旧播新。
///
/// 播放模式说明：
/// - `loop=true`：整首无限循环（图集/图文短视频页用，音源播完自动从头再放）；
/// - `playFrom`：从第 0 秒重开（视频内容与配乐对齐用，视频每次循环时也调它）；
/// - 音量分两层：发布者设定的 base 音量（0-1）+ 全局静音开关，静音只是把有效音量置 0，
///   取消静音后恢复 base 音量，不丢发布者的混音比例。
library;

import 'package:just_audio/just_audio.dart';

class MusicBgm {
  MusicBgm._();
  static final MusicBgm I = MusicBgm._();

  final AudioPlayer _p = AudioPlayer();
  String? _url;
  bool _muted = false;
  double _volume = 1.0;
  bool _looping = false;

  String? get url => _url;
  bool get playing => _p.playing;
  bool get muted => _muted;
  double get volume => _volume;
  Stream<bool> get playingStream => _p.playingStream;

  /// 循环模式按调用方声明切换（详情页不循环、短视频页循环）
  Future<void> _ensureMode(bool loop) async {
    if (_looping == loop) return;
    _looping = loop;
    try {
      await _p.setLoopMode(loop ? LoopMode.all : LoopMode.off);
    } catch (_) {}
  }

  double get _effective => _muted ? 0 : _volume;

  Future<void> _applyVolume() async {
    try {
      await _p.setVolume(_effective);
    } catch (_) {}
  }

  /// 播放配乐（同一首且正在播时只更新音量/循环，不打断进度）
  Future<void> play(
    String url, {
    bool loop = false,
    double volume = 1.0,
  }) async {
    _volume = volume.clamp(0, 1).toDouble();
    await _ensureMode(loop);
    if (_url == url) {
      await _applyVolume();
      if (!_p.playing) {
        try {
          await _p.play();
        } catch (_) {}
      }
      return;
    }
    _url = url;
    try {
      await _p.stop();
      await _p.setUrl(url);
      await _applyVolume();
      await _p.play();
    } catch (_) {
      // 网络/解码失败静默：不阻断内容浏览
    }
  }

  /// 从第 0 秒播放：视频内容与配乐同一时间轴（视频起播、视频每次循环回 0 时都调它）
  Future<void> playFrom(
    String url, {
    bool loop = true,
    double volume = 1.0,
  }) async {
    _volume = volume.clamp(0, 1).toDouble();
    await _ensureMode(loop);
    if (_url != url) {
      _url = url;
      try {
        await _p.stop();
        await _p.setUrl(url);
      } catch (_) {
        return;
      }
    }
    try {
      await _applyVolume();
      await _p.seek(Duration.zero);
      await _p.play();
    } catch (_) {}
  }

  /// 视频循环回 0：配乐同步归零重放（不改 url）
  Future<void> restart() async {
    if (_url == null) return;
    try {
      await _p.seek(Duration.zero);
      await _p.play();
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _p.pause();
    } catch (_) {}
  }

  Future<void> resume() async {
    if (_url == null) return;
    try {
      await _p.play();
    } catch (_) {}
  }

  /// 运行时调整配乐音量（发布者比例之外的手动微调）
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1).toDouble();
    await _applyVolume();
  }

  /// 静音/取消静音（短视频页的静音按钮共用）
  Future<void> setMuted(bool muted) async {
    if (_muted == muted) return;
    _muted = muted;
    await _applyVolume();
  }

  Future<void> stop() async {
    _url = null;
    try {
      await _p.stop();
    } catch (_) {}
  }

  Future<void> toggle() async {
    if (_p.playing) {
      await _p.pause();
    } else {
      try {
        await _p.play();
      } catch (_) {}
    }
  }
}
