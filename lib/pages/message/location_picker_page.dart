/// 发送位置 · 地图选点页（沉浸黑：拖动地图，中心图钉选点）
/// 地图：flutter_map + 高德瓦片（免 key）；逆地理：bigdatacloud 免费接口（中文）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../design/components.dart';

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
              '${parts.join(' ')}（${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}）';
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
    return ImmersivePage(
      child: Stack(
        children: [
          // 黑底地图容器（保留 flutter_map 用法）
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: FlutterMap(
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
                            color: Color(AppColors.heart), size: 44),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 顶部悬浮：玻璃顶栏 + 搜索胶囊
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassTopBar(title: '发送位置', floating: true),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
                  child: SearchPill(
                    hint: _resolving ? '正在获取位置…' : _name,
                  ),
                ),
              ],
            ),
          ),
          // 底部确认区
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _confirmBar(),
          ),
        ],
      ),
    );
  }

  Widget _confirmBar() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.x3,
          AppSpace.gutter, AppSpace.x3 + bottom),
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        border: Border(top: BorderSide(color: Color(AppColors.border))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location_rounded,
                  size: 14, color: Color(AppColors.textTertiary)),
              const SizedBox(width: AppSpace.x1 + 2),
              Text('拖动地图，选择中心位置', style: AppType.micro),
            ],
          ),
          const SizedBox(height: AppSpace.x3),
          Row(
            children: [
              const Icon(Icons.location_on_rounded,
                  size: 18, color: Color(AppColors.accent)),
              const SizedBox(width: AppSpace.x2),
              Expanded(
                child: _resolving
                    ? Text('正在获取位置…', style: AppType.bodySm)
                    : Text(
                        _name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.title,
                      ),
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.x2),
                  child: Text('未解析到地点名', style: AppType.micro),
                ),
            ],
          ),
          if (_address.isNotEmpty) ...[
            const SizedBox(height: AppSpace.x1),
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.x6 + 2),
              child: Text(
                _address,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.caption,
              ),
            ),
          ],
          const SizedBox(height: AppSpace.x4),
          PillButton(
            label: '发送该位置',
            icon: Icons.send_rounded,
            expand: true,
            size: PillSize.lg,
            glow: true,
            onTap: () => Navigator.pop(context, {
              'lat': _center.latitude,
              'lng': _center.longitude,
              'name': _name,
              'address': _address,
            }),
          ),
        ],
      ),
    );
  }
}
