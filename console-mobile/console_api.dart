import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ConsoleApiException implements Exception {
  ConsoleApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ConsoleLoginResult {
  const ConsoleLoginResult({this.token, this.secret, this.tfaType});

  final String? token;
  final String? secret;
  final String? tfaType;

  bool get needsCode => token == null && secret != null;
  bool get isTfa => tfaType == 'tfa_check';
}

class ConsolePeer {
  const ConsolePeer({
    required this.id,
    required this.online,
    required this.note,
    required this.deviceName,
    required this.os,
    required this.group,
  });

  final String id;
  final bool online;
  final String note;
  final String deviceName;
  final String os;
  final String group;

  String get title {
    if (note.trim().isNotEmpty) return note.trim();
    if (deviceName.trim().isNotEmpty) return deviceName.trim();
    return id;
  }

  String get subtitle {
    final parts = <String>['ID $id'];
    if (os.isNotEmpty) parts.add(os);
    if (group.isNotEmpty) parts.add(group);
    return parts.join(' · ');
  }

  factory ConsolePeer.fromJson(Map<String, dynamic> json) {
    final info = json['info'];
    final infoMap =
        info is Map ? Map<String, dynamic>.from(info) : <String, dynamic>{};
    final online = json['is_online'];
    return ConsolePeer(
      id: '${json['id'] ?? ''}',
      online: online == true || online == 1 || online == '1',
      note: '${json['note'] ?? ''}',
      deviceName: '${infoMap['device_name'] ?? ''}',
      os: '${infoMap['os'] ?? ''}',
      group: '${json['device_group_name'] ?? ''}',
    );
  }
}

class ConsoleApi {
  ConsoleApi(this.baseUrl, {this.token});

  final String baseUrl;
  final String? token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null && token!.isNotEmpty)
          'Authorization': 'Bearer $token',
      };

  Map<String, dynamic> get _deviceInfo => {
        'os': 'android',
        'type': 'client',
        'name': 'RustDesk Console Mobile',
      };

  Future<ConsoleLoginResult> login(String username, String password) async {
    final data = await _post('/api/login', {
      'username': username,
      'password': password,
      'autoLogin': true,
      'deviceInfo': _deviceInfo,
    });
    return _loginResult(data);
  }

  Future<ConsoleLoginResult> verify({
    required String username,
    required String secret,
    required String code,
    required bool tfa,
  }) async {
    final data = await _post('/api/login', {
      'username': username,
      'secret': secret,
      'type': tfa ? 'tfa_code' : 'email_code',
      if (tfa) 'tfaCode': code else 'verificationCode': code,
      'deviceInfo': _deviceInfo,
    });
    return _loginResult(data);
  }

  Future<List<ConsolePeer>> peers({
    String keyword = '',
    bool onlineOnly = false,
  }) async {
    final query = <String, String>{
      'current': '1',
      'pageSize': '100',
      if (keyword.trim().isNotEmpty) 'id': keyword.trim(),
      if (onlineOnly) 'is_online': '1',
    };
    final uri =
        Uri.parse('$baseUrl/api/peers').replace(queryParameters: query);
    final data = await _request(() => http.get(uri, headers: _headers));
    final rawList = data['data'];
    final peers = <ConsolePeer>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map) {
          peers.add(ConsolePeer.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return peers;
  }

  Future<Map<String, dynamic>> webClientConfig() async {
    return _request(() => http.get(
          Uri.parse('$baseUrl/api/web-client/config'),
          headers: _headers,
        ));
  }

  ConsoleLoginResult _loginResult(Map<String, dynamic> data) {
    final token = data['access_token'];
    final secret = data['secret'];
    final tfaType = data['tfa_type'];
    return ConsoleLoginResult(
      token: token is String && token.isNotEmpty ? token : null,
      secret: secret is String && secret.isNotEmpty ? secret : null,
      tfaType: tfaType is String ? tfaType : null,
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _request(() => http.post(
          Uri.parse('$baseUrl$path'),
          headers: _headers,
          body: jsonEncode(body),
        ));
  }

  Future<Map<String, dynamic>> _request(
    Future<http.Response> Function() action,
  ) async {
    http.Response response;
    try {
      response = await action().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw ConsoleApiException('连接超时，请检查服务器地址和网络');
    } catch (error) {
      throw ConsoleApiException('无法连接服务器：$error');
    }

    dynamic body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        body = null;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body is Map) return Map<String, dynamic>.from(body);
      return <String, dynamic>{};
    }
    throw ConsoleApiException(
      _errorMessage(body, response.statusCode),
      statusCode: response.statusCode,
    );
  }

  String _errorMessage(dynamic body, int status) {
    if (body is Map) {
      final message = body['message'] ?? body['error'];
      if (message is String && message.isNotEmpty) return message;
      if (message is List && message.isNotEmpty) {
        final first = message.first;
        if (first is String) return first;
        if (first is Map && first['message'] is String) {
          return first['message'] as String;
        }
      }
    }
    switch (status) {
      case 400:
        return '请求参数有误';
      case 401:
        return '用户名或密码错误，或登录已失效';
      case 403:
        return '当前账号没有访问权限';
      case 404:
        return '接口不存在，请确认服务器地址是否正确';
      default:
        return '请求失败（HTTP $status）';
    }
  }
}
