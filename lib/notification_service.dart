import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

/// Arka planda (Background) gelen mesajları işleyen TOP-LEVEL fonksiyon.
/// Bu fonksiyon sınıfın dışında olmalıdır.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Arka planda bildirim geldiğinde yapılacak işlemler (gerekirse)
  print("Arka plan bildirimi alındı: ${message.messageId}");
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  // --- EKLEMEN GEREKEN SATIR BU: ---
  FlutterLocalNotificationsPlugin get flutterLocalNotificationsPlugin =>
      _localNotificationsPlugin;

  // Bildirim Kanalı (Android 8+ için gerekli)
  final AndroidNotificationChannel _channel = const AndroidNotificationChannel(
    'high_importance_channel', // AndroidManifest.xml'deki id ile aynı olmalı
    'Yüksek Önemli Bildirimler',
    description: 'Uygulama bildirimleri bu kanaldan gelir.',
    importance: Importance.max,
    playSound: true,
  );

  /// Başlatma Fonksiyonu
  Future<void> init() async {
    // 1. İzin İste (iOS ve Android 13+ için)
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      print('Kullanıcı bildirim izni verdi.');
    } else {
      print('Kullanıcı bildirim izni vermedi.');
      return;
    }

    // 2. Token Al (Firebase Console'dan test gönderimi için bu token'a ihtiyacın olabilir)
    String? token = await _firebaseMessaging.getToken();
    print("🔥 FIREBASE TOKEN (Bunu konsolda test için kullan): $token");

    // 3. Arka Plan İşleyicisini Kaydet
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // 4. Local Notification Kurulumu (Foreground'da göstermek için)
    await _setupLocalNotifications();

    // 5. Ön Plan (Foreground) Dinleyicisi
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Ön planda bildirim geldi: ${message.notification?.title}');

      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;

      // Uygulama açıkken bildirimi Local Notification olarak göster
      if (notification != null && android != null) {
        _localNotificationsPlugin.show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _channel.id,
              _channel.name,
              channelDescription: _channel.description,
              icon: '@mipmap/ic_launcher', // Manifest'teki ikon
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
        );
      }
    });
  }

  Future<void> _setupLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS ayarları
    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings();

    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsDarwin,
        );

    // Kanalı Android sistemine oluştur
    await _localNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_channel);

    await _localNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        // Bildirime tıklanınca yapılacak işlemler buraya
      },
    );
  }
}
