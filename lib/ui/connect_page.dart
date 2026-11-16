import 'dart:io';

import 'package:flutter/material.dart';

import '../core/discovery.dart';
import '../core/relay.dart';
import 'viewer_page.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '7070');
  final _password = TextEditingController();
  final _relayHost = TextEditingController();
  final _relayPort = TextEditingController(text: '7072');
  final _relayToken = TextEditingController();
  bool _relayTls = false;
  bool _busy = false;
  bool _checkingStatus = false;
  bool _internetAvailable = false;
  bool _lanHostFound = false;
  String _statusText = 'در حال بررسی اتصال…';

  static final _idRe = RegExp(r'^\d{3}\s?\d{3}\s?\d{3}$');

  @override
  void initState() {
    super.initState();
    _refreshNetworkStatus();
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _password.dispose();
    _relayHost.dispose();
    _relayPort.dispose();
    _relayToken.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _refreshNetworkStatus() async {
    if (_checkingStatus) return;
    setState(() {
      _checkingStatus = true;
      _statusText = 'در حال بررسی اینترنت و شبکه محلی…';
    });

    var internet = false;
    var lan = false;

    // Socket connectivity is more reliable than ICMP ping on mobile networks.
    // This uses Android's normal INTERNET permission; no runtime prompt is needed.
    try {
      final socket = await Socket.connect('google.com', 443,
          timeout: const Duration(seconds: 3));
      internet = true;
      socket.destroy();
    } catch (_) {
      internet = false;
    }

    try {
      lan = (await discover(timeout: const Duration(milliseconds: 1100))).isNotEmpty;
    } catch (_) {
      lan = false;
    }

    if (!mounted) return;
    setState(() {
      _internetAvailable = internet;
      _lanHostFound = lan;
      _checkingStatus = false;
      _statusText = lan
          ? 'کامپیوتر NexaLink در شبکه محلی پیدا شد'
          : internet
              ? 'اینترنت برقرار است؛ کامپیوتر محلی پیدا نشد'
              : 'اینترنت و کامپیوتر محلی در دسترس نیستند';
    });
  }

  Color get _statusColor => _lanHostFound
      ? Colors.orange
      : _internetAvailable
          ? Colors.green
          : Colors.red;

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'NexaLink',
      applicationVersion: '1.2.0',
      applicationLegalese: 'نویسنده: Banshee',
      children: const [Text('کنترل امن کامپیوتر از طریق شبکه محلی و سرور ریلی.')],
    );
  }

  Future<void> _scan() async {
    setState(() => _busy = true);
    final hosts = await discover();
    if (!mounted) return;
    setState(() => _busy = false);
    if (hosts.isEmpty) {
      _snack('میزبانی در این شبکه پیدا نشد');
      return;
    }
    final picked = await showModalBottomSheet<HostInfo>(
      context: context,
      builder: (ctx) => ListView(
        children: [
          for (final h in hosts)
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(h.name.isEmpty ? h.id : h.name),
              subtitle: Text('${h.id}  •  ${h.host}:${h.port}',
                  textDirection: TextDirection.ltr),
              onTap: () => Navigator.pop(ctx, h),
            ),
        ],
      ),
    );
    if (picked != null) {
      _host.text = picked.host;
      _port.text = '${picked.port}';
    }
  }

  Future<void> _connect() async {
    var host = _host.text.trim();
    var port = int.tryParse(_port.text.trim()) ?? 7070;
    final pw = _password.text;
    if (host.isEmpty || pw.isEmpty) {
      _snack('آدرس و رمز عبور را وارد کنید');
      return;
    }

    RelaySettings? relay;
    if (_idRe.hasMatch(host)) {
      final id = host.replaceAll(RegExp(r'\s'), '');
      setState(() => _busy = true);
      final found = await discover(machineId: id);
      if (!mounted) return;
      setState(() => _busy = false);
      if (found.isNotEmpty) {
        host = found.first.host;
        port = found.first.port;
      } else {
        final relayServer = _relayHost.text.trim();
        final relayPort = int.tryParse(_relayPort.text.trim()) ?? 7072;
        if (relayServer.isEmpty) {
          _snack('این شناسه در شبکه محلی پیدا نشد؛ برای اتصال اینترنتی، سرور ریلی را تنظیم کنید.');
          return;
        }
        relay = RelaySettings(
          server: relayServer,
          port: relayPort,
          token: _relayToken.text,
          tls: _relayTls,
        );
        host = id;
      }
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(
        host: host,
        port: port,
        password: pw,
        relay: relay,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NexaLink'),
        actions: [
          IconButton(
            tooltip: 'بررسی دوباره وضعیت شبکه',
            onPressed: _checkingStatus ? null : _refreshNetworkStatus,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'درباره برنامه',
            onPressed: _showAbout,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('اتصال به کامپیوتر',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: _checkingStatus ? Colors.grey : _statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_statusText)),
                  if (_checkingStatus)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'آدرس IP یا شناسه‌ی ۹ رقمی',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'پورت', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            textDirection: TextDirection.ltr,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'رمز عبور', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('تنظیم اتصال اینترنتی (Relay)'),
            subtitle: const Text('برای اتصال از بیرون شبکه؛ در صورت خالی بودن فقط LAN فعال است.'),
            children: [
              TextField(
                controller: _relayHost,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'آدرس سرور ریلی',
                  hintText: 'relay.example.com',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _relayPort,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'پورت ریلی', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _relayToken,
                textDirection: TextDirection.ltr,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'توکن ریلی (در صورت نیاز)',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('استفاده از TLS'),
                value: _relayTls,
                onChanged: (v) => setState(() => _relayTls = v),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.wifi_find),
                label: const Text('جستجو در شبکه'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: const Icon(Icons.link),
                label: const Text('اتصال'),
              ),
            ),
          ]),
          if (_busy) const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
          const SizedBox(height: 24),
          const Text(
            'اتصال با IP یا شناسه در شبکه محلی امکان‌پذیر است. برای شناسه‌های خارج از شبکه، '
            'سرور Relay را وارد کنید؛ میزبان ویندوز نیز باید به همان سرور متصل باشد.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
