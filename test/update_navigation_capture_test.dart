import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_space_app/core/app_update_controller.dart';
import 'package:tsukuyomi_space_app/core/app_update_release.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_chrome.dart';
import 'package:tsukuyomi_space_app/features/site/site_widgets.dart';
import 'package:tsukuyomi_space_app/features/updates/app_update_page.dart';

import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

final _release = AppUpdateRelease(
  tag: 'v9.0.0',
  version: AppVersion.parse('v9.0.0')!,
  notes: 'Navigation and rendering improvements',
  installer: UpdateAsset(
    'fixture.apk',
    Uri.parse('$appRepository/fixture.apk'),
    1234,
    null,
  ),
  checksums: UpdateAsset(
    'SHA256SUMS.txt',
    Uri.parse('$appRepository/SHA256SUMS.txt'),
    100,
    null,
  ),
  publishedAt: DateTime(2026, 10, 12),
);

void main() {
  for (final language in ['zh', 'ja', 'en']) {
    for (final dark in [false, true]) {
      for (final editing in [false, true]) {
        testWidgets(
          'update popup fits 360px $language dark=$dark editing=$editing',
          (tester) async {
            tester.view.physicalSize = const Size(360, 640);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final locale = LocaleController(MemoryStorage());
            await locale.setLanguage(language);
            addTearDown(locale.dispose);
            await tester.pumpWidget(
              SiteLocaleScope(
                controller: locale,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: siteTheme(dark),
                  locale: Locale(language),
                  supportedLocales: const [
                    Locale('zh'),
                    Locale('ja'),
                    Locale('en'),
                  ],
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: const TextScaler.linear(1.5)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: AppUpdatePrompt(
                      release: _release,
                      currentVersion: 'v0.6.14-beta.1',
                      editing: editing,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              find.byType(FilledButton),
              editing ? findsNothing : findsOneWidget,
            );
            await tester.ensureVisible(find.byType(TextButton));
            expect(
              tester.getRect(find.byType(TextButton)).bottom,
              lessThanOrEqualTo(640),
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets('real font navigation and update popup captures', (tester) async {
    await tester.runAsync(loadSiteCaptureFonts);
    SharedPreferences.setMockInitialValues({'app-update.automatic': false});
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    await room.login('alice', 'test');
    final chrome = SiteChromeController(room);
    final updates = AppUpdateController(
      preferences: await SharedPreferences.getInstance(),
    )..release = _release;
    addTearDown(room.dispose);
    addTearDown(chrome.dispose);
    addTearDown(updates.dispose);
    final capture = GlobalKey();
    for (final width in [320, 390, 1280]) {
      tester.view.physicalSize = Size(width.toDouble(), 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: AppUpdateScope(
            controller: updates,
            child: SiteChromeScope(
              controller: chrome,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: siteTheme(false),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: SiteHeader(
                      title: '私人居所',
                      username: 'alice',
                      onGo: (_) {},
                      onLogin: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/images/sakura/sakura-moon-logo.webp'),
          capture.currentContext!,
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('artifacts/update2048/navigation-$width.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      final dialog = showDialog<void>(
        context: tester.element(find.byType(SiteHeader)),
        builder: (_) => AppUpdatePrompt(
          release: _release,
          currentVersion: 'v0.6.14-beta.1',
          editing: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('artifacts/update2048/popup-$width.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      Navigator.of(tester.element(find.byType(AppUpdatePrompt))).pop();
      await dialog;
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.reset();
  }, skip: !const bool.fromEnvironment('RUN_UI_CAPTURE'));
}
