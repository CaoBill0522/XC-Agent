import 'dart:convert';

import 'package:dio/dio.dart';

/// 面向用户的请求错误。[message] 直接显示在界面上。
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.detail});

  final String message;
  final int? statusCode;

  /// 服务端返回的原始错误信息（截断），用于展开查看。
  final String? detail;

  bool get isNotFound => statusCode == 404 || statusCode == 405;

  @override
  String toString() => detail == null ? message : '$message\n$detail';

  factory ApiException.fromDio(DioException e) {
    final status = e.response?.statusCode;
    final detail = _extractDetail(e.response?.data);

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException('请求超时，请检查网络或地址');
      case DioExceptionType.connectionError:
        return ApiException('无法连接到服务器，请检查地址和网络', detail: e.message);
      case DioExceptionType.badCertificate:
        return ApiException('证书校验失败');
      case DioExceptionType.cancel:
        return ApiException('已取消');
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    final message = switch (status) {
      400 => '请求参数错误',
      401 => 'API Key 无效或未填写',
      402 => '账户余额不足',
      403 => '没有权限（Key 无权访问，或地区受限）',
      404 => '接口不存在，请检查地址或协议',
      405 => '接口不支持该请求方式',
      429 => '请求过于频繁或额度用尽',
      final s? when s >= 500 => '服务端错误（$s）',
      final s? => '请求失败（$s）',
      null => '请求失败',
    };
    return ApiException(
      message,
      statusCode: status,
      detail: detail ?? e.message,
    );
  }

  static String? _extractDetail(Object? data) {
    if (data == null) return null;
    Object? json = data;
    if (data is String) {
      try {
        json = jsonDecode(data);
      } catch (_) {
        return _truncate(data);
      }
    }
    // OpenAI: {error:{message}}；Anthropic: {error:{type,message}}；部分中转: {message}/{msg}
    if (json is Map) {
      final err = json['error'];
      if (err is Map && err['message'] is String) {
        return _truncate(err['message'] as String);
      }
      if (err is String) return _truncate(err);
      for (final k in ['message', 'msg', 'detail']) {
        if (json[k] is String) return _truncate(json[k] as String);
      }
    }
    return _truncate(jsonEncode(json));
  }

  static String _truncate(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
