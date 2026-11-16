import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import 'console_api.dart';
import 'home_page.dart';

class ConsoleServer {
  const ConsoleServer(this.name, this.url);

  final String name;
  final String url;

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  static ConsoleServer? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    final name = raw['name'];
    return ConsoleServer(name is String ? name : '', url);
  }
}

class ConsolePage extends StatefulWidget implements PageShape {
  ConsolePage({Key? key}) : super(key: key);

  @override
  final String title = '控制台';

  @override
  final Widget icon = const Icon(Icons.dns_outlined);

  @override
  final List<Widget> appBarActions = const [];

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final _search = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  List<ConsoleServer> _servers = [];
  ConsoleServer? _server;
  String? _token;
  List<ConsolePeer> _peers = [];
  bool _loading = true;
  bool _busy = false;
  bool _loadingPeers = false;
  bool _onlineOnly = false;
  String _keyword = '';
  String? _error;
  String? _secret;
  String? _challengeType;
  String? _appliedServer;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _search.dispose();
    _username.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _restore() {
    _servers = _loadServers();
    _server = _servers.isEmpty ? null : _servers.first;
    _token = _server == null ? null : _readToken(_server!.url);
    _loading = false;
    if (_token != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPeers());
    }
  }

  List<ConsoleServer> _loadServers() {
    final raw = bind.mainGetLocalOption(key: 'console_servers');
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map(ConsoleServer.fromJson)
            .whereType<ConsoleServer>()
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveServers() async {
    await bind.mainSetLocalOption(
      key: 'console_servers',
      value: jsonEncode(_servers.map((server) => server.toJson()).toList()),
    );
  }

  String _tokenKey(String url) =>
      'console_token_${url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}';

  String? _readToken(String url) {
    final value = bind.mainGetLocalOption(key: _tokenKey(url));
    return value.isEmpty ? null : value;
  }

  Future<void> _writeToken(String url, String token) async {
    await bind.mainSetLocalOption(key: _tokenKey(url), value: token);
  }

  Future<void> _clearToken(String url) async {
    await bind.mainSetLocalOption(key: _tokenKey(url), value: '');
  }

  String _normalizeUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || uri.path.isNotEmpty) return '';
    return value;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _addServer() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final created = await showDialog<ConsoleServer>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加 Console 服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称（可选）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://rdc.example.com',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = _normalizeUrl(urlController.text);
              if (url.isEmpty) return;
              Navigator.pop(ctx, ConsoleServer(nameController.text.trim(), url));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    urlController.dispose();
    if (created == null || !mounted) return;

    final existing = _servers.where((server) => server.url == created.url);
    final target = existing.isNotEmpty ? existing.first : created;
    if (existing.isEmpty) {
      setState(() => _servers = [..._servers, created]);
      await _saveServers();
    }
    if (!mounted) return;
    setState(() {
      _server = target;
      _token = _readToken(target.url);
      _peers = [];
      _error = null;
      _secret = null;
      _challengeType = null;
      _appliedServer = null;
    });
    if (_token != null) {
      await _loadPeers();
    }
  }

  void _onServerChanged(ConsoleServer? value) {
    if (value == null || value.url == _server?.url) return;
    setState(() {
      _server = value;
      _token = _readToken(value.url);
      _peers = [];
      _error = null;
      _secret = null;
      _challengeType = null;
      _appliedServer = null;
    });
    if (_token != null) {
      _loadPeers();
    }
  }

  Future<void> _logout() async {
    final server = _server;
    if (server == null) return;
    await _clearToken(server.url);
    if (!mounted) return;
    setState(() {
      _token = null;
      _peers = [];
      _secret = null;
      _challengeType = null;
      _appliedServer = null;
    });
  }

  Future<void> _submitLogin() async {
    final server = _server;
    if (server == null || _busy) return;
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = '请输入用户名');
      return;
    }
    if (_secret == null && _password.text.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    if (_secret != null && _code.text.trim().isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ConsoleApi(server.url);
      final result = _secret == null
          ? await api.login(username, _password.text)
          : await api.verify(
              username: username,
              secret: _secret!,
              code: _code.text.trim(),
              tfa: _challengeType == 'tfa_check',
            );
      if (!mounted) return;
      if (result.token == null) {
        if (result.secret == null) {
          setState(() => _error = '服务器返回了无法识别的登录响应');
          return;
        }
        setState(() {
          _secret = result.secret;
          _challengeType = result.tfaType ?? 'email_check';
          _code.clear();
        });
        return;
      }
      await _writeToken(server.url, result.token!);
      if (!mounted) return;
      setState(() {
        _token = result.token;
        _secret = null;
        _challengeType = null;
        _appliedServer = null;
      });
      await _loadPeers();
    } on ConsoleApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '登录失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Point the RustDesk core at this console's ID/relay server before a
  /// native session starts, so tapping a device connects like a custom client.
  Future<String?> _applyServerConfig() async {
    final server = _server;
    final token = _token;
    if (server == null || token == null) return null;
    if (_appliedServer == server.url) return null;

    try {
      final config =
          await ConsoleApi(server.url, token: token).webClientConfig();
      final idHost = Uri.tryParse('${config['idServerUrl'] ?? ''}')?.host ?? '';
      final relayHost =
          Uri.tryParse('${config['relayServerUrl'] ?? ''}')?.host ?? '';
      final key = '${config['serverPublicKey'] ?? ''}';
      if (idHost.isNotEmpty) {
        await bind.mainSetOption(
            key: 'custom-rendezvous-server', value: idHost);
      }
      if (relayHost.isNotEmpty) {
        await bind.mainSetOption(key: 'relay-server', value: relayHost);
      }
      if (key.isNotEmpty) {
        await bind.mainSetOption(key: 'key', value: key);
      }
      await bind.mainSetOption(key: 'api-server', value: server.url);
      _appliedServer = server.url;
      return null;
    } catch (_) {
      final host = Uri.tryParse(server.url)?.host ?? '';
      if (host.isNotEmpty) {
        try {
          await bind.mainSetOption(
              key: 'custom-rendezvous-server', value: host);
          await bind.mainSetOption(key: 'relay-server', value: host);
          await bind.mainSetOption(key: 'api-server', value: server.url);
        } catch (_) {}
      }
      _appliedServer = server.url;
      return '未获取到服务器公钥，请确认 Console 已启用网页客户端；否则可能无法连接';
    }
  }

  Future<void> _loadPeers() async {
    final server = _server;
    final token = _token;
    if (server == null || token == null) return;
    setState(() {
      _loadingPeers = true;
      _error = null;
    });
    final warning = await _applyServerConfig();
    if (warning != null) _snack(warning);
    try {
      final peers = await ConsoleApi(server.url, token: token).peers(
        keyword: _keyword,
        onlineOnly: _onlineOnly,
      );
      if (!mounted) return;
      setState(() {
        _peers = peers;
        _loadingPeers = false;
      });
    } on ConsoleApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await _clearToken(server.url);
        if (!mounted) return;
        setState(() {
          _token = null;
          _peers = [];
          _loadingPeers = false;
        });
        _snack('登录已过期，请重新登录');
        return;
      }
      setState(() {
        _error = error.message;
        _loadingPeers = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '加载设备失败：$error';
        _loadingPeers = false;
      });
    }
  }

  Future<void> _openPeer(ConsolePeer peer) async {
    if (!peer.online) {
      _snack('设备当前离线');
      return;
    }
    final warning = await _applyServerConfig();
    if (warning != null) _snack(warning);
    if (!mounted) return;
    await connect(context, peer.id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SafeArea(
      child: Column(
        children: [
          _buildServerBar(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildServerBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: _servers.isEmpty
                ? const Text('未添加服务器',
                    style: TextStyle(color: Colors.grey))
                : DropdownButtonHideUnderline(
                    child: DropdownButton<ConsoleServer>(
                      isExpanded: true,
                      value: _server,
                      items: _servers
                          .map((server) => DropdownMenuItem(
                                value: server,
                                child: Text(
                                  server.displayName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: _busy ? null : _onServerChanged,
                    ),
                  ),
          ),
          IconButton(
            tooltip: '添加服务器',
            onPressed: _addServer,
            icon: const Icon(Icons.add),
          ),
          if (_token != null) ...[
            IconButton(
              tooltip: '刷新',
              onPressed: _loadingPeers ? null : _loadPeers,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '退出登录',
              onPressed: _logout,
              icon: const Icon(Icons.logout),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_server == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 52, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('添加你的 Console 服务器'),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '登录后可在这里直接查看设备并发起原生远控',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('添加服务器'),
            ),
          ],
        ),
      );
    }
    if (_token == null) {
      return _buildLogin(context);
    }
    return _buildDevices(context);
  }

  Widget _buildLogin(BuildContext context) {
    final needsCode = _secret != null;
    final codeLabel =
        _challengeType == 'tfa_check' ? '两步验证码' : '邮箱验证码';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '登录 ${_server!.displayName}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          _server!.url,
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _username,
          enabled: !_busy && !needsCode,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '用户名 / 邮箱',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 10),
        if (!needsCode)
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            onSubmitted: (_) => _submitLogin(),
          )
        else
          TextField(
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: codeLabel,
              helperText: _challengeType == 'tfa_check'
                  ? '请输入身份验证器中的验证码'
                  : '验证码已发送到账号邮箱',
              prefixIcon: const Icon(Icons.verified_user_outlined),
            ),
            onSubmitted: (_) => _submitLogin(),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _busy ? null : _submitLogin,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(needsCode ? '验证并登录' : '登录'),
        ),
        if (needsCode)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _secret = null;
                      _challengeType = null;
                      _code.clear();
                      _error = null;
                    }),
            child: const Text('返回重新输入账号'),
          ),
      ],
    );
  }

  Widget _buildDevices(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索设备 ID',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              _keyword = '';
                              setState(() {});
                              _loadPeers();
                            },
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (value) {
                    _keyword = value.trim();
                    _loadPeers();
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('仅在线'),
                selected: _onlineOnly,
                onSelected: (value) {
                  setState(() => _onlineOnly = value);
                  _loadPeers();
                },
              ),
            ],
          ),
        ),
        if (_loadingPeers) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadPeers,
            child: _buildPeerList(context),
          ),
        ),
      ],
    );
  }

  Widget _buildPeerList(BuildContext context) {
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.cloud_off, size: 44, color: Colors.grey),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: _loadPeers,
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }
    if (_peers.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Icon(Icons.devices_other, size: 44, color: Colors.grey),
          SizedBox(height: 10),
          Center(
            child: Text(
              '没有找到设备',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: _peers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final peer = _peers[index];
        return ListTile(
          onTap: () => _openPeer(peer),
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                backgroundColor:
                    Theme.of(context).colorScheme.secondaryContainer,
                child: Icon(_iconForOs(peer.os),
                    color: Theme.of(context).colorScheme.onSecondaryContainer),
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        peer.online ? const Color(0xFF3DDC84) : Colors.grey,
                    border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          title: Text(
            peer.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            peer.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: peer.online
              ? const Icon(Icons.chevron_right)
              : const Text('离线', style: TextStyle(fontSize: 12)),
        );
      },
    );
  }

  IconData _iconForOs(String os) {
    final value = os.toLowerCase();
    if (value.contains('android') || value.contains('ios')) {
      return Icons.smartphone;
    }
    if (value.contains('mac')) return Icons.laptop_mac;
    if (value.contains('linux')) return Icons.laptop;
    return Icons.desktop_windows;
  }
}
