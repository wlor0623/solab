import 'package:flutter/services.dart';
import '../../../core/services/apk_channel_invoke.dart';

/// 结构操作通道的统一返回结果。
///
/// 原生侧可能以 {ok:false, error, message} 正常返回，也可能直接抛
/// [PlatformException]；本服务将两种情况统一解析为 [ApkStructuralResult]。
class ApkStructuralResult {
  const ApkStructuralResult({
    required this.ok,
    this.error,
    this.message,
    this.data,
  });

  final bool ok;

  /// 原生侧错误码（ok=false 时可能为空）。
  final String? error;

  /// 面向用户的错误/提示文案。
  final String? message;

  /// 原生返回的完整数据（ok=true 时包含 outputPath 等）。
  final Map<Object?, Object?>? data;

  String get displayMessage =>
      message ?? (ok ? '操作成功' : (error ?? '操作失败，请稍后重试'));
}

/// APK 结构操作通道封装：buildApk / deleteZipEntries / writeZipEntry。
///
/// 约定通道：MethodChannel('solab/workspace')，与 analyzeApk 共用。
class ApkStructuralService {
  const ApkStructuralService._();

  static const _channel = MethodChannel('solab/workspace');

  /// A3 只保留指定 ABI 重新构建。
  ///
  /// 入参 {path, keepAbis, outputName?, outputDir?}
  /// 返回 {ok, outputPath, filteredAbis, filteredEntries, savedBytes}
  ///
  /// M1: [sign]=true 时重打包后链式内置签名（apksig v1/v2/v3），
  /// 返回含 signedPath（可直接安装的签名包）。
  static Future<ApkStructuralResult> buildApk({
    required String path,
    required List<String> keepAbis,
    String? outputName,
    String? outputDir,
    bool dryRun = false,
    bool sign = false,
  }) {
    return _invoke('buildApk', {
      'path': path,
      'keepAbis': keepAbis,
      if (outputName != null && outputName.isNotEmpty) 'outputName': outputName,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
      'sign': sign,
    });
  }

  /// A1 按精确条目与目录前缀删除 ZIP 内容。
  ///
  /// 入参 {path, entries:[精确条目], prefixes:[目录前缀], outputDir?}
  /// 返回 {ok, outputPath, deleted:[{path,size}], savedBytes}
  static Future<ApkStructuralResult> deleteZipEntries({
    required String path,
    List<String> entries = const [],
    List<String> prefixes = const [],
    String? outputDir,
    bool dryRun = false,
  }) {
    return _invoke('deleteZipEntries', {
      'path': path,
      'entries': entries,
      'prefixes': prefixes,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
    });
  }

  /// A2 覆盖 / 新增 / 删除单个 ZIP 条目。
  ///
  /// 入参 {path, entries:[{locator, action, content:{hex|base64}}], outputDir?}
  /// 返回 {ok, outputPath, results:[{locator,action,beforeSha256,afterSha256,beforeSize,afterSize}]}
  static Future<ApkStructuralResult> writeZipEntry({
    required String path,
    required List<Map<String, Object?>> entries,
    String? outputDir,
    bool dryRun = false,
  }) {
    return _invoke('writeZipEntry', {
      'path': path,
      'entries': entries,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
    });
  }

  /// B1/B2/B3/B4/B5 + 检测规避 + 时间劫持：按用户确认的方法名修改 DEX，NOP 广告库加载。
  ///
  /// [trueMethods] 非空时，命中且返回 boolean/int 的会员/VIP 状态方法会被强制
  /// 返回 true（B3）；[removeVpnDetection]/[removeEmulatorDetection]/
  /// [removeRootDetection]/[removeDebugDetection] 为 true 时，方法名含对应
  /// 检测关键词且返回 boolean/int 的方法会被强制 false；[timeMethods] 非空时，
  /// 命中且返回 long 的到期/剩余时间方法会被强制远期 0xffffff；[sdkPackages]
  /// 非空时，原生会推导 so 加载关键词并 NOP 广告库 loadLibrary 调用（B5）。
  /// [classMethods] 为方法级定位目标（dex_search/class_outline/dex_xref 的
  /// qualifiedId，Lpkg/Class;->name 或 pkg.Class.methodName）：按真实定义精确
  /// 匹配，void 置空、boolean/int 强制 false、回调与不支持类型跳过并报告。
  static Future<ApkStructuralResult> patchDexMethods({
    required String path,
    List<String> voidMethods = const [],
    List<String> trueMethods = const [],
    List<String> falseMethods = const [],
    List<String> classMethods = const [],
    List<String> sdkPackages = const [],
    bool removeVpnDetection = false,
    bool removeEmulatorDetection = false,
    bool removeRootDetection = false,
    bool removeDebugDetection = false,
    List<String> timeMethods = const [],
    List<String> nullMethods = const [],
    bool shortenSplashCountdown = false,
    bool signatureBypass = true,
    String signatureBypassMode = 'normal',
    String? originalApkPath,
    bool stripDebugInfo = false,
    String? outputDir,
    bool dryRun = false,
  }) {
    return _invoke('patchDexMethods', {
      'path': path,
      'voidMethods': voidMethods,
      if (trueMethods.isNotEmpty) 'trueMethods': trueMethods,
      'falseMethods': falseMethods,
      if (classMethods.isNotEmpty) 'classMethods': classMethods,
      if (sdkPackages.isNotEmpty) 'sdkPackages': sdkPackages,
      if (removeVpnDetection) 'removeVpnDetection': true,
      if (removeEmulatorDetection) 'removeEmulatorDetection': true,
      if (removeRootDetection) 'removeRootDetection': true,
      if (removeDebugDetection) 'removeDebugDetection': true,
      if (timeMethods.isNotEmpty) 'timeMethods': timeMethods,
      if (nullMethods.isNotEmpty) 'nullMethods': nullMethods,
      if (shortenSplashCountdown) 'shortenSplashCountdown': true,
      'signatureBypass': signatureBypass,
      if (signatureBypass) 'signatureBypassMode': signatureBypassMode,
      if (originalApkPath != null && originalApkPath.isNotEmpty)
        'originalApkPath': originalApkPath,
      if (stripDebugInfo) 'stripDebugInfo': true,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
    });
  }

