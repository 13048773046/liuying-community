/// 版块内容流页（独立入口兜底）：复用 BoardFeedGrid
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';
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
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(title: widget.title, solid: true),
          Expanded(child: BoardFeedGrid(boardId: widget.boardId)),
        ],
      ),
    );
  }
}
