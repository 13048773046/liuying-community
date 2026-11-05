/// 个性装扮 · 头像框选择页（从设置页/我的页进入）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';

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
      showAppToast(context, id.isEmpty ? '已取消头像框' : '已更换头像框');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(
            title: '个性装扮',
            subtitle: '选择你喜欢的头像框',
            solid: true,
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : GridView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      AppSpace.gutter,
                      AppSpace.x2,
                      AppSpace.gutter,
                      AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: AppSpace.x3,
                      crossAxisSpacing: AppSpace.x3,
                      childAspectRatio: 0.82,
                    ),
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
          ),
        ],
      ),
    );
  }

  Widget _cell(
      {required String id, required String name, required bool isDefault}) {
    final sel = _myFrame == id;
    return PressableScale(
      onTap: () => _equip(id),
      scale: 0.94,
      child: AnimatedContainer(
        duration: AppMotion.base,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.x2),
        decoration: BoxDecoration(
          color: sel ? const Color(AppColors.accentSoft) : const Color(AppColors.card),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: sel
                ? const Color(AppColors.accent)
                : const Color(AppColors.border),
            width: sel ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppAvatar(
              size: 46,
              name: isDefault ? '无' : name,
              ring: sel,
            ),
            const SizedBox(height: AppSpace.x2),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(
                color: sel
                    ? const Color(AppColors.accent)
                    : const Color(AppColors.textSecondary),
                fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            if (sel)
              Text(
                '使用中',
                style: AppType.micro
                    .copyWith(color: const Color(AppColors.accent)),
              )
            else
              const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}
