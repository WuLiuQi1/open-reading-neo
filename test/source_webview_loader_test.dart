import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_webview_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/source_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'cancellation identifies and settles an in-flight WebView load',
    () async {
      final pendingLoad = Completer<Map<String, dynamic>?>();
      String? loadRequestId;
      String? cancelledRequestId;
      final cancelCalled = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = (call.arguments as Map).cast<String, dynamic>();
        if (call.method == 'load') {
          loadRequestId = arguments['requestId'] as String?;
          return pendingLoad.future;
        }
        if (call.method == 'cancel') {
          cancelledRequestId = arguments['requestId'] as String?;
          cancelCalled.complete();
          return true;
        }
        throw MissingPluginException();
      });
      final cancellation = BookDownloadCancellation();
      final loader = SourceWebViewLoader.withChannel(channel);

      final load = loader.load(
        url: Uri.parse('https://books.test/slow'),
        method: 'GET',
        headers: const {},
        cancellation: cancellation,
      );
      await _untilCalled(() => loadRequestId != null);

      cancellation.cancel();

      await expectLater(load, throwsA(isA<BookDownloadCancelledException>()));
      await cancelCalled.future;
      expect(cancelledRequestId, loadRequestId);
      pendingLoad.complete(null);
    },
  );

  test('cancellation settles an in-flight bounded byte load', () async {
    final pendingLoad = Completer<Map<String, dynamic>?>();
    String? loadRequestId;
    String? cancelledRequestId;
    int? maxBytes;
    final cancelCalled = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = (call.arguments as Map).cast<String, dynamic>();
      if (call.method == 'loadBytes') {
        loadRequestId = arguments['requestId'] as String?;
        maxBytes = arguments['maxBytes'] as int?;
        return pendingLoad.future;
      }
      if (call.method == 'cancel') {
        cancelledRequestId = arguments['requestId'] as String?;
        cancelCalled.complete();
        return true;
      }
      throw MissingPluginException();
    });
    final cancellation = BookDownloadCancellation();
    final loader = SourceWebViewLoader.withChannel(channel);

    final load = loader.loadBytes(
      url: Uri.parse('https://books.test/cover'),
      headers: const {},
      maxBytes: 4096,
      cancellation: cancellation,
    );
    await _untilCalled(() => loadRequestId != null);

    cancellation.cancel();

    await expectLater(load, throwsA(isA<BookDownloadCancelledException>()));
    await cancelCalled.future;
    expect(cancelledRequestId, loadRequestId);
    expect(maxBytes, 4096);
    pendingLoad.complete(null);
  });

  test('a completed load unregisters its cancellation listener', () async {
    var cancelCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancel') {
        cancelCalls++;
        return true;
      }
      return <String, dynamic>{
        'body': '<html>ready</html>',
        'finalUrl': 'https://books.test/ready',
      };
    });
    final cancellation = BookDownloadCancellation();
    final loader = SourceWebViewLoader.withChannel(channel);

    await loader.load(
      url: Uri.parse('https://books.test/ready'),
      method: 'GET',
      headers: const {},
      cancellation: cancellation,
    );
    cancellation.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(cancelCalls, 0);
  });

  test('an already cancelled token does not start a platform load', () async {
    var platformCalls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      platformCalls++;
      return null;
    });
    final cancellation = BookDownloadCancellation()..cancel();
    final loader = SourceWebViewLoader.withChannel(channel);

    await expectLater(
      loader.load(
        url: Uri.parse('https://books.test/cancelled'),
        method: 'GET',
        headers: const {},
        cancellation: cancellation,
      ),
      throwsA(isA<BookDownloadCancelledException>()),
    );

    expect(platformCalls, 0);
  });

  test('parallel loads cancel only the matching request ID', () async {
    final pendingLoads = <String, Completer<Map<String, dynamic>?>>{};
    final cancelledRequestIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = (call.arguments as Map).cast<String, dynamic>();
      final requestId = arguments['requestId'] as String;
      if (call.method == 'load') {
        final pending = Completer<Map<String, dynamic>?>();
        pendingLoads[requestId] = pending;
        return pending.future;
      }
      if (call.method == 'cancel') {
        cancelledRequestIds.add(requestId);
        return true;
      }
      throw MissingPluginException();
    });
    final firstCancellation = BookDownloadCancellation();
    final secondCancellation = BookDownloadCancellation();
    final loader = SourceWebViewLoader.withChannel(channel);

    final first = loader.load(
      url: Uri.parse('https://books.test/first'),
      method: 'GET',
      headers: const {},
      cancellation: firstCancellation,
    );
    final second = loader.load(
      url: Uri.parse('https://books.test/second'),
      method: 'GET',
      headers: const {},
      cancellation: secondCancellation,
    );
    await _untilCalled(() => pendingLoads.length == 2);
    final requestIds = pendingLoads.keys.toList();

    firstCancellation.cancel();
    await expectLater(first, throwsA(isA<BookDownloadCancelledException>()));
    await _untilCalled(() => cancelledRequestIds.isNotEmpty);
    expect(cancelledRequestIds, [requestIds.first]);

    pendingLoads[requestIds.last]!.complete(<String, dynamic>{
      'body': '<html>second</html>',
      'finalUrl': 'https://books.test/second',
    });
    expect((await second).body, '<html>second</html>');
    pendingLoads[requestIds.first]!.complete(null);
  });

  test('token cancellation wins a simultaneous platform error', () async {
    final pendingLoad = Completer<Map<String, dynamic>?>();
    final cancellation = BookDownloadCancellation();
    cancellation.addListener(() {
      pendingLoad.completeError(
        PlatformException(code: 'cancelled', message: 'native cancelled'),
      );
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') return pendingLoad.future;
      if (call.method == 'cancel') return true;
      throw MissingPluginException();
    });
    final loader = SourceWebViewLoader.withChannel(channel);
    final load = loader.load(
      url: Uri.parse('https://books.test/race'),
      method: 'GET',
      headers: const {},
      cancellation: cancellation,
    );

    cancellation.cancel();

    await expectLater(load, throwsA(isA<BookDownloadCancelledException>()));
  });
}

Future<void> _untilCalled(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20 && !predicate(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}
