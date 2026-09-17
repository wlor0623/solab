import 'package:flutter/services.dart';

import '../../features/solab_apk/services/apk_structural_service.dart'
    show ApkStructuralResult;

/// 共享的 APK 原生通道调用（复用：ApkStructuralService 与
/// ApkToolchainService 曾各自实现一份完全相同的 _invoke）。
///
/// 统一解析三种返回形态：
///  - 成功 {ok:true, ...}
///  - 业务错误 {ok:false, error:{code,message,...}, message}（结构化）
///  - 旧格式 {ok:false, error:"code", message}
///  - PlatformException（原生侧抛出的硬错误）
Future<ApkStructuralResult> invokeApkChannel(
  MethodChannel channel,
  String method,
  Map<String, Object?> arguments,
) async {
  try {
    final raw = await channel.invokeMethod<Object?>(method, arguments);
    final data = raw is Map
        ? Map<Object?, Object?>.from(raw)
        : <Object?, Object?>{};
    final rawError = data['error'];
    String? errorCode;
    String? errorMessage;
    if (rawError is Map) {
      errorCode = rawError['code']?.toString();
      errorMessage = rawError['message']?.toString();
    } else if (rawError != null) {
      errorCode = rawError.toString();
    }
    return ApkStructuralResult(
      ok: data['ok'] == true,
      error: errorCode,
      message: errorMessage ?? data['message']?.toString(),
      data: data,
    );
  } on PlatformException catch (error) {
    return ApkStructuralResult(
      ok: false,
      error: error.code,
      message: error.message ?? '调用 $method 失败（${error.code}）',
    );
  } catch (error) {
    return ApkStructuralResult(
      ok: false,
      error: 'exception',
      message: error.toString(),
    );
  }
}
