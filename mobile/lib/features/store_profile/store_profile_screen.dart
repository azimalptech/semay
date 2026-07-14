import 'package:flutter/material.dart';

// Placeholder — Store Detail (grid/reels tabs, bio, message/call) wired up in Phase 2.
class StoreProfileScreen extends StatelessWidget {
  const StoreProfileScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Store profile ($storeId) — Phase 2')),
    );
  }
}
