import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';

/// 个性装扮 · 头像框选择页（从设置页/我的页进入）
class FramesPage extends StatefulWidget {
  const FramesPage({super.key});

  @override
  State<FramesPage> createState() => _FramesPageState();
}

class _FramesPageState extends State<FramesPage> {
  List<Map<String, dynamic>> _frames = [];
  String _myFrame = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final fr = await ApiClient.frames();
      final mf = await ApiClient.myFrame();
      if (!mounted) return;
      setState(() {
        _frames = ((fr['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _myFrame = (mf['frameId'] ?? '') as String;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _equip(String id) async {
    try {
      await ApiClient.equipFrame(id);
      if (!mounted) return;
      setState(() => _myFrame = id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(id.isEmpty ? '已取消头像框' : '已更换头像框'),
          backgroundColor: const Color(AppTheme.card)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: const Color(AppTheme.card)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        title: const Text('个性装扮 · 头像框',
            style: TextStyle(color: Color(AppTheme.textPrimary), fontSize: 16)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(AppTheme.accent)))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.95),
              itemCount: _frames.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return _cell(id: '', name: '无头像框', isDefault: true);
                }
                final f = _frames[i - 1];
                return _cell(
                    id: (f['id'] ?? '') as String,
                    name: (f['name'] ?? '') as String,
                    isDefault: false);
              },
            ),
    );
  }

  Widget _cell(
      {required String id, required String name, required bool isDefault}) {
    final sel = _myFrame == id;
    return GestureDetector(
      onTap: () => _equip(id),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: sel
                ? const Color(AppTheme.accent)
                : const Color(AppTheme.border),
            width: sel ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: sel
                    ? Border.all(color: const Color(AppTheme.accent), width: 2)
                    : null,
              ),
              child: CircleAvatar(
                radius: 22,
                backgroundColor: const Color(AppTheme.card),
                child: const Icon(Icons.person,
                    color: Color(AppTheme.textSecondary)),
              ),
            ),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
