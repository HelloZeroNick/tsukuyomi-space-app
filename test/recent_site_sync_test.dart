import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/model_catalog.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/model_runtime.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_context.dart';
import 'package:tsukuyomi_space_app/core/room_knowledge.dart';
import 'package:tsukuyomi_space_app/features/site/site_notice.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final model = fixture('model_runtime_web');
  for (final (index, item) in (model['cases'] as List).indexed) {
    test('independent website runtime fixture $index', () {
      final s = item['settings'];
      final runtime = ModelRuntime(
        RoomSettings(
          llmUrl: s['apiUrl'],
          model: s['model'],
          options: {'runtimeConfig': s['runtimeConfig']},
        ),
      );
      expect(
        runtime.apply(Map<String, dynamic>.from(item['payload'])),
        item['expected'],
      );
      expect(runtime.resolveCapabilities(), item['capabilities']);
    });
  }
  for (final item in model['plans'] as List) {
    final input = item['input'];
    test('catalog official host ${input['apiUrl']}', () {
      final settings = RoomSettings(
        llmUrl: input['apiUrl'],
        apiKey: input['apiKey'],
        options: {
          'aliyunWorkspaceId': input['workspaceId'],
          'anthropicWorkspaceId': input['workspaceId'],
        },
      );
      if (item['error'] != null) {
        expect(() => catalogPlan(settings), throwsA(isA<ApiFailure>()));
        return;
      }
      final plan = catalogPlan(settings), expected = item['expected'];
      expect(plan.provider, expected['provider']);
      final url = Uri.parse(expected['url']);
      expect(plan.url.host, url.host);
      expect(plan.url.path, url.path);
      expect(plan.url.queryParameters, url.queryParameters);
      expect(plan.headers, expected['headers']);
    });
  }
  for (final item in model['catalogCases'] as List) {
    test('catalog filters actual text models ${item['provider']}', () {
      final normalized = normalizeCatalog(item['payload'], item['provider']);
      Map project(Map row) => {
        for (final key in [
          'id',
          'nativeId',
          'label',
          'contextLength',
          'capabilities',
        ])
          key: row[key],
      };
      expect(
        normalized.models.map(project).toList(),
        (item['expected']['models'] as List).cast<Map>().map(project).toList(),
      );
      expect(normalized.cursor, item['expected']['nextCursor']);
    });
  }
  test('untrusted catalogs cannot receive a credential', () async {
    var calls = 0;
    final catalog = ModelCatalog(
      client: MockClient((r) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(catalog.close);
    for (final url in [
      'https://api.deepseek.com.evil.test/chat/completions',
      'https://user:pass@api.deepseek.com/chat/completions',
      'https://api.deepseek.com/chat/completions?redirect=evil',
      'http://api.deepseek.com/chat/completions',
    ]) {
      await expectLater(
        catalog.load(RoomSettings(llmUrl: url, apiKey: 'secret')),
        throwsA(isA<ApiFailure>()),
      );
    }
    expect(calls, 0);
  });
  test('catalog refuses redirects and bounds response bytes', () async {
    for (final status in [302, 200]) {
      final catalog = ModelCatalog(
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.url.host, 'api.deepseek.com');
          expect(request.headers['Authorization'], 'Bearer fixture-key');
          return http.Response(
            status == 200 ? ' ' * (2 * 1024 * 1024 + 1) : '',
            status,
            headers: {'location': 'https://evil.test'},
          );
        }),
      );
      await expectLater(
        catalog.load(
          const RoomSettings(
            llmUrl: 'https://api.deepseek.com/chat/completions',
            apiKey: 'fixture-key',
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      catalog.close();
    }
  });
  RoomSettings claude([String workspace = '']) => RoomSettings(
    llmUrl: 'https://api.anthropic.com/v1/messages',
    apiKey: 'fixture-key',
    options: {
      'anthropicWorkspaceId': workspace,
      'aliyunWorkspaceId': 'aliyun-only',
    },
  );
  test('Claude catalog sends its own headers, workspace and cursor', () {
    var plan = catalogPlan(claude());
    expect(plan.provider, 'anthropic');
    expect(
      plan.url.toString(),
      'https://api.anthropic.com/v1/models?limit=1000',
    );
    expect(plan.headers, {
      'Accept': 'application/json',
      'x-api-key': 'fixture-key',
      'anthropic-version': '2023-06-01',
    });
    plan = catalogPlan(claude(' wrkspc_01-ab '), cursor: 'claude-opus-5-5');
    expect(plan.url.queryParameters, {
      'limit': '1000',
      'after_id': 'claude-opus-5-5',
    });
    expect(plan.headers['anthropic-workspace-id'], 'wrkspc_01-ab');
    expect(catalogWorkspaceId(claude(' wrkspc_01-ab ')), 'wrkspc_01-ab');
    expect(
      catalogWorkspaceId(
        const RoomSettings(
          llmUrl: 'https://dashscope.aliyuncs.com/v1/chat/completions',
          options: {
            'aliyunWorkspaceId': 'aliyun-only',
            'anthropicWorkspaceId': 'wrkspc_a',
          },
        ),
      ),
      'aliyun-only',
    );
    // Invalid workspace IDs are never sent; a native app needs no CORS opt-in.
    for (final workspace in [
      'workspace-test',
      'wrkspc_',
      'wrkspc_a b',
      'wrkspc_${'a' * 121}',
    ]) {
      expect(
        () => catalogPlan(claude(workspace)),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message,
            'message',
            contains('wrkspc_'),
          ),
        ),
      );
    }
    expect(
      plan.headers.keys,
      isNot(contains('anthropic-dangerous-direct-browser-access')),
    );
    expect(
      () => catalogPlan(claude(), cursor: 'claude/opus'),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('Claude catalog reads its model fields and pages by last_id', () {
    final page = normalizeCatalog({
      'data': [
        {
          'type': 'model',
          'id': 'claude-opus-5-5',
          'display_name': 'Claude Opus 5.5',
          'created_at': '2026-07-01T00:00:00Z',
          'max_input_tokens': 1000000,
          'capabilities': {
            'image_input': {'supported': true},
          },
        },
        {
          'type': 'model',
          'id': 'claude-text',
          'capabilities': {
            'image_input': {'supported': false},
          },
        },
      ],
      'has_more': true,
      'last_id': 'claude-text',
    }, 'anthropic');
    expect(page.cursor, 'claude-text');
    expect(page.models.first['label'], 'Claude Opus 5.5');
    expect(page.models.first['contextLength'], 1000000);
    expect(
      page.models.first['created'],
      DateTime.utc(2026, 7).millisecondsSinceEpoch ~/ 1000,
    );
    expect(page.models.first['capabilities'], {'image': true});
    expect(page.models.last['capabilities'], {'image': false});
    expect(page.models.last['created'], 0);
    expect(
      normalizeCatalog({
        'data': [],
        'has_more': false,
        'last_id': 'x',
      }, 'anthropic').cursor,
      '',
    );
  });
  test(
    'Claude catalog follows pages and explains a missing workspace',
    () async {
      final seen = <Uri>[];
      var catalog = ModelCatalog(
        client: MockClient((request) async {
          seen.add(request.url);
          expect(request.headers['x-api-key'], 'fixture-key');
          expect(request.headers['anthropic-version'], '2023-06-01');
          expect(request.headers['anthropic-workspace-id'], 'wrkspc_fixture');
          expect(request.headers['Authorization'], isNull);
          final first = request.url.queryParameters['after_id'] == null;
          final id = first ? 'claude-opus-5-5' : 'claude-sonnet-5-5';
          return http.Response(
            jsonEncode({
              'data': [
                {'id': id},
              ],
              'has_more': first,
              'last_id': id,
            }),
            200,
          );
        }),
      );
      final rows = await catalog.load(claude('wrkspc_fixture'));
      expect(rows.map((row) => row['id']), [
        'claude-opus-5-5',
        'claude-sonnet-5-5',
      ]);
      expect(seen.last.queryParameters['after_id'], 'claude-opus-5-5');
      await catalog.load(claude('wrkspc_fixture'));
      expect(seen.length, 2, reason: 'same workspace reuses the cached list');
      catalog.close();
      catalog = ModelCatalog(
        client: MockClient((_) async => http.Response('{}', 400)),
      );
      addTearDown(catalog.close);
      await expectLater(
        catalog.load(claude()),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message,
            'message',
            contains('Anthropic 工作区 ID'),
          ),
        ),
      );
    },
  );
  test('Claude API omits sampling and sends effort only where supported', () {
    Map<String, dynamic> apply(String url, String model, Map payload) {
      final key = ModelRuntime(RoomSettings(llmUrl: url)).providerKey;
      return ModelRuntime(
        RoomSettings(
          llmUrl: url,
          model: model,
          options: {
            'runtimeConfig': {
              'providers': {
                key: {
                  'parameters': {
                    'temperature': .7,
                    'topP': .9,
                    'reasoningEffort': 'high',
                  },
                },
              },
            },
          },
        ),
      ).apply(Map<String, dynamic>.from(payload));
    }

    const claudeUrl = 'https://api.anthropic.com/v1/messages';
    final payload = {
      'max_tokens': 16000,
      'temperature': 1,
      'output_config': {'format': 'fixture'},
    };
    for (final model in [
      'claude-opus-5-5',
      'claude-fable-5-1',
      'claude-opus-4-6',
      'claude-sonnet-4-6',
      'claude-haiku-5-0',
    ]) {
      final body = apply(claudeUrl, model, payload);
      expect(body.containsKey('temperature'), isFalse, reason: model);
      expect(body.containsKey('top_p'), isFalse, reason: model);
      expect(body['output_config'], {
        'format': 'fixture',
        'effort': 'high',
      }, reason: model);
    }
    expect(payload['output_config'], {'format': 'fixture'});
    for (final model in ['claude-sonnet-4-5', 'claude-haiku-4-5', 'claude-3']) {
      final body = apply(claudeUrl, model, payload);
      expect(body.containsKey('temperature'), isFalse, reason: model);
      expect(body['output_config'], {'format': 'fixture'}, reason: model);
    }
    // Other Messages-compatible gateways keep sampling and get no effort.
    final minimax = apply('https://api.minimaxi.com/anthropic', 'MiniMax-M2', {
      'max_tokens': 4096,
      'temperature': 1,
    });
    expect(minimax['temperature'], .7);
    expect(minimax['top_p'], .9);
    expect(minimax.containsKey('output_config'), isFalse);
    final runtime = ModelRuntime(claude());
    expect(
      runtime.allowedMappings('reasoningEffort'),
      contains('output_config.effort'),
    );
    expect(
      ModelRuntime(
        const RoomSettings(
          llmUrl: 'https://api.openai.com/v1/chat/completions',
        ),
      ).allowedMappings('reasoningEffort'),
      isNot(contains('output_config.effort')),
    );
    final capabilities = ModelRuntime(
      claude().copyWith(model: 'claude-opus-5-5'),
    ).resolveCapabilities();
    for (final key in ['text', 'image', 'tools', 'streaming']) {
      expect(capabilities[key]['value'], isTrue, reason: key);
      expect(capabilities[key]['source'], 'builtin', reason: key);
    }
    expect(
      ModelRuntime(
        const RoomSettings(
          llmUrl: 'https://openrouter.ai/api/v1/chat/completions',
          model: 'claude-opus-5-5',
        ),
      ).resolveCapabilities()['image']['source'],
      'unknown',
    );
  });
  test('runtime rejects unlisted mappings and invalid values', () {
    for (final layer in [
      {
        'mappings': {'temperature': 'api_key'},
      },
      {
        'parameters': {'maxOutputTokens': 15},
      },
      {
        'parameters': {'temperature': double.nan},
      },
      {
        'parameters': {'reasoningEnabled': 'true'},
      },
    ]) {
      expect(
        () => normalizeModelRuntime({
          'models': {'provider#model': layer},
        }),
        throwsA(isA<ApiFailure>()),
      );
    }
  });
  for (final (url, field) in [
    ('https://api.deepseek.com/chat/completions', 'max_tokens'),
    ('https://api.openai.com/v1/responses', 'max_output_tokens'),
    ('https://api.anthropic.com/v1/messages', 'max_tokens'),
    ('http://localhost:11434/api/chat', 'options.num_predict'),
  ]) {
    test('native transport applies runtime configuration $url', () async {
      var requests = 0;
      final client =
          LlmClient(
              clientFactory: () => MockClient((request) async {
                requests++;
                final body = jsonDecode(request.body) as Map;
                final parts = field.split('.');
                expect(
                  parts.length == 1 ? body[field] : body[parts[0]][parts[1]],
                  128,
                );
                expect(body['stream'], isFalse);
                expect(body['tools'], isNull);
                return http.Response(
                  jsonEncode({'reply': '配置生效'}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            )
            ..tools = [
              {
                'name': 'web_search',
                'description': 'fixture',
                'parameters': {'type': 'object'},
              },
            ]
            ..executeTool = (_) async =>
                throw StateError('disabled tools must not run');
      addTearDown(client.cancel);
      final key = '$url#fixture-model';
      final settings = RoomSettings(
        llmUrl: url,
        model: 'fixture-model',
        options: {
          'runtimeConfig': {
            'models': {
              key: {
                'parameters': {'maxOutputTokens': 128},
                'capabilities': {'streaming': false, 'tools': false},
              },
            },
          },
        },
      );
      expect(await client.reply(settings, [], '测试配置').join(), '配置生效');
      expect(requests, 1);
    });
  }
  final knowledge = fixture('room_knowledge_web');
  for (final item in knowledge['cases'] as List) {
    test('website knowledge ranking ${item['message']}', () {
      final history = [
        for (final message in item['history'] as List)
          ChatTurn(
            id: 'prior',
            createdAt: DateTime(2026, 10, 1),
            user: message['content'],
            assistant: '模型编造的旧结论',
          ),
      ];
      final selected = selectRoomKnowledge(
        item['message'],
        const RoomSettings(),
        history: history,
      );
      expect(selected.map((row) => row['id']).toList(), item['ids']);
      expect(
        shouldRetrieveRoomPersona(
          roomKnowledgeQuery(item['message'], history),
          selected,
        ),
        item['persona'],
      );
    });
  }
  for (final (index, item) in (knowledge['migrations'] as List).indexed) {
    test(
      'knowledge migration preserves reduced libraries and custom facts $index',
      () {
        final actual = roomKnowledgeEntries(
          RoomSettings(options: {'knowledge': item['entries']}),
        );
        Map project(Map row) => {
          'id': row['id'],
          'title': row['title'],
          'content': row['content'],
          'tags': row['tags'],
          'enabled': row['enabled'] != false,
          'edition': row['edition'] ?? '',
          'references': row['references'] ?? [],
          'spoiler': row['spoiler'] == true,
        };
        expect(
          actual.map(project).toList(),
          (item['expected'] as List).cast<Map>().map(project).toList(),
        );
      },
    );
  }
  test('30 retrieved memories share the source budget instead of starving later facts', () {
    final pack = packRoomContext({
      'memories': [
        for (var i = 0; i < 30; i++)
          {'id': 'memory-$i', 'content': '事实$i ${'x' * 1000}'},
      ],
    });
    expect(pack.trace.length, 30);
    expect(pack.trace.every((item) => item.includedChars == 100), isTrue);
    expect(
      pack.trace.fold<int>(0, (sum, item) => sum + item.includedChars),
      3000,
    );
    expect(pack.usedChars, lessThanOrEqualTo(8000));
    expect(memoryRetrievalLimit(const RoomSettings()), 12);
    expect(
      memoryRetrievalLimit(
        const RoomSettings(options: {'memoryRetrievalLimit': 99}),
      ),
      30,
    );
  });
  test(
    'notice links stay native internally and reject active or credential URLs',
    () {
      for (final value in [
        'javascript:alert(1)',
        'data:text/html,hello',
        '//evil.test',
        'https://u:p@evil.test',
        '/\\evil.test',
        '/path\nnext',
      ]) {
        expect(safeNoticeLink(value, 'https://yachiyo.hk'), isNull);
      }
      expect(
        safeNoticeLink(
          '/articles/42?q=story#comment-1',
          'https://yachiyo.hk',
        )?.internal,
        isTrue,
      );
      expect(
        safeNoticeLink(
          'https://www.yachiyo.hk/wiki',
          'https://yachiyo.hk',
        )?.internal,
        isTrue,
      );
      expect(
        safeNoticeLink(
          'https://external.test/page',
          'https://yachiyo.hk',
        )?.internal,
        isFalse,
      );
      expect(
        announcementContent({
          'siteAnnouncement': '欢迎访问月读空间',
          'visitPopupContent': '**新公告**',
        }),
        '**新公告**',
      );
      expect(noticeSummary('## 标题\n\n[正文](/stage)'), '标题');
    },
  );
}
