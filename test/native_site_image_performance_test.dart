import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/site/native_site_shell.dart';

void main() {
  testWidgets('stretch dimensions use finite decoding targets', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: nativeSiteImage(
            'https://example.com',
            '/image.png',
            width: double.infinity,
            height: double.infinity,
          ),
        ),
      ),
    );
    final provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, inInclusiveRange(1, 2048));
    expect(provider.height, inInclusiveRange(1, 2048));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('content images bound decoding to displayed size and density', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 800), devicePixelRatio: 3),
          child: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: nativeSiteImage(
                'https://example.com',
                '/image.png',
                height: 200,
                width: 300,
              ),
            ),
          ),
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 900);
    expect(provider.height, 600);
    expect(provider.policy, ResizeImagePolicy.fit);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large viewport bounds decoding and unsafe URLs still fail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1920, 1080),
            devicePixelRatio: 2,
          ),
          child: nativeSiteImage('https://example.com', '/image.png'),
        ),
      ),
    );
    expect(
      (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width,
      2048,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: nativeSiteImage(
          'https://example.com',
          'https://name:password@example.com/image.png',
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });
}
