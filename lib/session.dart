// Viewer session controller: connection, frames, input, clipboard, files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'core/errors.dart';
import 'core/filetransfer.dart';
import 'core/network.dart';
import 'core/protocol.dart';
import 'core/relay.dart';

class RemoteSession extends ChangeNotifier {
  RemoteSession(this.fileServices);

  final FileServices fileServices;
  final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);

  String status = '';
  /// null while running; set once when the session ended ('' = we closed it).
  String? closedReason;
  Map<String, dynamic>? info;
  double? pingMs;
  int fps = 0;
  bool clipboardSync = true;

  Connection? _conn;
  FileTransfer? _files;
  bool _userClosed = false;
  bool _disposed = false;
  Timer? _ticker;
  Timer? _pingTimer;
  Timer? _clipTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _frameCount = 0;
  String _lastClip = '';
  Uint8List? _pendingFrame;
  bool _decoding = false;
  int _lastMoveMs = -1000;

  bool get connected => _conn?.cipher != null;

  void _setStatus(String s) {
    status = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(String host, int port, String password,
          {RelaySettings? relay}) =>
      _run(host, port, password, relay: relay);

  Future<void> _run(String host, int port, String password,
      {RelaySettings? relay}) async {
    var reason = 'ارتباط قطع شد';
    Connection? conn;
    try {
      if (relay != null && relay.enabled) {
        _setStatus('اتصال به شناسه $host از طریق سرور ریلی...');
        conn = await connectViaRelay(relay, host,
            timeout: const Duration(seconds: 20));
      } else {
        _setStatus('اتصال به $host:$port ...');
        final sock = await Socket.connect(host, port,
            timeout: const Duration(seconds: 5));
        sock.setOption(SocketOption.tcpNoDelay, true);
        conn = Connection.fromSocket(sock);
      }
      _conn = conn;
      _setStatus('احراز هویت (چند ثانیه طول می‌کشد)...');
      await clientHandshake(conn, password)
          .timeout(const Duration(seconds: 40));
      _setStatus('منتظر پاسخ میزبان...');
      _files = FileTransfer(conn, fileServices, 1);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        fps = _frameCount;
        _frameCount = 0;
        _notify();
      });
      _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final b = ByteData(8)..setFloat64(0, _clock.elapsedMicroseconds / 1e6);
        _send(MsgType.ping, b.buffer.asUint8List());
      });
      try {
        _lastClip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      } catch (_) {}
      _clipTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _pollClipboard());

      var gotInfo = false;
      loop:
      while (true) {
        final m = await conn
            .recv()
            .timeout(Duration(seconds: gotInfo ? 15 : 45));
        switch (m.type) {
          case MsgType.frame:
            _onFrame(FrameMsg.unpack(m.body));
            break;
          case MsgType.sessionInfo:
            gotInfo = true;
            info = unpackJson(m.body);
            _setStatus('متصل');
            break;
          case MsgType.ping:
            _send(MsgType.pong, m.body);
            break;
          case MsgType.pong:
            if (m.body.length >= 8) {
              final t0 = ByteData.sublistView(m.body).getFloat64(0);
              pingMs = (_clock.elapsedMicroseconds / 1e6 - t0) * 1000;
            }
            break;
          case MsgType.clipboard:
            _onRemoteClipboard(m.body);
            break;
          case MsgType.error:
            reason = (unpackJson(m.body)['reason'] ?? 'خطای میزبان').toString();
            break loop;
          case MsgType.bye:
            break loop;
          default:
            if (MsgType.isFile(m.type)) await _files!.handle(m.type, m.body);
        }
      }
    } on AuthError {
      reason = 'احراز هویت ناموفق بود (رمز عبور اشتباه است؟)';
    } on TimeoutException {
      reason = 'زمان اتصال تمام شد';
    } on SocketException catch (e) {
      reason = 'اتصال برقرار نشد: ${e.message}';
    } on ConnectionClosed {
      reason = 'ارتباط قطع شد';
    } on ProtocolError {
      reason = 'خطای پروتکل (نسخه‌ی میزبان سازگار نیست؟)';
    } catch (e) {
      reason = 'خطا: $e';
    } finally {
      _ticker?.cancel();
      _pingTimer?.cancel();
      _clipTimer?.cancel();
      _files?.close();
      await conn?.close();
      _conn = null;
      closedReason = _userClosed ? '' : reason;
      _notify();
    }
  }

  // ---------------------------------------------------------------- frames
  void _onFrame(FrameMsg f) {
    _pendingFrame = f.data; // latest wins: drop frames while decoding
    if (!_decoding) _decodeLoop();
  }

  Future<void> _decodeLoop() async {
    _decoding = true;
    while (_pendingFrame != null && !_disposed) {
      final bytes = _pendingFrame!;
      _pendingFrame = null;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final fi = await codec.getNextFrame();
        codec.dispose();
        final old = image.value;
        image.value = fi.image;
        _frameCount++;
        if (old != null) {
          // dispose only after the new frame has been painted
          WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
        }
      } catch (_) {
        // corrupt frame: skip
      }
    }
    _decoding = false;
  }

  // ----------------------------------------------------------------- input
  void _send(int type, Uint8List body) {
    final c = _conn;
    if (c == null || c.cipher == null) return;
    c.send(type, body).catchError((Object _) {});
  }

  void sendMouseMove(double nx, double ny, {bool force = false}) {
    final now = _clock.elapsedMilliseconds;
    if (!force && now - _lastMoveMs < 11) return; // ~90 Hz cap
    _lastMoveMs = now;
    _send(MsgType.mouseMove, packMouseMove(nx, ny));
  }

  void sendMouseButton(int button, bool pressed) =>
      _send(MsgType.mouseButton, packMouseButton(button, pressed));

  void sendScroll(int dx, int dy) =>
      _send(MsgType.mouseScroll, packScroll(dx, dy));

  void sendKey(String name, bool pressed) =>
      _send(MsgType.key, packKey(name, pressed));

  /// Press + release [name], wrapped in [mods] (ctrl/alt/shift/cmd).
  void typeKey(String name, {Set<String> mods = const {}}) {
    for (final m in mods) {
      sendKey(m, true);
    }
    sendKey(name, true);
    sendKey(name, false);
    for (final m in mods.toList().reversed) {
      sendKey(m, false);
    }
  }

  void requestSettings(Map<String, dynamic> settings) =>
      _send(MsgType.frameRequest, packJson(settings));

  Future<bool> sendFile(String path) async =>
      await (_files?.sendFile(path) ?? Future<bool>.value(false));

  // ------------------------------------------------------------- clipboard
  Future<void> _pollClipboard() async {
    if (!clipboardSync || !connected) return;
    try {
      final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (t == null || t.isEmpty || t == _lastClip) return;
      final bytes = utf8.encode(t);
      if (bytes.length > (1 << 20)) return;
      _lastClip = t;
      _send(MsgType.clipboard, Uint8List.fromList(bytes));
    } catch (_) {}
  }

  void _onRemoteClipboard(Uint8List body) {
    if (!clipboardSync || body.length > (1 << 20)) return;
    try {
      final t = utf8.decode(body);
      _lastClip = t; // stops the echo
      Clipboard.setData(ClipboardData(text: t));
    } catch (_) {}
  }

  // --------------------------------------------------------------- closing
  Future<void> close() async {
    _userClosed = true;
    final c = _conn;
    if (c != null && c.cipher != null) {
      try {
        await c.send(MsgType.bye, Uint8List(0));
      } catch (_) {}
    }
    await c?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _pingTimer?.cancel();
    _clipTimer?.cancel();
    image.value?.dispose();
    image.value = null;
    super.dispose();
  }
}
