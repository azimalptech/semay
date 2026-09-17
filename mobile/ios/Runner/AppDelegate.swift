import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Mirror of notification_service.dart's _activeChatId, kept over the
  // "com.semay.semay/notifications" channel: on iOS the OS asks THIS delegate
  // what to present for a foreground push, so the "silent only for the thread
  // on screen" rule has to be answered here — Dart is never consulted.
  private var activeChatId: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before super, which registers the plugins: firebase_messaging makes
    // itself the notification-center delegate unless one that forwards to the
    // plugins (a FlutterAppDelegate) is already installed. With this line every
    // willPresent reaches the override below first and super forwards it on to
    // the plugins; without it the FCM plugin answers every foreground push
    // itself with the global options from main.dart, and this class is never
    // asked.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.semay.semay/notifications",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setActiveChat":
        // nil (NSNull from Dart) when the thread is left or the app pauses.
        self?.activeChatId = call.arguments as? String
        result(nil)
      case "dismissChat":
        // The Android half of this is flutter_local_notifications' cancel(id:
        // 0, tag: chatId); iOS has no such plugin here (the OS presents
        // foreground pushes itself), so the thread's delivered notifications
        // are removed straight from the notification centre. Without it a
        // banner for a chat the user has already read stayed in Notification
        // Center until they swiped it away — which neither WhatsApp nor
        // Instagram does. The launcher NUMBER is corrected separately, by the
        // server's badge-only push (chats/service.ts syncLauncherBadges).
        guard let chatId = call.arguments as? String else {
          result(nil)
          return
        }
        Self.removeDelivered(chatId: chatId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Every delivered notification for one chat. `chatId` comes from the FCM
  /// data payload (notifications/push.ts sends it on every chat push; it is
  /// the same key `willPresent` below matches on) — `threadIdentifier` would
  /// only work for pushes whose `aps.thread-id` the OS actually applied.
  private static func removeDelivered(chatId: String) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
      let ids = delivered
        .filter { $0.request.content.userInfo["chatId"] as? String == chatId }
        .map { $0.request.identifier }
      guard !ids.isEmpty else { return }
      center.removeDeliveredNotifications(withIdentifiers: ids)
    }
  }

  // willPresent is called ONLY while the app is in the foreground, so every
  // chat push reaching it is one Flutter is about to announce itself with the
  // in-app banner (features/chat/in_app_banner.dart). iOS therefore draws no
  // banner of its own for a chat message — two banners for one message was
  // the alternative — and answers with badge + the phone's default sound
  // instead. The one exception is the rule from notification_service.dart's
  // shouldPresentPush, unchanged: a message for the thread ALREADY ON SCREEN
  // is silent, badge only, because the user is looking straight at it.
  //
  // Broadcasts and order notices — no chatId — are untouched: the OS presents
  // them in full, exactly as before.
  //
  // Every case still goes through super so the FCM plugin fires
  // Messaging#onMessage (the delivered receipt, and the banner itself); only
  // the presentation options are replaced.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // UNUserNotificationCenter's completion handler must be called exactly
    // once: super fans the callback out to every registered plugin (FCM's and
    // flutter_local_notifications' both implement it), so more than one of
    // them answering would otherwise call it twice. Called on the main
    // thread, like the delegate callback itself, so the flag needs no lock.
    var answered = false
    let answer: (UNNotificationPresentationOptions) -> Void = { options in
      guard !answered else { return }
      answered = true
      completionHandler(options)
    }
    let chatId = notification.request.content.userInfo["chatId"] as? String
    if let chatId = chatId {
      let options: UNNotificationPresentationOptions =
        chatId == activeChatId ? [.badge] : [.badge, .sound]
      super.userNotificationCenter(center, willPresent: notification) { _ in
        answer(options)
      }
      return
    }
    super.userNotificationCenter(
      center, willPresent: notification, withCompletionHandler: answer)
  }
}
