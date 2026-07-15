// Background FCM handler for web. Non-functional until a real Firebase
// project/VAPID key exists (see firebase_options.dart's demo web config and
// services/notification_service.dart's REPLACE_ME_VAPID_KEY) — this file
// only exists so the browser doesn't error registering a missing service
// worker.
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'demo-api-key',
  appId: 'demo-app-id',
  messagingSenderId: 'demo-sender-id',
  projectId: 'demo-semay',
  authDomain: 'demo-semay.firebaseapp.com',
  storageBucket: 'demo-semay.appspot.com',
});

firebase.messaging();
