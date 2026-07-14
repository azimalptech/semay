import 'package:flutter/material.dart';

import 'feed_view.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeedView(storyRoutePrefix: '/home/story');
  }
}
