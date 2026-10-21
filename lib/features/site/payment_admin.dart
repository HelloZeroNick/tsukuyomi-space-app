import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/payments.dart';
import 'management_service.dart';
import 'native_site_shell.dart';

class PaymentAdmin extends StatefulWidget {
  const PaymentAdmin({super.key, required this.api});
  final ManagementService api;
  @override
  State<PaymentAdmin> createState() => _PaymentAdminState();
}

class _PaymentAdminState extends State<PaymentAdmin> {
  Map<String, dynamic> _settings = {}, _orders = {};
  final _products = <Map<String, dynamic>>[];
  bool _busy = false, _enabled = false;
  String _error = '', _notice = '', _status = '';
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int) action) async {
    if (_busy) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await action(epoch);
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = e is ApiFailure ? e.message : '支付管理暂时不可用');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run((epoch) async {
    final results = await Future.wait([
      widget.api.data('GET', '/payments/settings'),
      widget.api.data('GET', '/payments/orders'),
    ]);
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _settings = Map<String, dynamic>.from(results[0] as Map);
      _enabled = _settings['enabled'] == true;
      _products.clear();
      _products.addAll(
        (_settings['products'] as List).whereType<Map>().map(
          (p) => Map<String, dynamic>.from(p),
        ),
      );
      _orders = Map<String, dynamic>.from(results[1] as Map);
    });
  });
  Future<void> _history(int page) async {
    final result = await widget.api.data(
      'GET',
      '/payments/orders?page=$page&status=$_status',
    );
    if (mounted) {
      setState(() => _orders = Map<String, dynamic>.from(result as Map));
    }
  }

  Future<void> _save() => _run((epoch) async {
    final result = await widget.api.data('PUT', '/payments/settings', {
      'enabled': _enabled,
      'products': _products,
    });
    if (mounted && epoch == _epoch) {
      setState(() {
        _settings = Map<String, dynamic>.from(result as Map);
        _notice = '支付配置已保存';
      });
    }
  });
  Widget _field(
    Map<String, dynamic> product,
    String name,
    String label, {
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      initialValue: '${product[name] ?? ''}',
      enabled: !_busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      onChanged: (value) => product[name] = value,
    ),
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_error.isNotEmpty)
        Text(
          _error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (_notice.isNotEmpty) Text(_notice),
      TextButton(
        onPressed: _busy ? null : _load,
        child: const Text('重新读取支付配置'),
      ),
      if (_settings.isNotEmpty)
        NativeSiteSection(
          title: '支付宝收款',
          subtitle: '仅超级管理员可配置',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                (_settings['readiness'] as Map)['configured'] == true
                    ? '服务器支付配置已就绪'
                    : '服务器支付配置未就绪',
              ),
              Text(
                (_settings['readiness'] as Map)['mobileCheckout'] == true
                    ? '手机网站支付已配置'
                    : '手机网站支付尚未配置',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开放在线收款'),
                value: _enabled,
                onChanged: _busy ? null : (v) => setState(() => _enabled = v),
              ),
              for (final product in _products)
                Card(
                  key: ObjectKey(product),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _field(product, 'id', '商品编号'),
                        _field(product, 'title', '商品名称'),
                        _field(product, 'description', '商品说明'),
                        _field(product, 'price', '价格（元）', number: true),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('上架商品'),
                          value: product['enabled'] == true,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => product['enabled'] = v),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('支付成功后按实付金额充值到网站余额'),
                          value: product['walletCredit'] == true,
                          onChanged: _busy
                              ? null
                              : (v) =>
                                    setState(() => product['walletCredit'] = v),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() => _products.remove(product)),
                          child: const Text('移除此商品'),
                        ),
                      ],
                    ),
                  ),
                ),
              TextButton(
                onPressed: _busy || _products.length >= 20
                    ? null
                    : () => setState(
                        () => _products.add({
                          'id': '',
                          'title': '',
                          'description': '',
                          'price': '',
                          'enabled': false,
                          'walletCredit': false,
                        }),
                      ),
                child: const Text('新增商品'),
              ),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存支付配置'),
              ),
            ],
          ),
        ),
      NativeSiteSection(
        title: '支付订单',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: '订单状态'),
              items: [
                for (final item in {
                  '': '全部',
                  'pending': '待支付',
                  'paid': '已支付',
                  'closed': '已关闭',
                }.entries)
                  DropdownMenuItem(value: item.key, child: Text(item.value)),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _status = v!);
                      _run((e) => _history(1));
                    },
            ),
            for (final order
                in (_orders['items'] as List? ?? []).whereType<Map>())
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText('${order['id']}'),
                      Text(
                        '${order['userId'] ?? ''} · ${order['title']} · ¥${order['amount']}',
                      ),
                      Text(
                        '${paymentStatus(order)} · ${order['walletCredited'] == true ? '已充值到账' : ''}',
                      ),
                      OutlinedButton(
                        onPressed: _busy || order['status'] == 'paid'
                            ? null
                            : () => _run((epoch) async {
                                await widget.api.data(
                                  'POST',
                                  '/payments/orders/${order['id']}/refresh',
                                );
                                if (mounted && epoch == _epoch) {
                                  await _history(_orders['page'] as int? ?? 1);
                                }
                              }),
                        child: const Text('支付宝查单'),
                      ),
                    ],
                  ),
                ),
              ),
            if ((_orders['totalPages'] as int? ?? 1) > 1)
              Wrap(
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: _busy || _orders['page'] == 1
                        ? null
                        : () => _run(
                            (e) => _history((_orders['page'] as int) - 1),
                          ),
                    child: const Text('上一页'),
                  ),
                  Text('${_orders['page']} / ${_orders['totalPages']}'),
                  TextButton(
                    onPressed: _busy || _orders['page'] == _orders['totalPages']
                        ? null
                        : () => _run(
                            (e) => _history((_orders['page'] as int) + 1),
                          ),
                    child: const Text('下一页'),
                  ),
                ],
              ),
          ],
        ),
      ),
    ],
  );
}
