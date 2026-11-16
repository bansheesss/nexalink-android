import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/filetransfer.dart';
import '../session.dart';
import '../core/relay.dart';
import 'keyboard_bar.dart';
import 'nav.dart';
import 'remote_view.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage(
      {super.key, required this.host, required this.port, required this.password, this.relay});
  final String host;
  final int port;
  final String password;
  final RelaySettings? relay;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late RemoteSession _session;
  bool _keysOpen = false;
  bool _textOpen = false;
  bool _dialogShown = false;
  final Map<String, dynamic> _settings = {};

  @override
  void initState() {
    super.initState();
    _newSession();
  }

  void _newSession() {
    _dialogShown = false;
    _session = RemoteSession(FileServices(
      ask: _ask,
      notify: _toast,
      destDir: _destDir,
    ));
    _session.addListener(_onChange);
    _session.start(widget.host, widget.port, widget.password, relay: widget.relay);
  }

  Future<Directory> _destDir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    return Directory('${base.path}/NexaLink');
  }

  Future<bool> _ask(String title, String text) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return false;
    final r = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('خیر')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('بله')),
        ],
      ),
    );
    return r ?? false;
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));
  }

  void _onChange() {
    if (!mounted) return;
    final reason = _session.closedReason;
    if (reason != null && reason.isNotEmpty && !_dialogShown) {
      _dialogShown = true;
      _showClosed(reason);
    }
    setState(() {});
    // first SESSION_INFO of a (re)connected session: restore chosen settings
    if (_session.info != null && _settings.isNotEmpty && !_restored) {
      _restored = true;
      _session.requestSettings({..._settings, 'keyframe': true});
    }
  }

  bool _restored = false;

  Future<void> _showClosed(String reason) async {
    final again = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('ارتباط قطع شد'),
        content: Text(reason),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('بستن')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('اتصال مجدد')),
        ],
      ),
    );
    if (!mounted) return;
    if (again == true) {
      final old = _session;
      old.removeListener(_onChange);
      _restored = false;
      setState(_newSession);
      old.dispose();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    _session.close();
    _session.dispose();
    super.dispose();
  }

  Future<void> _sendFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) {
      final p = f.path;
      if (p != null) await _session.sendFile(p);
    }
  }

  void _setting(String key, dynamic value) {
    _settings[key] = value;
    _session.requestSettings({key: value, 'keyframe': true});
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final monitors =
            (_session.info?['monitors'] as List?)?.cast<Map<String, dynamic>>() ??
                const [];
        final curMon = _session.info?['monitor'];
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('کیفیت تصویر: ${(_settings['quality'] ?? 60)}'),
              Slider(
                min: 10, max: 95, divisions: 17,
                value: ((_settings['quality'] ?? 60) as num).toDouble(),
                onChanged: (v) => setSheet(() => _settings['quality'] = v.round()),
                onChangeEnd: (v) => _setting('quality', v.round()),
              ),
              Text('فریم بر ثانیه: ${(_settings['fps'] ?? 20)}'),
              Slider(
                min: 5, max: 30, divisions: 25,
                value: ((_settings['fps'] ?? 20) as num).toDouble(),
                onChanged: (v) => setSheet(() => _settings['fps'] = v.round()),
                onChangeEnd: (v) => _setting('fps', v.round()),
              ),
              Text('مقیاس تصویر: ${(((_settings['scale'] ?? 1.0) as num) * 100).round()}٪'),
              Slider(
                min: 0.25, max: 1.0, divisions: 15,
                value: ((_settings['scale'] ?? 1.0) as num).toDouble(),
                onChanged: (v) => setSheet(() => _settings['scale'] = double.parse(v.toStringAsFixed(2))),
                onChangeEnd: (v) => _setting('scale', double.parse(v.toStringAsFixed(2))),
              ),
              if (monitors.length > 1) ...[
                const Text('مانیتور'),
                Wrap(spacing: 8, children: [
                  for (final m in monitors)
                    ChoiceChip(
                      label: Text(m['index'] == 0
                          ? 'همه'
                          : '${m['index']} (${m['width']}×${m['height']})'),
                      selected: m['index'] == curMon,
                      onSelected: (_) {
                        _session.requestSettings({'monitor': m['index']});
                        Navigator.pop(ctx);
                      },
                    ),
                ]),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('همگام‌سازی کلیپ‌بورد'),
                value: _session.clipboardSync,
                onChanged: (v) => setSheet(() => _session.clipboardSync = v),
              ),
            ],
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ping = _session.pingMs;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(
          _session.info == null
              ? _session.status
              : '${_session.info!['name'] ?? widget.host}  •  ${_session.fps} fps'
                  '${ping != null ? '  •  ${ping.round()} ms' : ''}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'صفحه‌کلید',
            icon: const Icon(Icons.keyboard),
            onPressed: () => setState(() {
              _textOpen = !_textOpen;
              if (_textOpen) _keysOpen = true;
            }),
          ),
          IconButton(
            tooltip: 'کلیدهای ویژه',
            icon: const Icon(Icons.keyboard_alt_outlined),
            onPressed: () => setState(() {
              _keysOpen = !_keysOpen;
              if (!_keysOpen) _textOpen = false;
            }),
          ),
          IconButton(
            tooltip: 'ارسال فایل',
            icon: const Icon(Icons.upload_file),
            onPressed: _session.connected ? _sendFiles : null,
          ),
          IconButton(
            tooltip: 'تنظیمات',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: RemoteView(session: _session),
            ),
          ),
          if (_keysOpen) KeyboardBar(session: _session, showText: _textOpen),
        ]),
      ),
    );
  }
}
