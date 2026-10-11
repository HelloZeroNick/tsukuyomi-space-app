import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_provider.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_protocol.dart';

const claudeUrl = 'https://api.anthropic.com/v1/messages';
const minimaxUrl = 'https://api.minimaxi.com/anthropic/v1/messages';
final claude = Uri.parse(claudeUrl), minimax = Uri.parse(minimaxUrl);
RoomSettings claudeSettings({
  String url = claudeUrl,
  String model = 'claude-opus-5-5',
  Map<String, dynamic> options = const {},
}) => RoomSettings(
  llmUrl: url,
  model: model,
  apiKey: 'private-key',
  options: options,
);
http.Response jsonReply(Map data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);
final refused = throwsA(
  isA<ApiFailure>()
      .having((e) => e is ModelIncompleteFailure, 'retryable', false)
      .having((e) => e.message, 'message', contains('拒绝')),
);

void main() {
  test('Claude omits sampling, raises max_tokens and opts into fallback only on the Claude API', () {
    for (final model in [
      'claude-fable-5-1',
      'claude-opus-5-5',
      'claude-opus-5',
      ' claude-sonnet-5-5 ',
    ]) {
      expect(
        roomMessagesOptions(claude, model, maxTokens: 900, temperature: .25),
        {'max_tokens': 16000, 'fallbacks': 'default'},
      );
    }
    for (final model in [
      'claude-haiku-4-5',
      'claude-sonnet-5',
      'claude-opus-5-5-20260101',
    ]) {
      expect(roomMessagesOptions(claude, model), isEmpty);
    }
    expect(roomMessagesOptions(claude, 'claude-haiku-4-5', maxTokens: 32000), {
      'max_tokens': 32000,
    });
    expect(roomMessagesOptions(minimax, 'claude-opus-5-5', maxTokens: 900), {
      'max_tokens': 900,
      'temperature': 1,
    });
    expect(
      roomMessagesOptions(minimax, 'MiniMax-M2', temperature: null),
      isEmpty,
    );

    final body = roomChatBody(claudeSettings(), 'system', [], 'hello');
    expect(body.containsKey('temperature'), isFalse);
    expect(body.containsKey('top_p'), isFalse);
    expect(body['max_tokens'], 16384);
    expect(body['fallbacks'], 'default');
    final older = roomChatBody(
      claudeSettings(model: 'claude-haiku-4-5'),
      'system',
      [],
      'hello',
    );
    expect(older.containsKey('temperature'), isFalse);
    expect(older.containsKey('fallbacks'), isFalse);
    final compatible = roomChatBody(
      claudeSettings(url: minimaxUrl),
      'system',
      [],
      'hello',
    );
    expect(compatible['temperature'], 1);
    expect(compatible.containsKey('fallbacks'), isFalse);
  });

  test('Claude headers carry a valid workspace and fallback beta, never the browser opt-in', () {
    expect(claudeWorkspaceId('  wrkspc_01AbC-x_y  '), 'wrkspc_01AbC-x_y');
    expect(claudeWorkspaceId('wrkspc_${'a' * 120}'), 'wrkspc_${'a' * 120}');
    for (final invalid in [
      null,
      '',
      'wrkspc_',
      'team',
      'wrkspc_a/b',
      'wrkspc_${'a' * 121}',
    ]) {
      expect(claudeWorkspaceId(invalid), '');
    }
    final headers = roomChatHeaders(
      claudeSettings(options: {'anthropicWorkspaceId': ' wrkspc_team '}),
      claude,
    );
    expect(headers['x-api-key'], 'private-key');
    expect(headers['anthropic-version'], '2023-06-01');
    expect(headers['anthropic-workspace-id'], 'wrkspc_team');
    expect(headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    expect(headers.containsKey('Authorization'), isFalse);
    expect(
      headers.keys,
      isNot(contains('anthropic-dangerous-direct-browser-access')),
    );
    final unscoped = roomChatHeaders(
      claudeSettings(
        model: 'claude-haiku-4-5',
        options: {'anthropicWorkspaceId': 'team'},
      ),
      claude,
    );
    expect(unscoped.containsKey('anthropic-workspace-id'), isFalse);
    expect(unscoped.containsKey('anthropic-beta'), isFalse);
    final compatible = roomChatHeaders(
      claudeSettings(
        url: minimaxUrl,
        options: {'anthropicWorkspaceId': 'wrkspc_team'},
      ),
      minimax,
    );
    expect(compatible['x-api-key'], 'private-key');
    expect(compatible.containsKey('anthropic-workspace-id'), isFalse);
    expect(compatible.containsKey('anthropic-beta'), isFalse);
  });

  test('one-shot status check fails Claude refusals without treating them as truncation', () {
    final partial = [
      {'type': 'text', 'text': '半句'},
    ];
    expect(
      () => validateCompletion({'content': partial, 'stop_reason': 'refusal'}),
      refused,
    );
    expect(
      () =>
          validateCompletion({'content': partial, 'stop_reason': 'max_tokens'}),
      throwsA(isA<ModelIncompleteFailure>()),
    );
    validateCompletion({'content': partial, 'stop_reason': 'end_turn'});
  });

  test('direct Room requests send the Claude contract and never return refused text', () async {
    final requests = <http.Request>[];
    var answer = <String, dynamic>{
      'content': [
        {'type': 'text', 'text': '连接成功'},
      ],
      'stop_reason': 'end_turn',
    };
    final client = LlmClient(
      clientFactory: () => MockClient((req) async {
        requests.add(req);
        return jsonReply(answer);
      }),
    );
    final settings = claudeSettings(
      options: {'anthropicWorkspaceId': 'wrkspc_team'},
    );
    expect(await client.reply(settings, [], '测试').join(), '连接成功');
    final request = requests.single, body = jsonDecode(request.body) as Map;
    expect(request.url.toString(), claudeUrl);
    expect(request.headers['anthropic-workspace-id'], 'wrkspc_team');
    expect(
      request.headers['anthropic-beta'],
      'server-side-fallback-2026-07-01',
    );
    expect(body['fallbacks'], 'default');
    expect(body['max_tokens'], greaterThanOrEqualTo(16000));
    expect(body.containsKey('temperature'), isFalse);
    expect(body.containsKey('top_p'), isFalse);

    // Diary, Japanese TTS translation and the settings test all join this
    // stream, so a declined or cut reply is never saved, spoken or shown.
    answer = {
      'content': [
        {'type': 'text', 'text': '半句'},
      ],
      'stop_reason': 'refusal',
    };
    await expectLater(client.reply(settings, [], '测试').join(), refused);
    answer = {...answer, 'stop_reason': 'max_tokens'};
    await expectLater(
      client.reply(settings, [], '测试').join(),
      throwsA(isA<ModelIncompleteFailure>()),
    );
    final streamed = LlmClient(
      clientFactory: () => MockClient(
        (_) async => http.Response(
          [
            {
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'text', 'text': ''},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': '半句'},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'refusal'},
            },
            {'type': 'message_stop'},
          ].map((e) => 'data: ${jsonEncode(e)}\n\n').join(),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        ),
      ),
    );
    await expectLater(streamed.reply(settings, [], '测试').join(), refused);
  });

  test('site proxy receives only a valid Claude workspace ID', () async {
    final bodies = <Map>[];
    final client = LlmClient(
      clientFactory: () => MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map);
        return jsonReply({'reply': '好的'});
      }),
    );
    for (final (url, workspace) in [
      (claudeUrl, ' wrkspc_team '),
      (claudeUrl, 'team'),
      (minimaxUrl, 'wrkspc_team'),
    ]) {
      await client
          .reply(
            claudeSettings(
              url: url,
              options: {'llmProxy': true, 'anthropicWorkspaceId': workspace},
            ),
            [],
            '你好',
          )
          .join();
    }
    expect(bodies.map((b) => b['workspaceId']), ['wrkspc_team', null, null]);
  });

  test(
    'desktop agent sends the Claude Messages contract and rejects refusals',
    () async {
      final requests = <http.Request>[];
      var answer = <String, dynamic>{
        'content': [
          {'type': 'text', 'text': '完成。'},
        ],
        'stop_reason': 'end_turn',
      };
      AgentProviderBridge bridge(String url) => AgentProviderBridge(
        claudeSettings(
          url: url,
          options: {'anthropicWorkspaceId': 'wrkspc_team'},
        ),
        clientFactory: () => MockClient((req) async {
          requests.add(req);
          return jsonReply(answer);
        }),
      );
      final input = {
        'messages': [
          {'role': 'user', 'content': '整理'},
        ],
        'max_tokens': 4096,
        'temperature': .2,
        'top_p': .9,
      };
      final result = await bridge(claudeUrl).complete(input);
      expect(result['choices'][0]['message']['content'], '完成。');
      var body = jsonDecode(requests.last.body) as Map;
      expect(body['max_tokens'], 16000);
      expect(body['fallbacks'], 'default');
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(requests.last.headers['anthropic-workspace-id'], 'wrkspc_team');
      expect(
        requests.last.headers['anthropic-beta'],
        'server-side-fallback-2026-07-01',
      );
      expect(
        requests.last.headers.keys,
        isNot(contains('anthropic-dangerous-direct-browser-access')),
      );

      await bridge(minimaxUrl).complete(input);
      body = jsonDecode(requests.last.body) as Map;
      expect(body['max_tokens'], 4096);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('fallbacks'), isFalse);
      expect(
        requests.last.headers.containsKey('anthropic-workspace-id'),
        false,
      );

      answer = {...answer, 'stop_reason': 'refusal'};
      final refusing = bridge(claudeUrl);
      await expectLater(refusing.complete(input), refused);
      expect(refusing.lastFailure?.message, contains('拒绝'));
    },
  );
}
