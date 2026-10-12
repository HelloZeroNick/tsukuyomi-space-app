import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_reply.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_message_cache.dart';
import 'package:tsukuyomi_space_app/features/site/native_rich_text.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

void main() {
  test(
    'reply presentation is reused; streaming does not evict completed replies',
    () {
      final cache = RoomMessageCache(maxReplies: 2, maxReplyCharacters: 100);
      final first = cache.reply('First. Next!');
      cache.reply('Other.');
      expect(identical(cache.reply('First. Next!'), first), true);
      for (var i = 0; i < 100; i++) {
        cache.reply('Stream $i', streaming: true);
      }
      expect(cache.replyCount, 2);
      expect(identical(cache.reply('First. Next!'), first), true);
      cache.reply('Third.');
      expect(cache.replyCount, 2);
      expect(identical(cache.reply('First. Next!'), first), true);
      cache.reply(List.filled(100, 'long').join());
      expect(cache.cachedReplyCharacters, lessThanOrEqualTo(100));
      expect(() => first.parts.add('changed'), throwsUnsupportedError);
      expect(cache.reply('## Heading\n\n**Text**').markdown, true);
      expect(cache.reply('## Heading', streaming: true).markdown, false);
    },
  );

  test('image bytes retain identity and stay within count and byte limits', () {
    final cache = RoomMessageCache(maxImages: 2, maxImageBytes: 6);
    String url(List<int> bytes) =>
        'data:image/png;base64,${base64Encode(bytes)}';
    final one = url([1, 2, 3]), two = url([4, 5, 6]);
    final first = cache.image(one);
    cache.image(two);
    expect(identical(cache.image(one), first), true);
    cache.image(url([7, 8, 9]));
    expect(cache.imageCount, 2);
    expect(cache.cachedImageBytes, 6);
    expect(identical(cache.image(one), first), true);
    cache.image(url(List.filled(7, 0)));
    expect(cache.cachedImageBytes, 6);
    expect(
      () => cache.image('data:image/png;base64,???'),
      throwsFormatException,
    );
    cache.clear();
    expect(cache.cachedImageBytes, 0);
    expect(cache.cachedReplyCharacters, 0);
    expect(identical(cache.image(one), first), false);
  });

  test('long replies preserve text, code, URLs and sentence boundaries', () {
    final unbroken = List.filled(12000, '长').join();
    expect(splitRoomReply(unbroken), [unbroken]);
    expect(
      splitRoomReply(
        'Dr. Li uses 3.14. Read https://example.com/a?b=1! Then continue.',
      ),
      ['Dr. Li uses 3.14.', 'Read https://example.com/a?b=1! Then continue.'],
    );
    expect(splitRoomReply('“真的！？可以。”下一句。\n\n```\na.b?\n\n```结尾！'), [
      '“真的！？可以。”',
      '下一句。',
      '```\na.b?\n\n```结尾！',
    ]);
    final longUrl = 'https://example.com/${List.filled(300, 'x').join()},';
    expect(splitRoomReply(longUrl), [longUrl]);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('chat Markdown has no article measurements at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      room.turns = [
        ChatTurn(
          id: 'markdown',
          user: '问题',
          assistant: '## 第一节\n\n**格式**\n\n## 第二节\n\n[原站](https://yachiyo.hk)',
          createdAt: DateTime(2020),
        ),
      ];
      addTearDown(room.dispose);
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, loadNative: false),
      );
      await tester.pumpAndSettle();
      final rich = tester.widget<NativeRichText>(find.byType(NativeRichText));
      expect(rich.trackReading, false);
      expect(find.text('文章目录'), findsNothing);
      final state = tester.state(find.byType(NativeRichText)) as dynamic;
      expect(state.position, isNull);
      expect(find.textContaining('第二节', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'revisiting an image reuses its provider at $width and clears it on scope change',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final data = await rootBundle.load(
          'assets/images/yachiyo-portrait.webp',
        );
        final url =
            'data:image/webp;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
        final turns = List.generate(
          30,
          (i) => ChatTurn(
            id: 'image-$i',
            user: 'question $i',
            assistant: 'answer $i',
            createdAt: DateTime(2020),
            image: i == 29 ? {'dataUrl': url} : null,
          ),
        );
        final storage = MemoryStorage()..histories['demo'] = turns;
        final room = RoomController(
          storage: storage,
          chat: FakeChat(),
          site: FakeSite(),
          voice: SilentVoice(),
        );
        await room.initialize();
        addTearDown(room.dispose);
        await tester.pumpWidget(
          TsukuyomiApp(controller: room, loadNative: false),
        );
        await tester.pumpAndSettle();
        MemoryImage image() => tester
            .widgetList<Image>(find.byType(Image))
            .map((w) => w.image)
            .whereType<ResizeImage>()
            .map((p) => p.imageProvider)
            .whereType<MemoryImage>()
            .single;
        final first = image();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(-3000);
        await tester.pumpAndSettle();
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        expect(image(), first);
        expect(identical(image().bytes, first.bytes), true);
        final other = const RoomSettings(model: 'configured');
        storage.histories['${endpointUri(other.siteUrl).origin}:guest'] = turns;
        await room.configure(other);
        await tester.pumpAndSettle();
        expect(identical(image().bytes, first.bytes), false);
        expect(find.text('图片暂不可用'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('streaming respects an active chat drag at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final chat = FakeChat()..controlled = true;
      final room = RoomController(
        storage: MemoryStorage(),
        chat: chat,
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      room.turns = List.generate(
        15,
        (i) => ChatTurn(
          id: 'drag-$i',
          user: 'question $i',
          assistant: 'answer $i',
          createdAt: DateTime(2020),
        ),
      );
      addTearDown(room.dispose);
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, loadNative: false),
      );
      await tester.pumpAndSettle();
      final sending = room.send('stream while dragging');
      for (var i = 0; chat.stream == null && i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final gesture = await tester.startGesture(tester.getCenter(scrollable));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      final before = position.pixels;
      expect(position.isScrollingNotifier.value, true);
      chat.stream!.add('流式内容继续增加，保持用户手势位置。');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      expect(position.pixels, closeTo(before, .01));
      await gesture.up();
      await chat.stream!.close();
      await sending;
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
