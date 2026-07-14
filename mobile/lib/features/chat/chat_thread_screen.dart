import 'package:flutter/material.dart';

// Placeholder — chat thread content wired up in Phase 2.
class ChatThreadScreen extends StatelessWidget {
  const ChatThreadScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Chat $chatId — Phase 2')),
    );
  }
}
