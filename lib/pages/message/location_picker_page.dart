/// 发送位置 · 地图选点页（微信式：拖动地图，中心图钉选点）
/// 地图：flutter_map + 高德瓦片（免 key）；逆地理：bigdatacloud 免费接口（中文）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../config.dart';

/// 返回 {lat, lng, name, address}；取消返回 null
Future<Map<String, dynamic>?> showLocationPicker(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const LocationPickerPage()),
  );
}

class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({super.key});
  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final MapController _mc = MapController();
  LatLng _center = const LatLng(31.2990, 120.5853); // 默认苏州
  String _name = '获取位置信息…';
  String _address = '';
  bool _resolving = false;
  bool _failed = false;

  /// 逆地理：bigdatacloud 免费接口（中文行政区）
  Future<void> _reverse(double lat, double lng) async {
    setState(() {
      _resolving = true;
      _failed = false;
      _name = '获取位置信息…';
      _address = '';
    });
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=$lat&longitude=$lng&localityLanguage=zh'))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map<String, dynamic>) {
          final city = (j['city'] ?? '') as String;
          final locality = (j['locality'] ?? '') as String;
          final sub = (j['principalSubdivision'] ?? '') as String;
          final parts = [sub, city, locality].where((x) => x.isNotEmpty).toList();
          final name = parts.isNotEmpty ? parts.join(' · ') : '我的位置';
          final addr =
              parts.join(' ') + '（${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}）';
          if (mounted) {
            setState(() {
              _name = name;
              _address = addr;
              _resolving = false;
            });
          }
          return;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _name = '我的位置';
        _address =
            '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
        _resolving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(AppTheme.textPrimary)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('发送位置',
            style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mc,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: 14,
                    minZoom: 3,
                    maxZoom: 18,
                    // 拖动地图选点：地图移动结束取中心点
                    onMapEvent: (e) {
                      if (e is MapEventMoveEnd && mounted) {
                        final c = _mc.camera.center;
                        setState(() => _center = c);
                        _reverse(c.latitude, c.longitude);
                      }
                    },
                  ),
                  children: [
                    // 高德瓦片（免 key，国内可达）
                    TileLayer(
                      urlTemplate:
                          'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                      subdomains: const ['1', '2', '3', '4'],
                      userAgentPackageName: 'com.liuying.community',
                    ),
                    // 中心图钉（选点标记）
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _center,
                          width: 44,
                          height: 44,
                          child: const Icon(Icons.location_pin,
                              color: Color(0xFFFF5A5F), size: 44),
                        ),
                      ],
                    ),
                  ],
                ),
                // 顶栏提示
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text('拖动地图，选择中心位置',
                          style: TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 底部：位置信息 + 确认发送
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: const BoxDecoration(
                color: Color(AppTheme.card),
                border: Border(top: BorderSide(color: Color(AppTheme.border))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.location_on_rounded,
                          color: Color(AppTheme.accent), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _resolving
                            ? const Text('正在获取位置…',
                                style: TextStyle(
                                    color: Color(AppTheme.textTertiary),
                                    fontSize: 14))
                            : Text(_name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(AppTheme.textPrimary),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                      ),
                      if (_failed)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('未解析到地点名',
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary),
                                  fontSize: 10)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text(_address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 12)),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => Navigator.pop(context, {
                      'lat': _center.latitude,
                      'lng': _center.longitude,
                      'name': _name,
                      'address': _address,
                    }),
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [
                          Color(AppTheme.gradStart),
                          Color(AppTheme.gradEnd),
                        ]),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Text('发送该位置',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
