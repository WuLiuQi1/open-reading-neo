import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';

class SourcePlatformBytesResult {
  const SourcePlatformBytesResult({
    required this.statusCode,
    required this.bytes,
    this.location,
  });

  final int statusCode;
  final Uint8List bytes;
  final String? location;
}

class SourceWebViewResult {
  const SourceWebViewResult({
    required this.body,
    required this.finalUri,
    this.cookieHeader,
  });

  final String body;
  final Uri finalUri;
  final String? cookieHeader;
}

abstract interface class SourceWebViewLoaderPort {
  Future<SourcePlatformBytesResult> loadBytes({
    required Uri url,
    required Map<String, String> headers,
    required int maxBytes,
    BookDownloadCancellation? cancellation,
  });

  Future<SourceWebViewResult> load({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    String? body,
    String? webJs,
    String? html,
    BookDownloadCancellation? cancellation,
  });
}

class SourceWebViewLoader implements SourceWebViewLoaderPort {
  const SourceWebViewLoader() : _channel = _defaultChannel;

  @visibleForTesting
  const SourceWebViewLoader.withChannel(this._channel);

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.niki.xxread/source_webview',
  );
  static int _requestSequence = 0;

  final MethodChannel _channel;

  @override
  Future<SourcePlatformBytesResult> loadBytes({
    required Uri url,
    required Map<String, String> headers,
    required int maxBytes,
    BookDownloadCancellation? cancellation,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const BookSourceProtocolException(
        'Platform byte loading is available on Android only.',
      );
    }
    try {
      final result = await _invokeCancellable(
        method: 'loadBytes',
        arguments: {
          'url': url.toString(),
          'headers': headers,
          'maxBytes': maxBytes,
          'timeoutMs': 15000,
        },
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      final statusCode = result?['statusCode'];
      final bytes = result?['bytes'];
      if (statusCode is! int || bytes is! Uint8List) {
        throw const BookSourceProtocolException(
          'Platform byte loader returned an invalid response.',
        );
      }
      return SourcePlatformBytesResult(
        statusCode: statusCode,
        bytes: bytes,
        location: result?['location'] as String?,
      );
    } on PlatformException catch (error) {
      cancellation?.throwIfCancelled();
      throw BookSourceProtocolException(
        error.message ?? 'Platform byte loading failed.',
      );
    }
  }

  @override
  Future<SourceWebViewResult> load({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    String? body,
    String? webJs,
    String? html,
    BookDownloadCancellation? cancellation,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const BookSourceProtocolException(
        'This source requires background browser loading on Android.',
      );
    }
    try {
      final result = await _invokeCancellable(
        method: 'load',
        arguments: {
          'url': url.toString(),
          'method': method,
          'headers': headers,
          'body': body,
          'webJs': webJs,
          'html': html,
          'timeoutMs': 15000,
        },
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      final responseBody = result?['body'];
      final finalUrl = result?['finalUrl'];
      final cookieHeader = result?['cookieHeader'];
      final uri = finalUrl is String ? Uri.tryParse(finalUrl) : null;
      if (responseBody is! String || uri == null) {
        throw const BookSourceProtocolException(
          'Background browser returned an invalid response.',
        );
      }
      return SourceWebViewResult(
        body: responseBody,
        finalUri: uri,
        cookieHeader: cookieHeader is String ? cookieHeader : null,
      );
    } on PlatformException catch (error) {
      cancellation?.throwIfCancelled();
      throw BookSourceProtocolException(
        error.message ?? 'Background browser failed to load this source.',
      );
    }
  }

  Future<Map<String, dynamic>?> _invokeCancellable({
    required String method,
    required Map<String, dynamic> arguments,
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_requestSequence++}';
    final platformLoad = _channel.invokeMapMethod<String, dynamic>(method, {
      ...arguments,
      'requestId': requestId,
    });
    if (cancellation == null) return platformLoad;

    void cancelPlatformLoad() {
      unawaited(_cancelPlatformLoad(requestId));
    }

    cancellation.addListener(cancelPlatformLoad);
    try {
      return await Future.any<Map<String, dynamic>?>([
        platformLoad,
        cancellation.whenCancelled.then<Map<String, dynamic>?>((_) {
          throw const BookDownloadCancelledException();
        }),
      ]);
    } finally {
      cancellation.removeListener(cancelPlatformLoad);
    }
  }

  Future<void> _cancelPlatformLoad(String requestId) async {
    try {
      await _channel.invokeMethod<bool>('cancel', {'requestId': requestId});
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'source WebView loader',
          context: ErrorDescription(
            'while cancelling background browser request $requestId',
          ),
        ),
      );
    }
  }
}
