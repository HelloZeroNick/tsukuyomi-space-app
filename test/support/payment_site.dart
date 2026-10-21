import 'dart:async';

import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';

import 'fakes.dart';

/// Offline fixtures only. These never contact a payment provider.
class PaymentFixtureSite extends FakeSite
    implements SiteDataService, OfficialDataService {
  bool pluginOffline = false, paidProof = false, walletCredited = false;
  bool operator = false;
  final adminWrites = <Map<String, dynamic>>[];
  final calls = <String>[];
  final keys = <String>[];
  Map<String, dynamic>? order;
  Completer<Map<String, dynamic>>? aliceDashboard;
  Map<String, dynamic> get wallet => {
    'available_atoms': userId == 'bob'
        ? '2000000000'
        : paidProof && walletCredited
        ? '2000000000'
        : '1000000000',
    'balance_atoms': userId == 'bob'
        ? '2000000000'
        : paidProof && walletCredited
        ? '2000000000'
        : '1000000000',
    'held_atoms': '0',
    'unlimited': false,
  };
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add('$method $path');
    dynamic data = {};
    if (path == '/api/payments/catalog') {
      data = {
        'enabled': true,
        'mobileCheckout': false,
        'appCheckout': true,
        'products': [
          {
            'id': 'topup',
            'title': '网站余额充值',
            'description': '离线模拟商品',
            'price': '1.00',
            'walletCredit': true,
          },
        ],
      };
    }
    if (path == '/api/payments/wallet') data = wallet;
    if (path.startsWith('/api/payments/orders?')) {
      data = {
        'page': 1,
        'totalPages': 1,
        'items': [if (order != null) order],
      };
    }
    if (path == '/api/payments/orders' && method == 'POST') {
      keys.add('${body!['requestKey']}');
      order = {
        'id': 'TS${List.filled(32, 'a').join()}',
        'title': '网站余额充值',
        'amount': '1.00',
        'status': 'pending',
        'expired': false,
        'channel': body['channel'],
        'createdAt': 1792540800000,
        'walletCredited': false,
        'walletCreditAmount': '1.00',
      };
      data = order;
    }
    if (path.endsWith('/checkout')) {
      data = {
        'type': 'app',
        'appId': '2099000000000002',
        'environment': 'sandbox',
        'orderString': 'fixture',
      };
    }
    if (path.endsWith('/refresh')) {
      if (paidProof) {
        order = {...order!, 'status': 'paid', 'walletCredited': true};
        walletCredited = true;
      }
      data = order;
    }
    return {'success': true, 'data': data};
  }

  Map<String, dynamic> get dashboard => {
    'me': {
      'site_user_id': userId,
      'account_id': 'official-$userId',
      'operator': operator,
    },
    'enabled': true,
    'models': [
      {
        'id': 'deepseek-chat',
        'provider': 'deepseek',
        'enabled': true,
        'max_output_tokens': 2048,
        'price': {
          'rates_per_million_money_atoms': {
            'input_uncached': '2000000000',
            'input_cached': '200000000',
            'output': '3000000000',
          },
        },
      },
    ],
    'usage': {
      'items': [
        {
          'request_id': 'req-first',
          'model': 'deepseek-chat',
          'status': 'settled',
          'charged_atoms': '1000000',
          'created_at': '2026-10-21T00:00:00Z',
          'usage': {
            'input_uncached': '100',
            'input_cached': '0',
            'output': '20',
          },
        },
      ],
      'next_cursor': '1',
    },
    'statement': {
      'month': '2026-10',
      'charged_atoms': '1000000',
      'credited_atoms': '1000000000',
      'pending_hold_atoms': '0',
    },
  };
  @override
  Future<Map<String, dynamic>> officialRequest(
    String site,
    String method,
    String path, {
    String? account,
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method official$path');
    if (pluginOffline) throw const ApiFailure('直供服务离线');
    if (path == '/api/dashboard') {
      if (userId == 'alice' && aliceDashboard != null) {
        return aliceDashboard!.future;
      }
      return dashboard;
    }
    if (account != 'official-$userId') {
      throw const ApiFailure('账号已切换', status: 409);
    }
    if (path == '/api/admin/settings') {
      if (method == 'POST') adminWrites.add({...?body});
      return {
        'revision': adminWrites.length + 1,
        'enabled': true,
        'provider': 'deepseek',
        'model': 'deepseek-chat',
        'maxInputTokens': 4096,
        'maxOutputTokens': 2048,
        'perUserConcurrent': 1,
        'requestsPerMinute': 10,
        'published': true,
        'usageVerified': true,
        'boundVerified': true,
        'simulation': false,
        'rates': {
          'input_uncached': '2000000000',
          'input_cached': '200000000',
          'output': '3000000000',
        },
        'providers': [
          {
            'id': 'deepseek',
            'name': 'DeepSeek',
            'hasKey': true,
            'host': 'api.deepseek.com',
          },
        ],
      };
    }
    if (path == '/api/admin/reconciliation') return {'items': []};
    if (path.startsWith('/api/usage')) {
      return {
        'items': [
          {
            'request_id': 'req-second',
            'model': 'deepseek-chat',
            'status': 'released',
          },
        ],
      };
    }
    if (path.startsWith('/api/statements/monthly')) {
      return {
        'month': '2026-09',
        'charged_atoms': '5000000',
        'credited_atoms': '0',
        'pending_hold_atoms': '0',
      };
    }
    if (path.startsWith('/api/requests')) {
      return {
        'request_id': 'req-first',
        'model': 'deepseek-chat',
        'status': 'settled',
        'charged_atoms': '1000000',
      };
    }
    return {};
  }
}
