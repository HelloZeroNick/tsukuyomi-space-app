import 'package:html/parser.dart' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/site_localization.dart';
import 'package:tsukuyomi_space_app/core/site_theme.dart';
import 'package:tsukuyomi_space_app/features/room/room_chat_view.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_message_cache.dart';
import 'package:tsukuyomi_space_app/features/site/native_article_document.dart';
import 'package:tsukuyomi_space_app/features/site/native_rich_text.dart';

import 'support/fakes.dart';

ChatTurn turn(int i, {String? reply}) => ChatTurn(
  id: 'turn-$i',
  user: '问题 $i',
  assistant: reply ?? '第 $i 句回复。第二句。',
  createdAt: DateTime(2020),
);

class PlaybackVoice extends SilentVoice {
  bool active = false;
  @override
  bool get playing => active;
  void setActive(bool value) {
    active = value;
    notifyListeners();
  }
}

void main() {
  test('large Markdown resolves references and keeps atomic rich blocks', () {
    final before = List.generate(
      130,
      (i) => '第 $i 段 **格式化文字**，访问 [原站][site]。',
    ).join('\n\n');
    final source =
        '$before\n\n```dart\nfinal x = "<tag>";\n```\n\n'
        '| 标题 | 数值 |\n| --- | --- |\n| a | 42 |\n\n'
        '- 列表第一项\n- 列表第二项\n\n![图片][image]\n\n$before\n\n'
        '[site]: https://tsukuyomi-space.com/stage\n[image]: https://tsukuyomi-space.com/image.png';
    final presentation = RoomReplyPresentation(source);
    expect(presentation.markdown, true);
    expect(presentation.format, 'html');
    expect(presentation.parts.length, greaterThan(10));
    final original = html.parseFragment(
      parseNativeArticle(source, 'markdown').html,
    );
    final reassembled = html.parseFragment(
      presentation.parts
          .map((part) => parseNativeArticle(part, presentation.format).html)
          .join(),
    );
    for (final selector in ['pre', 'table', 'ul', 'img', 'a']) {
      final old = original.querySelectorAll(selector),
          next = reassembled.querySelectorAll(selector);
      expect(
        next.map((element) => element.outerHtml).toList(),
        old.map((element) => element.outerHtml).toList(),
        reason: selector,
      );
    }
    expect(reassembled.text, original.text);
    expect(
      presentation.parts.where((part) => part.contains('<pre>')).length,
      1,
    );
    expect(
      presentation.parts.where((part) => part.contains('<table>')).length,
      1,
    );
  });

  test('local Markdown anchors and single huge code block remain coherent', () {
    final source = List.filled(700, '**文字**。').join('\n\n');
    final anchors = RoomReplyPresentation(
      '$source\n\n[跳转](#article-section-2)',
    );
    expect(anchors.format, 'markdown');
    expect(anchors.parts.length, 1);
    final code =
        '```dart\n${List.filled(900, 'print("一行代码");').join('\n')}\n```';
    expect(RoomReplyPresentation(code).parts, [code]);
  });

  test('flat transcript reuses unchanged turn rows and presentation', () {
    final cache = RoomMessageCache(maxReplies: 4);
    final index = RoomTranscriptIndex(cache);
    final turns = List.generate(2000, turn);
    index.update(turns, (_) => true);
    expect(index.history.knownRowCount, 0);
    expect(index.preparedTurns, 0);
    final first = index.history.rowAt(0)!;
    expect(index.preparedTurns, 1);
    index.update([
      ...turns,
      turn(2000),
    ], (t) => t.createdAt.year == 2020 && t.id != 'turn-2000');
    expect(index.preparedTurns, 1);
    expect(identical(index.history.rowAt(0), first), true);
    expect(index.recent.turnCount, 1);
    expect(index.history.indices[first.id], 0);
    index.history.complete();
    expect(index.history.completeRowCount, 8000);
    expect(cache.replyCount, lessThanOrEqualTo(4));
    expect(
      cache.cachedReplyCharacters,
      lessThanOrEqualTo(cache.maxReplyCharacters),
    );
    expect(index.presentation(turns.first).parts, ['第 0 句回复。', '第二句。']);
  });

  testWidgets('history dialog is lazy and retains formatted replies', (
    tester,
  ) async {
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    c.turns = [
      turn(0, reply: '## 标题\n\n**正文**'),
      ...List.generate(1999, (i) => turn(i + 1)),
    ];
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomChatHistoryView(
            controller: c,
            onNavigate: (_) {},
            onNotice: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomChatBubble).evaluate().length, lessThan(20));
    expect(find.textContaining('标题', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('jump to first turn resolves lazy history extent', (
    tester,
  ) async {
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    c.turns = List.generate(40, turn);
    addTearDown(c.dispose);
    final key = GlobalKey<RoomChatViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomChatView(
            key: key,
            controller: c,
            mobile: false,
            onNavigate: (_) {},
            onNotice: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('问题 39'), findsOneWidget);
    key.currentState!.jumpToStart();
    await tester.pumpAndSettle();
    expect(find.text('问题 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cached reply controls observe playback and current send permission',
    (tester) async {
      final voice = PlaybackVoice(), chat = FakeChat()..controlled = true;
      final c = RoomController(
        storage: MemoryStorage(),
        chat: chat,
        site: FakeSite(),
        voice: voice,
      );
      await c.initialize();
      c.turns = [turn(0)];
      addTearDown(c.dispose);
      final key = GlobalKey<RoomChatViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomChatView(
              key: key,
              controller: c,
              mobile: false,
              onNavigate: (_) {},
              onNotice: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rows = key.currentState!.debugBuiltRows;
      expect(find.byTooltip('朗读回复'), findsOneWidget);
      voice.setActive(true);
      await tester.pump();
      expect(find.byTooltip('停止语音'), findsOneWidget);
      expect(key.currentState!.debugBuiltRows, rows);
      final send = c.send('再次提问');
      for (var i = 0; chat.stream == null && i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新生成'))
            .onPressed,
        isNull,
      );
      chat.stream!.add('新的回复。');
      await chat.stream!.close();
      await send;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新生成'))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cached pending rows follow theme language and text scaling', (
    tester,
  ) async {
    final store = MemoryStorage();
    final c = RoomController(
      storage: store,
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    c.turns = [
      ChatTurn(
        id: 'pending-theme',
        user: '问题',
        assistant: '回复。',
        pending: true,
        createdAt: DateTime(2020),
      ),
    ];
    addTearDown(c.dispose);
    final locale = LocaleController(store);
    addTearDown(locale.dispose);
    final key = GlobalKey<RoomChatViewState>();
    final chat = RoomChatView(
      key: key,
      controller: c,
      mobile: false,
      onNavigate: (_) {},
      onNotice: (_) {},
    );
    Future<void> show(Brightness brightness, double scale) async {
      await tester.pumpWidget(
        SiteLocaleScope(
          controller: locale,
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(body: chat),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    SiteText pending() => tester
        .widgetList<SiteText>(find.byType(SiteText))
        .singleWhere((w) => w.data == '已保存在本机 · 等待同步');
    await show(Brightness.light, 1);
    expect(pending().style!.color, const SitePalette(false).muted);
    final updates = key.currentState!.debugIndexUpdates;
    await show(Brightness.dark, 1);
    expect(pending().style!.color, const SitePalette(true).muted);
    for (final language in ['en', 'ja', 'zh']) {
      await locale.setLanguage(language);
      await tester.pumpAndSettle();
      expect(
        find.text(siteMessage(language, 'nativeUi.30811218c7e7')),
        findsOneWidget,
      );
      expect(
        find.byTooltip(siteMessage(language, 'nativeUi.8559c992d706')),
        findsOneWidget,
      );
    }
    await show(Brightness.dark, 1.7);
    expect(pending().style!.color, const SitePalette(true).muted);
    expect(key.currentState!.debugIndexUpdates, updates);
    expect(
      key.currentState!.debugCachedReplyCharacters,
      lessThanOrEqualTo(262144),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'horizontal nested scroll notifications keep the new reply badge',
    (tester) async {
      final c = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      c.turns = List.generate(40, turn);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomChatView(
              controller: c,
              mobile: false,
              onNavigate: (_) {},
              onNotice: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(-1200);
      await tester.pumpAndSettle();
      c.turns = [
        ...c.turns,
        ChatTurn(
          id: 'new-reply',
          user: '新问题',
          assistant: '新回复。',
          createdAt: DateTime.now(),
        ),
      ];
      c.workspace.changed();
      await tester.pumpAndSettle();
      expect(find.text('查看新消息'), findsOneWidget);
      final context = tester.element(find.byType(CustomScrollView));
      ScrollUpdateNotification(
        context: context,
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 100,
          pixels: 100,
          viewportDimension: 500,
          axisDirection: AxisDirection.right,
          devicePixelRatio: 1,
        ),
      ).dispatch(context);
      await tester.pump();
      expect(find.text('查看新消息'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'long reply and 2000 turns mount only visible bubbles at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = RoomController(
          storage: MemoryStorage(),
          chat: FakeChat(),
          site: FakeSite(),
          voice: SilentVoice(),
        );
        await c.initialize();
        c.turns = [
          ...List.generate(1999, turn),
          turn(1999, reply: List.generate(600, (i) => '第 $i 句是历史聊天内容。').join()),
        ];
        addTearDown(c.dispose);
        final key = GlobalKey<RoomChatViewState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RoomChatView(
                key: key,
                controller: c,
                mobile: width < 860,
                onNavigate: (_) {},
                onNotice: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final mounted = find.byType(SelectableText).evaluate().length;
        debugPrint(
          'ROOM_LONG_REPLY_FLAT width=$width selectableTexts=$mounted sentences=600 turns=2000',
        );
        expect(mounted, lessThan(20));
        expect(key.currentState!.debugPreparedTurns, lessThan(5));
        final updates = key.currentState!.debugIndexUpdates,
            built = key.currentState!.debugBuiltRows;
        for (var i = 0; i < 30; i++) {
          c.workspace.status = 'unrelated update $i';
          c.workspace.changed();
          await tester.pump();
        }
        expect(key.currentState!.debugIndexUpdates, updates);
        expect(key.currentState!.debugBuiltRows, built);
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(-3000);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText).evaluate().length, lessThan(22));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'large formatted reply mounts only visible Markdown chunks at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = RoomController(
          storage: MemoryStorage(),
          chat: FakeChat(),
          site: FakeSite(),
          voice: SilentVoice(),
        );
        await c.initialize();
        c.turns = [
          turn(
            0,
            reply:
                '${List.generate(600, (i) => '第 $i 段 **粗体** 文字，访问 [站点][site]。').join('\n\n')}\n\n[site]: https://tsukuyomi-space.com/stage',
          ),
        ];
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RoomChatView(
                controller: c,
                mobile: width < 860,
                onNavigate: (_) {},
                onNotice: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rich = tester
            .widgetList<NativeRichText>(find.byType(NativeRichText))
            .toList();
        debugPrint(
          'ROOM_MARKDOWN_LAZY width=$width mountedChunks=${rich.length} paragraphs=600',
        );
        expect(rich.length, inInclusiveRange(1, 4));
        expect(
          rich.every(
            (widget) => widget.format == 'html' && !widget.trackReading,
          ),
          true,
        );
        expect(
          find.textContaining('第 599 段', findRichText: true),
          findsWidgets,
        );
        expect(find.textContaining('第 0 段', findRichText: true), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('streaming stays lazy and reports drag activity at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final chat = FakeChat()..controlled = true;
      final c = RoomController(
        storage: MemoryStorage(),
        chat: chat,
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      c.turns = List.generate(20, turn);
      addTearDown(c.dispose);
      final activity = <bool>[];
      final key = GlobalKey<RoomChatViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomChatView(
              key: key,
              controller: c,
              mobile: width < 860,
              onNavigate: (_) {},
              onNotice: (_) {},
              onScrollActivity: activity.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sending = c.send('stream while dragging');
      for (var i = 0; chat.stream == null && i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      final updates = key.currentState!.debugIndexUpdates;
      chat.stream!.add(List.generate(600, (i) => '第 $i 句流式回复。').join());
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();
      expect(find.text('第 599 句流式回复。'), findsOneWidget);
      expect(find.byType(SelectableText).evaluate().length, lessThan(24));
      expect(key.currentState!.debugIndexUpdates, updates);
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final gesture = await tester.startGesture(tester.getCenter(scrollable));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      final before = position.pixels;
      expect(activity.last, true);
      chat.stream!.add('继续增加回复。');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      expect(position.pixels, closeTo(before, .01));
      await gesture.up();
      await chat.stream!.close();
      await sending;
      await tester.pumpAndSettle();
      expect(activity.last, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
