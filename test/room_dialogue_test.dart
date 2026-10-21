import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/room_dialogue.dart';

void main() {
  final suite = jsonDecode(
    File('test/fixtures/room_dialogue_web.json').readAsStringSync(),
  ) as Map;
  for (final item in suite['cases'] as List) {
    test('dialogue parity and behaviour: ${item['id']}', () {
      final input = item['input'] as Map;
      final result = RoomDialogue.plan(
        message: input['message'] as String,
        history: (input['history'] as List? ?? [])
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList(),
        now: suite['now'] as int,
        opener: input['opener'] == true,
      );
      expect(result, item['expected']);
      for (final entry in (item['expect'] as Map).entries) {
        expect(result[entry.key], entry.value);
      }
    });
  }
  test(
    'actual replies determine questions, excluding URL and code punctuation',
    () {
      expect(
        RoomDialogue.evaluateReply(
          '看 https://example.test/?q=x 和 `a?b:c`。',
        )['question'],
        false,
      );
      expect(RoomDialogue.evaluateReply('什么？')['question'], true);
    },
  );
  test('technical questions and cloud openers match native replay', () {
    expect(RoomDialogue.plan(message: '为什么这个接口失败了？')['act'], 'answer');
    final rows = <Map<String, dynamic>>[
      {'turnId': 'opener', 'role': 'assistant', 'content': '好，你来啦。'},
      {'turnId': 'one', 'role': 'user', 'content': '嗯'},
      {'turnId': 'one', 'role': 'assistant', 'content': '好，收到。'},
    ];
    expect(RoomDialogue.deriveState(rows)['completedTurns'], 2);
    expect(
      RoomDialogue.deriveState(rows),
      RoomDialogue.deriveState([
        {...rows.first, 'opener': true},
        ...rows.skip(1),
      ]),
    );
  });
}
