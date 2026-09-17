import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 发送层失败重连：对瞬态故障（连接被拒/中断/超时、HTTP 408/429/5xx）
/// 做有限次指数退避重试；业务性 4xx（如 schema 被拒的 400）不重试——
/// 重放同样的请求不会成功。仅在响应头到达、流未消费前判定，不对
/// 已建立的 SSE 流做中途续传。
abstract final class HttpSendRetry {
  static const Set<int> retryableStatusCodes = {408, 429, 500, 502, 503, 504};

  /// buildRequest 每次重新构造（http.Request 携带 body 字节后不可复用）。
  static Future<http.StreamedResponse> send(
    http.Client client,
    http.Request Function() buildRequest, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(milliseconds: 500),
  }) async {
    assert(maxAttempts >= 1);
    var delay = initialDelay;
    for (var attempt = 1; ; attempt++) {
      http.StreamedResponse response;
      try {
        response = await client.send(buildRequest());
      } on Exception catch (e) {
        if (!_isTransient(e) || attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(delay);
        delay *= 2;
        continue;
      }
      if (!retryableStatusCodes.contains(response.statusCode) ||
          attempt >= maxAttempts) {
        return response;
      }
      // 瞬态状态码：先排空旧响应再退避重试，避免连接占用。
      await response.stream.drain<void>().catchError((_) {});
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }

  static bool _isTransient(Exception e) =>
      e is SocketException || e is TimeoutException || e is http.ClientException;
}
