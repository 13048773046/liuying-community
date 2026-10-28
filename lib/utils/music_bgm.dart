/// 配乐单例：图文详情 / 短视频共用，切歌即停旧播新。
library;

import 'package:just_audio/just_audio.dart';

class MusicBgm {
  MusicBgm._();
  static final MusicBgm I = MusicBgm._();

  final AudioPlayer _p = AudioPlayer();
  String? _url;

  String? get url => _url;
  bool get playing => _p.playing;
  Stream<bool> get playingStream => _p.playingStream;

  /// 播放新配乐（同一首不重复启动）
  Future<void> play(String url) async {
    if (_url == url) return;
    _url = url;
    try {
      await _p.stop();
      await _p.setUrl(url);
      await _p.play();
    } catch (_) {
      // 网络/解码失败静默：不阻断内容浏览
    }
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
