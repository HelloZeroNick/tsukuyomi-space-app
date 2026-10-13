import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/site_localization.dart';
import 'room_controller.dart';
import 'room_style.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

/// The editor owns its focus, composing range and controller for its lifetime.
/// Input notifications update this surface, never the Room transcript/stage.
class RoomComposer extends StatefulWidget {
  const RoomComposer({
    super.key,
    required this.controller,
    required this.mobile,
    required this.onAttach,
    this.onTyping,
  });
  final RoomController controller;
  final bool mobile;
  final VoidCallback onAttach;
  final VoidCallback? onTyping;
  @override
  State<RoomComposer> createState() => RoomComposerState();
}

class RoomComposerState extends State<RoomComposer> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  late Object _state;
  late String _scope, _draft;
  RoomController get c => widget.controller;

  Object _snapshot() => (
    c.scope,
    c.loading,
    c.busy,
    c.generating,
    c.canSend,
    c.settings.demo,
    c.attachment != null,
  );

  @override
  void initState() {
    super.initState();
    _scope = c.scope;
    _draft = c.draft;
    _input.text = c.draft;
    _state = _snapshot();
    c.addListener(_changed);
    _input.addListener(_edited);
  }

  void _edited() => setState(() {});

  void _changed() {
    final next = _snapshot();
    final scopeChanged = _scope != c.scope;
    if (!c.generating &&
        (scopeChanged ||
            _draft != c.draft ||
            (_input.text.isEmpty && c.draft.isNotEmpty)) &&
        _input.text != c.draft) {
      _input.value = TextEditingValue(
        text: c.draft,
        selection: TextSelection.collapsed(offset: c.draft.length),
      );
    }
    _scope = c.scope;
    _draft = c.draft;
    if (_state != next) setState(() => _state = next);
  }

  void fillDraft(String value) {
    _input.text = value;
    _focus.requestFocus();
    unawaited(c.saveComposerDraft(value));
  }

  void _send() {
    if ((_input.text.trim().isEmpty && c.attachment == null) || !c.canSend) {
      return;
    }
    final value = _input.text;
    if (value.trim().length > 12000) {
      unawaited(c.send(value));
      return;
    }
    _input.clear();
    unawaited(c.send(value));
  }

  @override
  void didUpdateWidget(RoomComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _input.removeListener(_edited);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobile = widget.mobile;
    final p = RoomStyle(context);
    final composing = _input.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;
    final input = Shortcuts(
      shortcuts: {
        if (!mobile && !isComposing)
          const SingleActivator(LogicalKeyboardKey.enter):
              const _SendMessageIntent(),
        if (!isComposing) ...{
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              const _SendMessageIntent(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              const _SendMessageIntent(),
        },
      },
      child: Actions(
        actions: {
          _SendMessageIntent: CallbackAction<_SendMessageIntent>(
            onInvoke: (_) {
              _send();
              return null;
            },
          ),
        },
        child: TextField(
          key: const Key('message-input'),
          onChanged: (value) {
            widget.onTyping?.call();
            unawaited(c.saveComposerDraft(value));
          },
          controller: _input,
          focusNode: _focus,
          enabled: !c.loading && !c.busy,
          readOnly: c.generating,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.newline,
          style: TextStyle(
            fontSize: mobile ? 16 : 13,
            height: mobile ? 1.5 : 1.65,
            color: p.ink,
          ),
          decoration: InputDecoration(
            hintText: siteTranslate(
              context,
              mobile && c.settings.demo ? '离线演示 · 和八千代聊聊…' : '和八千代说点什么…',
            ),
            filled: false,
            isDense: true,
            hintStyle: TextStyle(
              fontSize: mobile ? 14 : 12,
              color: p.muted.withValues(alpha: .7),
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: mobile ? 5 : 2,
              vertical: mobile ? 10 : 2,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
          ),
        ),
      ),
    );
    final attach = Tooltip(
      message: '添加图片',
      child: IconButton(
        onPressed: c.canSend ? widget.onAttach : null,
        icon: Icon(CupertinoIcons.photo, size: mobile ? 22 : 18),
        style: IconButton.styleFrom(
          disabledForegroundColor: p.muted,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size(mobile ? 44 : 30, mobile ? 44 : 30),
        ),
      ),
    );
    final send = Tooltip(
      message: c.generating ? '停止生成' : '发送',
      child: FilledButton(
        onPressed: c.generating
            ? c.stop
            : (!c.canSend ||
                      (_input.text.trim().isEmpty && c.attachment == null)
                  ? null
                  : _send),
        style: FilledButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.primary.withValues(alpha: .5),
          disabledForegroundColor: p.onPrimary,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size(mobile ? 44 : 67, mobile ? 44 : 29),
          padding: EdgeInsets.symmetric(horizontal: mobile ? 0 : 10),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mobile) ...[
              Text(
                c.generating ? '停止' : '发送',
                style: const TextStyle(fontSize: 10),
              ),
              const SizedBox(width: 6),
            ],
            Icon(
              c.generating
                  ? CupertinoIcons.stop_fill
                  : CupertinoIcons.paperplane,
              size: mobile ? 24 : 16,
            ),
          ],
        ),
      ),
    );
    return Container(
      key: const Key('room-composer'),
      padding: mobile
          ? const EdgeInsets.all(6)
          : const EdgeInsets.fromLTRB(10, 12, 10, 9),
      decoration: BoxDecoration(
        color: mobile ? p.glass : Colors.transparent,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(mobile ? 30 : 14),
      ),
      child: mobile
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                attach,
                Expanded(child: input),
                send,
              ],
            )
          : Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: input,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    attach,
                    Expanded(
                      child: SiteText(
                        'Enter 发送 · Shift + Enter 换行',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 8, color: p.muted),
                      ),
                    ),
                    const SizedBox(width: 10),
                    send,
                  ],
                ),
              ],
            ),
    );
  }
}
