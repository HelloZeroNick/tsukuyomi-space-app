import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/model_protocol.dart';
import 'package:tsukuyomi_space_app/core/models.dart';

Stream<List<int>> reply(List<String> parts) => Stream.fromIterable([
  for (final part in parts)
    utf8.encode(
      'data: ${jsonEncode({
        'choices': [
          {
            'index': 0,
            'delta': {'content': part},
          },
        ],
      })}\n\n',
    ),
  utf8.encode(
    'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
  ),
]);

void main() {
  test(
    'stream byte bounds preserve surrogate pairs split between JSON deltas',
    () async {
      final high = String.fromCharCode(0xd83d),
          low = String.fromCharCode(0xde00);
      final events = await decodeModelStream(
        reply([high, '', low]),
        'openai',
        limits: const ModelLimits(textBytes: 4),
      ).toList();
      expect(events.last.completion!.reply, '😀');
      await expectLater(
        decodeModelStream(
          reply([high, low]),
          'openai',
          limits: const ModelLimits(textBytes: 3),
        ).toList(),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test(
    'unpaired surrogates and mixed Chinese retain exact UTF-8 limits',
    () async {
      final parts = ['中', String.fromCharCode(0xd800), 'a', '文'];
      final size = utf8.encode(parts.join()).length;
      final events = await decodeModelStream(
        reply(parts),
        'openai',
        limits: ModelLimits(textBytes: size),
      ).toList();
      expect(events.last.completion!.reply, parts.join());
      await expectLater(
        decodeModelStream(
          reply(parts),
          'openai',
          limits: ModelLimits(textBytes: size - 1),
        ).toList(),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
}
