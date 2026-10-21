// Offline visual QA: flutter run -d chrome -t tool/preview_payments.dart
import 'package:flutter/material.dart';

import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/payments.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/payments_page.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import '../test/support/fakes.dart';
import '../test/support/payment_site.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = RoomController(
    storage: MemoryStorage()..value = const RoomSettings(demo: false),
    chat: FakeChat(),
    site: PaymentFixtureSite(),
    voice: SilentVoice(),
  );
  await controller.initialize();
  // A fixture identity avoids a real login or any credential in the web preview.
  controller.account = const Account('alice', 'alice');
  controller.sessionVerified = true;
  controller.site.cookie = 'offline-fixture';
  controller.pause();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Banner(
        message: '离线界面验收',
        location: BannerLocation.topEnd,
        child: child!,
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffa6627d)),
        useMaterial3: true,
      ),
      initialRoute: '/payments',
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => settings.name == '/room/settings'
            ? RoomSettingsPage(controller: controller)
            : PaymentsPage(
                controller: controller,
                onGo: (path) =>
                    Navigator.pushNamed(context, Uri.parse(path).path),
                launcher: AlipayCheckoutLauncher(
                  open: (_) async => false,
                  appPay: (_, sandbox) async => {'resultStatus': '6001'},
                ),
              ),
      ),
    ),
  );
}
