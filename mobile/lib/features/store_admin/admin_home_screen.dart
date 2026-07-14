import 'package:flutter/material.dart';

import '../feed/feed_view.dart';

// docs/04_SCREENS_AND_NAVIGATION.md: "Admin can browse like a normal user too."
class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeedView(storyRoutePrefix: '/admin/home/story');
  }
}
