import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../store_profile/store_profile_providers.dart';
import 'chat_providers.dart';

/// How long a banner stays up before sliding away by itself. Long enough to
/// read a preview, short enough that it never sits over what the user is
/// doing — Instagram's is about this.
const chatBannerDuration = Duration(seconds: 4);

/// One chat message, as an in-app banner: what the push carried
/// (notification_service.dart reads `title`/`body` off the FCM notification
/// payload and `chatId` off its data).
@immutable
class ChatBanner {
  const ChatBanner({
    required this.chatId,
    required this.title,
    required this.body,
    required this.id,
  });

  final String chatId;

  /// The sender's name and the message preview, straight from the push — the
  /// server already composes both, so the banner needs no extra fetch to say
  /// something useful.
  final String title;
  final String body;

  /// Distinguishes two banners with identical text (the same person sending
  /// "?" twice), so the second one restarts the animation and the timer
  /// instead of being treated as the one already on screen.
  final int id;
}

/// The banner currently showing, or null. Written only by
/// notification_service.dart's foreground-push handler, which applies
/// [shouldPresentPush] first — the SAME rule that decides whether an OS
/// notification is shown, so a message for the thread already on screen is
/// silent here too, and that rule is not restated anywhere.
class ChatBannerController extends Notifier<ChatBanner?> {
  var _seq = 0;

  @override
  ChatBanner? build() => null;

  void show({required String chatId, required String title, required String body}) {
    state = ChatBanner(chatId: chatId, title: title, body: body, id: ++_seq);
  }

  /// Takes the banner down. [onlyIfId] makes an auto-dismiss timer harmless
  /// when a NEWER banner has since replaced the one it was started for.
  void dismiss({int? onlyIfId}) {
    final current = state;
    if (current == null) return;
    if (onlyIfId != null && current.id != onlyIfId) return;
    state = null;
  }
}

final chatBannerProvider = NotifierProvider<ChatBannerController, ChatBanner?>(
  ChatBannerController.new,
);

/// Mounts the banner ABOVE the navigator — wrapped around MaterialApp.router's
/// child in main.dart — so a message that arrives while the app is open is
/// announced on whatever screen the user is on (feed, reels, settings, another
/// chat), not only inside the Chat tab. Tapping it opens that conversation.
///
/// This replaces the OS notification for a chat push while the app is in the
/// foreground; see notification_service.dart, which stops posting one, and
/// AppDelegate.swift, which stops letting iOS present one. Backgrounded and
/// killed apps are unchanged: the OS push handles those, as before.
class ChatBannerHost extends ConsumerStatefulWidget {
  const ChatBannerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ChatBannerHost> createState() => _ChatBannerHostState();
}

class _ChatBannerHostState extends ConsumerState<ChatBannerHost> {
  Timer? _autoDismiss;

  @override
  void dispose() {
    _autoDismiss?.cancel();
    super.dispose();
  }

  void _armAutoDismiss(ChatBanner banner) {
    _autoDismiss?.cancel();
    _autoDismiss = Timer(chatBannerDuration, () {
      if (mounted) ref.read(chatBannerProvider.notifier).dismiss(onlyIfId: banner.id);
    });
  }

  void _open(ChatBanner banner) {
    _autoDismiss?.cancel();
    ref.read(chatBannerProvider.notifier).dismiss();
    // Through the router rather than a BuildContext: this widget sits above
    // the Navigator, which is exactly where GoRouter.of(context) has nothing
    // to find. Same route the notification tap uses — '/chat/:id' renders the
    // thread for either role (router.dart).
    ref.read(routerProvider).push('/chat/${banner.chatId}');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ChatBanner?>(chatBannerProvider, (previous, next) {
      if (next != null) _armAutoDismiss(next);
    });
    final banner = ref.watch(chatBannerProvider);

    return Stack(
      children: [
        widget.child,
        // Ignores pointers while nothing is showing, so the (invisible)
        // banner slot never eats a tap meant for the screen underneath.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -1),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: banner == null
                ? const SizedBox.shrink(key: ValueKey('no-banner'))
                : _BannerCard(
                    key: ValueKey(banner.id),
                    banner: banner,
                    onTap: () => _open(banner),
                    onDismiss: () =>
                        ref.read(chatBannerProvider.notifier).dismiss(onlyIfId: banner.id),
                  ),
          ),
        ),
      ],
    );
  }
}

class _BannerCard extends ConsumerWidget {
  const _BannerCard({
    super.key,
    required this.banner,
    required this.onTap,
    required this.onDismiss,
  });

  final ChatBanner banner;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Material(
          color: AppColors.backgroundCard,
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          child: GestureDetector(
            // Flick it up to get rid of it, like a real notification banner.
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < 0) onDismiss();
            },
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    _SenderAvatar(chatId: banner.chatId, name: banner.title),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            banner.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyMediumSemibold,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            banner.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodySmall.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sender's picture. The push carries no avatar URL, so it is resolved
/// from data the app already holds: the chat row on the live list channel
/// gives the store / customer id, and the store and user docs are read-cached.
/// Nothing new is subscribed to — these are the providers the Chat tab and its
/// unread badge already watch — and a miss simply falls back to the initial.
class _SenderAvatar extends ConsumerWidget {
  const _SenderAvatar({required this.chatId, required this.name});

  final String chatId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(appRoleProvider).value;
    final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
    final chats = isAdmin
        ? ref.watch(adminChatsProvider).value
        : ref.watch(userChatsProvider).value;
    Map<String, dynamic>? chat;
    for (final doc in chats ?? const <ChatDoc>[]) {
      if (doc.id == chatId) {
        chat = doc.data();
        break;
      }
    }
    // The sender is whichever side isn't me: the shop for a customer, the
    // customer for a store admin.
    String avatarUrl = '';
    if (chat != null) {
      final sender = isAdmin
          ? ref.watch(userDocProvider(chat['userId'] as String)).value
          : ref.watch(storeDocProvider(chat['storeId'] as String)).value;
      avatarUrl = sender?['avatarUrl'] as String? ?? '';
    }

    final initial = name.trim().isEmpty
        ? ''
        : name.trim().substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppColors.buttonMuted,
      backgroundImage: avatarUrl.isNotEmpty
          ? CachedNetworkImageProvider(avatarUrl)
          : null,
      child: avatarUrl.isNotEmpty
          ? null
          : Text(
              initial,
              style: AppTypography.bodyMediumSemibold.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
    );
  }
}
