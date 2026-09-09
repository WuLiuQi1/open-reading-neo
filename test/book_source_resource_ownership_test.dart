import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_contract.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  group('BookSourceShelfService ownership', () {
    test('does not close an injected client', () {
      final client = _CloseTrackingClient();
      final service = BookSourceShelfService(client: client);

      service.close();
      service.close();

      expect(client.closeCount, 0);
    });

    test('closes a factory-created client exactly once', () {
      final client = _CloseTrackingClient();
      final service = BookSourceShelfService(clientFactory: () => client);

      service.close();
      service.close();

      expect(client.closeCount, 1);
    });
  });

  group('BookSourceChangeService ownership', () {
    test('owns and shares both default-created dependencies', () {
      final events = <String>[];
      final client = _CloseTrackingClient(events: events);
      late BookSourceClient shelfClient;
      final shelfService = _CloseTrackingShelfService(events: events);
      final service = BookSourceChangeService(
        clientFactory: () => client,
        shelfServiceFactory: (resolvedClient) {
          shelfClient = resolvedClient;
          return shelfService;
        },
      );

      service.close();
      service.close();

      expect(shelfClient, same(client));
      expect(shelfService.closeCount, 1);
      expect(client.closeCount, 1);
      expect(events, ['shelf', 'client']);
    });

    test('borrows an injected client and owns the default shelf service', () {
      final client = _CloseTrackingClient();
      late BookSourceClient shelfClient;
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        client: client,
        shelfServiceFactory: (resolvedClient) {
          shelfClient = resolvedClient;
          return shelfService;
        },
      );

      service.close();
      service.close();

      expect(shelfClient, same(client));
      expect(shelfService.closeCount, 1);
      expect(client.closeCount, 0);
    });

    test('owns the default client and borrows an injected shelf service', () {
      final client = _CloseTrackingClient();
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        clientFactory: () => client,
        shelfService: shelfService,
      );

      service.close();
      service.close();

      expect(shelfService.closeCount, 0);
      expect(client.closeCount, 1);
    });

    test('borrows both injected dependencies', () {
      final client = _CloseTrackingClient();
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        client: client,
        shelfService: shelfService,
      );

      service.close();
      service.close();

      expect(shelfService.closeCount, 0);
      expect(client.closeCount, 0);
    });
  });

  test(
    'a closed source runtime cannot lazily recreate its script engine',
    () async {
      final evaluator = _CloseTrackingEvaluator();
      final runtime = SourceRuntime(
        transport: _StaticSourceTransport(),
        scriptEvaluator: evaluator,
      );
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Closed runtime',
        'bookSourceUrl': 'https://closed.test',
        'searchUrl': '<js>"/search"</js>',
        'ruleSearch': {
          'bookList': 'class.book',
          'name': 'class.name@text',
          'bookUrl': 'tag.a@href',
        },
      }).toRegisteredSource(enabled: true);

      runtime.close();

      await expectLater(
        runtime.search(source, 'query'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      expect(evaluator.disposeCount, 1);
    },
  );
}

class _CloseTrackingClient extends BookSourceClient {
  _CloseTrackingClient({this.events});

  final List<String>? events;
  int closeCount = 0;

  @override
  void close({bool force = true}) {
    closeCount++;
    events?.add('client');
  }
}

class _CloseTrackingShelfService extends BookSourceShelfService {
  _CloseTrackingShelfService({this.events})
    : super(client: _CloseTrackingClient());

  final List<String>? events;
  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    events?.add('shelf');
  }
}

class _CloseTrackingEvaluator implements SourceScriptEvaluator {
  int disposeCount = 0;

  @override
  Object? evaluate(String script, SourceScriptContext context) => '/search';

  @override
  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  @override
  void dispose() {
    disposeCount++;
  }
}

class _StaticSourceTransport implements SourceTransport {
  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async => SourceResponse(
    body:
        '<div class="book"><a href="/book/1"><span class="name">Book</span></a></div>',
    finalUri: request.url,
  );
}
