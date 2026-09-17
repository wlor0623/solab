enum ApkExecutionMode { reportOnly, analyzeOnly, modify }

abstract final class ApkAgentPolicy {
  static const String version = 'evidence-composition-v4';
  static const int maxVisibleToolResultChars = 16000;
  static const int maxEvidenceTokens = 80000;

  static const Set<String> mutationToolNames = <String>{
    'patch_apk_dex_methods',
    'signature_bypass',
    'patch_apk_manifest',
    'apk_sign',
    'apk_rebuild',
    'so_patch_into_apk',
    'cleanup_apk_builds',
    'save_apk_patch_memory',
    'record_apk_patch_verification',
    'apk_note_write',
  };

  static ApkExecutionMode executionModeFor(String goal) {
    final text = goal.trim().toLowerCase();
    if (RegExp(
      r'修改|修复|打补丁|补丁|去广告|解锁|精简|删除|移除|替换|写入|回填|回编|重打包|重新打包|签名|构建|安装|patch|modify|fix|rebuild|sign',
      caseSensitive: false,
    ).hasMatch(text)) {
      return ApkExecutionMode.modify;
    }
    if (RegExp(
      r'报告|汇报|总结|report|summary',
      caseSensitive: false,
    ).hasMatch(text)) {
      return ApkExecutionMode.reportOnly;
    }
    return ApkExecutionMode.analyzeOnly;
  }

  /// Agent 与 MCP 共用的判断契约。两种模式必须原样注入这一段，避免证据
  /// 标准、反混淆策略和停止条件各写一份后逐渐漂移。
  static const String sharedDecisionPolicy =
      '''
<apk_decision_policy version="$version">
1. Treat routes and preferred tools as candidates, never as a mandatory sequence. DEX, Flutter, native, resources, and existing artifacts are independent evidence probes. Start from an exact qualifiedId, field locator, string reference, file identity, or VA when one already exists.
2. Maintain competing falsifiable hypotheses. Choose the cheapest probe that can change their ranking or the patch method. Stop when another read cannot change the decision.
3. A current exact method body or field data-flow proof can decide alone. Otherwise require two independent indirect sources. UI text, names, package prefixes, cached reports, and heuristic scores are clues rather than proof.
4. Recover obfuscated semantics through used strings/resources, constants, return types, field READ/WRITE, callers/callees, object-pool references, file identity, and function VA. A miss rejects only that search dimension.
5. Map identities before comparing outputs: APK entry, DEX qualifiedId, ELF VA, and Dart functionVa are different projections of the same program. Current exact code/data flow outranks cached or name-based evidence.
6. If two strong sources conflict, retain both hypotheses and use a third independent probe. Never force agreement by majority vote or a fixed layer preference.
7. Keep output compact: decision, exact locator, decisive evidence, uncertainty, and at most one next discriminating action. Paginate only when the next page can affect the decision.
8. Obey the requested boundary. A report request only reads existing facts and writes the report response. An analysis request may run read-only probes but must stop before previewing, patching, rebuilding, signing, installing, cleaning, or saving memory. Mutation tools are allowed only when the user explicitly requests a modification or build action.
9. Every analysis, signature_bypass, patch, build and sign tool is independently callable; never require a fixed full pipeline. Before every first business write, use standalone signature_bypass on the unchanged original unless the supplied input is already its prepared output, the user explicitly asks to skip it, or the APK 工作台 setting is off. Honor the user-requested mode exactly; when omitted, follow the APK 工作台 setting (new-install default: normal). dpatch must return a separate prepared output and that output, never the original APK, is the next input. If installation fails, preserve the original and offer or select a different signature mode only for a fresh preparation from that original.
</apk_decision_policy>''';
}
