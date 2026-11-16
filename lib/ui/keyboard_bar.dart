import 'package:flutter/material.dart';

import '../session.dart';

/// Soft-keyboard typing + special keys with one-shot modifiers.
class KeyboardBar extends StatefulWidget {
  const KeyboardBar({super.key, required this.session, required this.showText});
  final RemoteSession session;
  final bool showText;

  @override
  State<KeyboardBar> createState() => _KeyboardBarState();
}

class _KeyboardBarState extends State<KeyboardBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final Set<String> _mods = {};
  String _prev = '';

  static const _keys = <(String, String)>[
    ('Esc', 'esc'), ('Tab', 'tab'), ('Enter', 'enter'), ('⌫', 'backspace'),
    ('Del', 'delete'), ('←', 'left'), ('↑', 'up'), ('↓', 'down'),
    ('→', 'right'), ('Home', 'home'), ('End', 'end'), ('PgUp', 'page_up'),
    ('PgDn', 'page_down'), ('Space', 'space'),
    ('F1', 'f1'), ('F2', 'f2'), ('F3', 'f3'), ('F4', 'f4'), ('F5', 'f5'),
    ('F6', 'f6'), ('F7', 'f7'), ('F8', 'f8'), ('F9', 'f9'), ('F10', 'f10'),
    ('F11', 'f11'), ('F12', 'f12'),
  ];

  @override
  void didUpdateWidget(KeyboardBar old) {
    super.didUpdateWidget(old);
    if (widget.showText && !old.showText) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _press(String name) {
    widget.session.typeKey(name, mods: Set.of(_mods));
    if (_mods.isNotEmpty) setState(_mods.clear); // one-shot modifiers
  }

  void _onChanged(String v) {
    if (v.length > _prev.length && v.startsWith(_prev)) {
      for (final r in v.substring(_prev.length).runes) {
        _press(String.fromCharCode(r));
      }
    } else if (v.length < _prev.length && _prev.startsWith(v)) {
      for (var i = 0; i < _prev.length - v.length; i++) {
        _press('backspace');
      }
    } else {
      // replaced text (autocorrect): erase the old, type the new
      for (var i = 0; i < _prev.length; i++) {
        _press('backspace');
      }
      for (final r in v.runes) {
        _press(String.fromCharCode(r));
      }
    }
    _prev = v;
    if (v.length > 40) {
      _ctrl.clear();
      _prev = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showText)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: _onChanged,
                onSubmitted: (_) {
                  _press('enter');
                  _focus.requestFocus();
                },
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'تایپ کنید؛ مستقیم به کامپیوتر ارسال می‌شود',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final (label, mod) in const [
                  ('Ctrl', 'ctrl'), ('Alt', 'alt'), ('Shift', 'shift'), ('Win', 'cmd'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                    child: FilterChip(
                      label: Text(label),
                      selected: _mods.contains(mod),
                      onSelected: (on) => setState(
                          () => on ? _mods.add(mod) : _mods.remove(mod)),
                    ),
                  ),
                for (final (label, name) in _keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                    child: ActionChip(
                      label: Text(label),
                      onPressed: () => _press(name),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
