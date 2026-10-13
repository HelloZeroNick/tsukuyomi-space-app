import 'package:flutter/widgets.dart';

/// Observe only the values rendered by a Room surface. Notifications from
/// unrelated services never walk that surface's element or render tree.
class RoomSelector<T> extends StatefulWidget {
  const RoomSelector({
    super.key,
    required this.listenable,
    required this.select,
    required this.builder,
  });
  final Listenable listenable;
  final T Function() select;
  final WidgetBuilder builder;

  @override
  State<RoomSelector<T>> createState() => _RoomSelectorState<T>();
}

class _RoomSelectorState<T> extends State<RoomSelector<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select();
    widget.listenable.addListener(_changed);
  }

  void _changed() {
    final next = widget.select();
    if (next != _value) setState(() => _value = next);
  }

  @override
  void didUpdateWidget(RoomSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.select();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }
}
