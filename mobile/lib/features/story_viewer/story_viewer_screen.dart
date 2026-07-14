import 'package:flutter/material.dart';

// Placeholder — full-screen story viewer wired up in Phase 2.
class StoryViewerScreen extends StatelessWidget {
  const StoryViewerScreen({super.key, required this.storyId});

  final String storyId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Story viewer ($storyId) — Phase 2')),
    );
  }
}