  /// B6/B7：二进制 AXML 编辑 Manifest，移除广告组件与权限。
  ///
  /// [auto] 为 true 时按规则库自动匹配广告组件与 ad_permissions，无需手填清单。
  /// [removeMetaData] 精确移除广告 SDK 的 meta-data 配置键（如 com.qq.e.comm.AppId），
  /// SDK 初始化拿不到配置即不加载广告，比删组件更安全。
  /// 返回 {ok, outputPath, removedComponents, removedPermissions, removedMetaData}
  static Future<ApkStructuralResult> patchManifest({
    required String path,
    List<String> removeComponents = const [],
    List<String> removePermissions = const [],
    List<String> removeMetaData = const [],
    bool auto = false,
    String? outputDir,
    bool dryRun = false,
  }) {
    return _invoke('patchManifest', {
      'path': path,
      if (removeComponents.isNotEmpty) 'removeComponents': removeComponents,
      if (removePermissions.isNotEmpty) 'removePermissions': removePermissions,
      if (removeMetaData.isNotEmpty) 'removeMetaData': removeMetaData,
      if (auto) 'auto': true,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
    });
  }

  /// B8：清理广告 assets 资源（先查 DEX 引用，被引用的不删）。
  ///
  /// 返回 {ok, outputPath, deleted, referenced, savedBytes}
  static Future<ApkStructuralResult> cleanAdAssets({
    required String path,
    String? outputDir,
    bool dryRun = false,
  }) {
    return _invoke('cleanAdAssets', {
      'path': path,
      if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      'dryRun': dryRun,
    });
  }

  /// 用户规则同步：规则库启用规则全量推给原生（原生存入私有 SP，
  /// 供 analyze/patch 与内置规则合并使用）。
  ///
  /// 入参 `rules`：`{key: List<String>}`（key 与原生契约一致）
  static Future<ApkStructuralResult> setUserRules(
    Map<String, List<String>> rules,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('setUserRules', {
        'rules': rules,
      });
      final data = raw is Map
          ? Map<Object?, Object?>.from(raw)
          : <Object?, Object?>{};
      return ApkStructuralResult(ok: data['ok'] == true, data: data);
    } catch (error) {
      return ApkStructuralResult(
        ok: false,
        error: 'exception',
        message: error.toString(),
      );
    }
  }

  /// 一键回滚：把源 APK（已签名原版）复制到输出目录，可直接安装恢复。
  ///
  /// 入参 {path, outputDir?}
  /// 返回 {ok, outputPath, message}
  static Future<ApkStructuralResult> restoreSourceApk({
    required String path,
    String? outputDir,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('restoreSourceApk', {
        'path': path,
        if (outputDir != null && outputDir.isNotEmpty) 'outputDir': outputDir,
      });
      final data = raw is Map
          ? Map<Object?, Object?>.from(raw)
          : <Object?, Object?>{};
      return ApkStructuralResult(
        ok: data['ok'] == true,
        error: data['error']?.toString(),
        message: data['message']?.toString(),
        data: data,
      );
    } on PlatformException catch (error) {
      return ApkStructuralResult(
        ok: false,
        error: error.code,
        message: error.message ?? '恢复原版失败（${error.code}）',
      );
    } catch (error) {
      return ApkStructuralResult(
        ok: false,
        error: 'exception',
        message: error.toString(),
      );
    }
  }

  /// 检查是否有写公共存储的权限（Android 11+ 需「所有文件访问」）。
  static Future<bool> checkStoragePermission() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'checkStoragePermission',
      );
      final data = raw is Map
          ? Map<Object?, Object?>.from(raw)
          : <Object?, Object?>{};
      return data['granted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统设置页，引导用户授予「所有文件访问」权限。
  static Future<bool> requestStoragePermission() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'requestStoragePermission',
      );
      final data = raw is Map
          ? Map<Object?, Object?>.from(raw)
          : <Object?, Object?>{};
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<ApkStructuralResult> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) {
    return invokeApkChannel(_channel, method, arguments);
  }
}
