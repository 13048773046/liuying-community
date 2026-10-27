/// 版块内容流页（独立入口兜底）：复用 BoardFeedGrid
library;

import 'package:flutter/material.dart';

import '../../config.dart';
import '../../widgets/board_feed_grid.dart';

class BoardFeedPage extends StatefulWidget {
  final String boardId;
  final String title;
  const BoardFeedPage({super.key, required this.boardId, required this.title});

  @override
  State<BoardFeedPage> createState() => _BoardFeedPageState();
}

class _BoardFeedPageState extends State<BoardFeedPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: Text(widget.title,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: BoardFeedGrid(boardId: widget.boardId),
    );
  }
}
