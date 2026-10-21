import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:convert';

import 'package:tobias/tobias.dart';

import 'models.dart';
import 'site_client.dart';

String paymentStatus(Map order) => switch (order['status']) {
  'paid' => '已支付',
  'closed' => '已关闭',
  _ => order['expired'] == true ? '已到期，待确认' : '待支付',
};

bool get mobilePaymentPlatform =>
    !kIsWeb &&
    {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(defaultTargetPlatform);

Uri checkoutDestination(String value, {bool mobile = false}) {
  final uri = Uri.tryParse(value);
  if (value.length > 32768 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !{
        'https://openapi.alipay.com',
        'https://openapi-sandbox.dl.alipaydev.com',
      }.contains(uri.origin) ||
      uri.path != '/gateway.do' ||
      !{
        'alipay.trade.page.pay',
        'alipay.trade.wap.pay',
      }.contains(uri.queryParameters['method']) ||
      (mobile && uri.queryParameters['method'] != 'alipay.trade.wap.pay')) {
    throw const ApiFailure('支付链接无效，请刷新订单后重试');
  }
  return uri;
}

class AlipayCheckoutLauncher {
  AlipayCheckoutLauncher({
    Future<bool> Function(Uri)? open,
    Future<Map> Function(String, bool)? appPay,
  }) : _open =
           open ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _appPay =
           appPay ??
           ((order, sandbox) => Tobias().pay(
             order,
             evn: sandbox ? AliPayEvn.sandbox : AliPayEvn.online,
           ));
  final Future<bool> Function(Uri) _open;
  final Future<Map> Function(String, bool) _appPay;
  Future<void> payApp(
    Map<String, dynamic> checkout,
    Map<String, dynamic> order,
  ) async {
    final text = checkout['orderString'];
    if (checkout['type'] != 'app' ||
        text is! String ||
        text.length > 32768 ||
        !{'production', 'sandbox'}.contains(checkout['environment'])) {
      throw const ApiFailure('App 支付订单无效');
    }
    final params = Uri.splitQueryString(text);
    if (params.length != Uri(query: text).queryParametersAll.length ||
        Uri(query: text).queryParametersAll.values.any((v) => v.length != 1) ||
        params['method'] != 'alipay.trade.app.pay' ||
        params['app_id'] != checkout['appId'] ||
        !RegExp(r'^\d{16}$').hasMatch('${params['app_id']}') ||
        params['sign_type'] != 'RSA2' ||
        (params['sign'] ?? '').isEmpty) {
      throw const ApiFailure('App 支付签名参数无效');
    }
    Map biz;
    try {
      biz = jsonDecode(params['biz_content'] ?? '') as Map;
    } catch (_) {
      throw const ApiFailure('App 支付订单内容无效');
    }
    if (biz['product_code'] != 'QUICK_MSECURITY_PAY' ||
        biz['out_trade_no'] != order['id'] ||
        biz['total_amount'] != order['amount']) {
      throw const ApiFailure('App 支付订单与当前订单不一致');
    }
    Map result;
    try {
      result = await _appPay(text, checkout['environment'] == 'sandbox');
    } catch (_) {
      throw const ApiFailure('无法唤起支付宝，请确认已安装支付宝后重试');
    }
    // Even 9000 is only a hint to query the backend. It never credits a wallet.
    final status = '${result['resultStatus']}';
    if (status == '6001') throw const ApiFailure('已取消支付，可在我的订单中继续付款');
    if (!{'9000', '8000', '6004'}.contains(status)) {
      throw const ApiFailure('支付宝未确认付款，请核对订单后重试');
    }
  }

  Future<void> launch(String value, {required bool mobile}) async {
    final checkout = checkoutDestination(value, mobile: mobile);
    if (mobile) {
      final wallet = Uri(
        scheme: 'alipays',
        host: 'platformapi',
        path: '/startapp',
        query: 'appId=20000067&url=${Uri.encodeComponent(checkout.toString())}',
      );
      try {
        if (await _open(wallet)) return;
      } catch (_) {
        /* Try the HTTPS cashier. */
      }
    }
    if (!await _open(checkout)) {
      throw const ApiFailure('无法打开支付宝，请安装支付宝或系统浏览器后重试');
    }
  }
}

class PaymentService {
  PaymentService(this.client, this.site);
  final SiteDataService client;
  final String site;
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final result = await client.request(
      site,
      method,
      '/api/payments$path',
      body,
    );
    if (result['data'] is! Map) throw const ApiFailure('支付服务响应异常');
    return Map<String, dynamic>.from(result['data'] as Map);
  }
}
