import 'package:flutter/services.dart';
import '../../../core/services/apk_channel_invoke.dart';
import 'apk_structural_service.dart';

/// 静态分析/SO 引擎工具链的 MethodChannel 封装。
///
/// 对应 Kotlin 侧 SolabChannel 的当前工具入口。
///
/// 信封契约：{ok:true,...} / {ok:false, error:{code,message}, message}；
/// 错误解析复用 [ApkStructuralResult]（含结构化 error 解析）。
class ApkToolchainService {
  const ApkToolchainService._();

  static const _channel = MethodChannel('solab/workspace');

  static Future<ApkStructuralResult> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) {
    return invokeApkChannel(_channel, method, arguments);
  }

  /// 签名校验点扫描（DPatch 去签前的风险判定）。
  static Future<ApkStructuralResult> scanSignatureCheck({
    required String path,
  }) {
    return _invoke('scanSignatureCheck', {'path': path});
  }

  /// A1: jadx DEX→Java 反编译。action ∈ {save, class, list}。
  static Future<ApkStructuralResult> jadxDecompile({
    required String path,
    String action = 'save',
    String? className,
    String? dexName,
    int? limit,
    int? offset,
    String? workDir,
  }) {
    return _invoke('jadxDecompile', {
      'path': path,
      'action': action,
      if (className != null && className.isNotEmpty) 'className': className,
      if (dexName != null && dexName.isNotEmpty) 'dexName': dexName,
      if (limit != null) 'limit': limit,
      if (offset != null) 'offset': offset,
      if (workDir != null && workDir.isNotEmpty) 'workDir': workDir,
    });
  }

  /// A4: APK v1/v2/v3 签名（内置自签名密钥，首次自动生成）。
  static Future<ApkStructuralResult> apkSign({
    required String inputApk,
    String? outputApk,
    int? minSdk,
  }) {
    return _invoke('apkSign', {
      'inputApk': inputApk,
      if (outputApk != null && outputApk.isNotEmpty) 'outputApk': outputApk,
      if (minSdk != null) 'minSdk': minSdk,
    });
  }

  /// T1: 列出 APK 内 `lib/<abi>/*.so` 条目（so_patch_into_apk 自动定位回填目标）。
  static Future<ApkStructuralResult> listLibEntries({required String path}) {
    return _invoke('listLibEntries', {'path': path});
  }

  /// A6: APKEditor 完整回编/合并/去混淆。action ∈ {decode, build, merge, refactor}。
  static Future<ApkStructuralResult> apkRebuild({
    required String path,
    String action = 'decode',
    String? output,
    String? type,
    bool? dex,
    bool? force,
    bool? cleanMeta,
    bool? fixTypeNames,
    String? workDir,
  }) {
    return _invoke('apkRebuild', {
      'path': path,
      'action': action,
      if (output != null && output.isNotEmpty) 'output': output,
      if (type != null && type.isNotEmpty) 'type': type,
      if (dex != null) 'dex': dex,
      if (force != null) 'force': force,
      if (cleanMeta != null) 'cleanMeta': cleanMeta,
      if (fixTypeNames != null) 'fixTypeNames': fixTypeNames,
      if (workDir != null && workDir.isNotEmpty) 'workDir': workDir,
    });
  }

  /// A8: DexKit 反混淆查找。默认自动组合证据并在零命中时换路。
  static Future<ApkStructuralResult> dexSearch({
    required String path,
    String keyword = '',
    List<num>? numbers,
    String? className,
    String? methodName,
    List<String>? fieldNames,
    List<String>? invokedMethodNames,
    List<String>? opNames,
    String action = 'auto',
    String matchType = 'Contains',
    bool ignoreCase = false,
    String? packagePrefix,
    int? limit,
  }) {
    return _invoke('dexSearch', {
      'path': path,
      'keyword': keyword,
      if (numbers != null && numbers.isNotEmpty) 'numbers': numbers,
      if (className != null && className.isNotEmpty) 'className': className,
      if (methodName != null && methodName.isNotEmpty) 'methodName': methodName,
      if (fieldNames != null && fieldNames.isNotEmpty) 'fieldNames': fieldNames,
      if (invokedMethodNames != null && invokedMethodNames.isNotEmpty)
        'invokedMethodNames': invokedMethodNames,
      if (opNames != null && opNames.isNotEmpty) 'opNames': opNames,
      'action': action,
      'matchType': matchType,
      'ignoreCase': ignoreCase,
      if (packagePrefix != null && packagePrefix.isNotEmpty)
        'packagePrefix': packagePrefix,
      if (limit != null) 'limit': limit,
    });
  }

  /// A9: 敏感字符串扫描。category ∈ {all, url, ip, email, jwt, private_key,
  /// aws_ak, google_api, aliyun_ak, secret_field}；ip 默认排除本地/保留/私网地址。
  static Future<ApkStructuralResult> stringScan({
    required String path,
    String category = 'all',
    int? minLen,
    int? limit,
    bool? includePrivate,
  }) {
    return _invoke('stringScan', {
      'path': path,
      'category': category,
      if (minLen != null) 'minLen': minLen,
      if (limit != null) 'limit': limit,
      if (includePrivate != null) 'includePrivate': includePrivate,
    });
  }

  static Future<ApkStructuralResult> apkArchive({
    required String path,
    String action = 'list',
    String? query,
    String? entry,
    int? offset,
    int? limit,
    int? minLen,
  }) {
    return _invoke('apkArchive', {
      'path': path,
      'action': action,
      if (query != null && query.isNotEmpty) 'query': query,
      if (entry != null && entry.isNotEmpty) 'entry': entry,
      if (offset != null) 'offset': offset,
      if (limit != null) 'limit': limit,
      if (minLen != null) 'minLen': minLen,
    });
  }

  /// M2: DEX 调用处、流程图与重写实现。
  static Future<ApkStructuralResult> dexXref({
    required String path,
    required String target,
    String direction = 'to',
    String? classPrefix,
    int offset = 0,
    int? limit,
    bool includeGraph = false,
    int callSiteOffset = 0,
    int? callSiteLimit,
  }) {
    return _invoke('dexXref', {
      'path': path,
      'target': target,
      'direction': direction,
      if (classPrefix != null && classPrefix.isNotEmpty)
        'classPrefix': classPrefix,
      'offset': offset,
      'includeGraph': includeGraph,
      if (limit != null) 'limit': limit,
      'callSiteOffset': callSiteOffset,
      if (callSiteLimit != null) 'callSiteLimit': callSiteLimit,
    });
  }

  /// M2: Field XREF（字段 → 读写它的方法，跨 dex 聚合，带指令 index）。
  /// offset/limit 均缺省时一次返回全部（写入方优先）；分页场景显式传参。
  static Future<ApkStructuralResult> fieldXref({
    required String path,
    required String fieldTarget,
    int? offset,
    int? limit,
  }) {
    return _invoke('fieldXref', {
      'path': path,
      'fieldTarget': fieldTarget,
      if (offset != null) 'offset': offset,
      if (limit != null) 'limit': limit,
    });
  }

  /// M2: 类大纲（替代 outline_class）。className 支持全限定或短名子串。
  static Future<ApkStructuralResult> classOutline({
    required String path,
    required String className,
    int offset = 0,
    int? limit,
  }) {
    return _invoke('classOutline', {
      'path': path,
      'className': className,
      'offset': offset,
      if (limit != null) 'limit': limit,
    });
  }

  /// M2: smaliRead（替代 mt_apk_read_text）。按 qualifiedId 输出方法 smali。
  static Future<ApkStructuralResult> smaliRead({
    required String path,
    required String qualifiedId,
  }) {
    return _invoke('smaliRead', {'path': path, 'qualifiedId': qualifiedId});
  }

  /// M3: SO 引擎统一入口。action 覆盖 workspace/read/edit/emulate/backend/blutter 全部分域。
  static Future<ApkStructuralResult> soAnalyze(Map<String, Object?> args) {
    return _invoke('soAnalyze', args);
  }

  /// 按需下载可选引擎资源。
  /// [url] 必须 http/https 且非私有地址（引擎侧校验）；[sha256] 可选校验。
  static Future<ApkStructuralResult> assetDownload({
    required String url,
    required String name,
    String? sha256,
  }) {
    return _invoke('soAnalyze', {
      'action': 'asset_download',
      'url': url,
      'name': name,
      if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
    });
  }

  static Future<ApkStructuralResult> assetStatus({List<String>? names}) {
    return _invoke('soAnalyze', {
      'action': 'asset_status',
      if (names != null && names.isNotEmpty) 'names': names,
    });
  }

  /// 文件管理：读写工作目录任意格式文件 / 增删改查 / 压缩解压。
  /// action ∈ {read, write, list, delete, info, zip, unzip, copy, rename, grep, replace, strings}；
  /// write/delete/zip/unzip 写操作需 dryRun→confirm（previewToken 由调用方管理）。
  static Future<ApkStructuralResult> fileOps(Map<String, Object?> args) {
    return _invoke('fileOps', args);
  }

  /// 打断：取消当前执行中的长任务（DEX 分析 / SO 分析 / jadx 等），
  /// 引擎返回 TASK_CANCELLED 结构化错误。
  static Future<bool> cancelTask() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'cancelTask',
        <String, Object?>{},
      );
      return raw is Map && raw['cancelled'] == true;
    } catch (_) {
      return false;
    }
  }
}
