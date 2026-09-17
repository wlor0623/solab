import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// SoLab APK 原生分析进度监听：EventChannel 'solab/progress' 的 Dart 侧消费方。
///
/// 此前进度事件发出后无任何监听方（无效投递）；现在记录最近一次进度供
/// 工作台展示，并可在工具结果中附注，避免分析大包时 AI/用户误判超时。
class ApkProgressService extends ChangeNotifier {
  ApkProgressService._();

  static final ApkProgressService instance = ApkProgressService._();

  static const _channel = EventChannel('solab/progress');
  static const _soChannel = EventChannel('so_analyze/progress');

  StreamSubscription<Object?>? _subscription;
  StreamSubscription<Object?>? _soSubscription;
  bool _listening = false;

  int _percent = 0;
  String _stage = '';

  /// SO 引擎最近进度（so_analyze 长任务阶段）。
  int _soPercent = 0;
  String _soStage = '';

  /// 最近一次分析进度百分比（0-100）。
  int get percent => _percent;

  /// 最近一次分析阶段说明（原生侧 stage 文案）。
  String get stage => _stage;

  bool get hasProgress => _percent > 0;

  /// SO 引擎进度（0-100）与阶段。
  int get soPercent => _soPercent;
  String get soStage => _soStage;
  bool get hasSoProgress => _soPercent > 0;

  /// 订阅进度通道（幂等）。在 Android 通道注册后调用；其它平台订阅无害。
  void ensureListening() {
    if (_listening) return;
    _listening = true;
    _subscription = _channel.receiveBroadcastStream().listen(
      (event) {
        try {
          if (event is Map) {
            final percent = (event['percent'] as num?)?.toInt() ?? 0;
            final stage = (event['stage'] as String?) ?? '';
            if (percent != _percent || stage != _stage) {
              _percent = percent;
              _stage = stage;
              notifyListeners();
            }
          }
        } catch (_) {}
      },
      onError: (_) {
        // 通道未注册/已关闭：忽略；下次分析事件仍会发出。
      },
      cancelOnError: true,
    );
    // SO 引擎进度（so_analyze 长任务：open/analyze_apk/emulate/blutter）
    _soSubscription = _soChannel.receiveBroadcastStream().listen(
      (event) {
        try {
          if (event is Map) {
            final percent = (event['percent'] as num?)?.toInt() ?? 0;
            final stage = (event['stage'] as String?) ?? '';
            if (percent != _soPercent || stage != _soStage) {
              _soPercent = percent;
              _soStage = stage;
              notifyListeners();
            }
          }
        } catch (_) {}
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// 重置进度（新分析开始时调用）。
  void reset() {
    if (_percent == 0 &&
        _stage.isEmpty &&
        _soPercent == 0 &&
        _soStage.isEmpty) {
      return;
    }
    _percent = 0;
    _stage = '';
    _soPercent = 0;
    _soStage = '';
    notifyListeners();
  }

  /// 工具结果附注：最近一次进度的紧凑描述，无进度时返回 null。
  String? progressSummary() {
    if (_percent > 0) return '最近一次分析进度：$_percent%（$_stage）';
    if (_soPercent > 0) return 'SO 引擎进度：$_soPercent%（$_soStage）';
    return null;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _soSubscription?.cancel();
    _soSubscription = null;
    _listening = false;
    super.dispose();
  }
}
