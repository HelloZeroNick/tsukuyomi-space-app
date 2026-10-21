import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/payments.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/payments_page.dart';

import 'support/fakes.dart';
import 'support/payment_site.dart';

class FixtureLauncher extends AlipayCheckoutLauncher {
  int calls = 0;
  @override
  Future<void> payApp(
    Map<String, dynamic> checkout,
    Map<String, dynamic> order,
  ) async {
    calls++;
  }
}

Future<RoomController> mount(
  WidgetTester tester,
  PaymentFixtureSite site, {
  double width = 390,
  AlipayCheckoutLauncher? launcher,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final room = RoomController(
    storage: MemoryStorage()..value = const RoomSettings(demo: false),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  addTearDown(room.dispose);
  await room.initialize();
  await room.login('alice', 'fixture');
  room.pause();
  await tester.pumpWidget(
    MaterialApp(
      home: PaymentsPage(controller: room, onGo: (_) {}, launcher: launcher),
    ),
  );
  if (site.aliceDashboard == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return room;
}

void main() {
  testWidgets(
    'operator settings use current account, precise rates, and never echo or overwrite a saved key',
    (tester) async {
      final site = PaymentFixtureSite()..operator = true;
      await mount(tester, site);
      final settings = find.text('供应商、售价与待核对请求');
      await tester.ensureVisible(settings);
      await tester.tap(settings);
      await tester.pumpAndSettle();
      final save = find.text('保存服务配置');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(site.adminWrites.length, 1);
      expect(site.adminWrites.single['rates'], {
        'input_uncached': '2000000000',
        'input_cached': '200000000',
        'output': '3000000000',
      });
      expect(site.adminWrites.single['paymentsEnabled'], false);
      expect(site.adminWrites.single.containsKey('apiKey'), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'native payment centre renders at $width without plugin coupling or layout errors',
      (tester) async {
        final site = PaymentFixtureSite();
        await mount(tester, site, width: width);
        expect(find.text('网站统一余额'), findsOneWidget);
        expect(find.text('deepseek-chat'), findsOneWidget);
        expect(find.text('我的订单'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(site.calls, contains('GET official/api/dashboard'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('plugin failure leaves the main wallet and orders available', (
    tester,
  ) async {
    final site = PaymentFixtureSite()..pluginOffline = true;
    await mount(tester, site);
    expect(find.text('¥1.00'), findsWidgets);
    expect(find.text('我的订单'), findsOneWidget);
    expect(find.text('直供服务离线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'SDK callback cannot mark paid; a resumed app queries server proof and refreshes wallet',
    (tester) async {
      final site = PaymentFixtureSite(), launcher = FixtureLauncher();
      await mount(tester, site, launcher: launcher);
      final buy = find.text('使用支付宝支付');
      await tester.ensureVisible(buy);
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(launcher.calls, 1);
      expect(site.keys.length, 1);
      expect(site.order!['status'], 'pending');
      expect(site.walletCredited, false);
      expect(
        site.calls,
        contains('POST /api/payments/orders/${site.order!['id']}/refresh'),
      );
      site.paidProof = true;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(site.order!['status'], 'paid');
      expect(site.walletCredited, true);
      expect(find.text('¥2.00'), findsOneWidget);
      expect(site.keys.length, 1); // Resume and polling never create an order.
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late Alice responses are hidden after switching to Bob', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final site = PaymentFixtureSite()..aliceDashboard = pending;
    final room = await mount(tester, site);
    final alice =
        jsonDecode(jsonEncode(site.dashboard)) as Map<String, dynamic>;
    await room.logout();
    await room.login('bob', 'fixture');
    room.pause();
    await tester.pumpAndSettle();
    pending.complete(alice);
    await tester.pumpAndSettle();
    expect(find.text('¥2.00'), findsOneWidget);
    expect(find.text('¥1.00'), findsOneWidget); // Public product price only.
    expect(find.text('登录账号已变化，请刷新支付中心后重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
