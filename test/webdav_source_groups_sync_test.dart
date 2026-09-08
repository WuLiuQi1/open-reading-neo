import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/sync/adapters/book_source_groups_sync_adapter.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_clock.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  late Database database;
  late SyncChangeStore store;
  late BookSourceRegistry registry;
  late BookSourceGroupsSyncAdapter adapter;
  late MetadataSyncAdapters adapters;

  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await WebDavSyncSchemaMigration.migrate(database);
    store = SyncChangeStore(database: () async => database);
    registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    adapter = BookSourceGroupsSyncAdapter(store, registry);
    adapters = MetadataSyncAdapters(
      store: store,
      database: () async => database,
      registeredAdapters: [adapter],
    );
  });

  tearDown(() async {
    await BookSourceRegistry.resetForTesting();
    await database.close();
  });

  Future<void> applyRemote({
    required int sequence,
    required String hlc,
    required List<String> groups,
  }) async {
    await store.applyRemoteBatch(
      SyncBatch.create(
        deviceId: 'remote',
        sequence: sequence,
        createdHlc: hlc,
        operations: [_operation(hlc: hlc, groups: groups)],
      ),
      validateWinner: adapters.validate,
      applyWinner: adapters.apply,
    );
    await adapters.scan(
      _bookSourcesOnlyScope(),
      HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => sequence * 1000 + 1001,
      ),
    );
  }

  test(
    'scan preserves order and empty groups, publishes removal once',
    () async {
      await registry.createGroup('Unread');
      await registry.createGroup('Empty');
      await registry.createGroup('Favorites');
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 1000,
      );

      await adapters.scan(const WebDavSyncScope(), clock);
      var record = (await store.recordsForDataset('book_source_groups')).single;
      expect(record.recordId, BookSourceGroupsSyncAdapter.catalogRecordId);
      expect(record.entityKey, BookSourceGroupsSyncAdapter.catalogRecordId);
      expect(record.payload, {
        'sync_schema': 1,
        'groups': ['Unread', 'Empty', 'Favorites'],
      });
      expect(record.dirty, isTrue);

      await store.markUploaded([record]);
      final uploadedHlc = record.hlc;
      await registry.deleteGroup('Empty');
      await adapters.scan(const WebDavSyncScope(), clock);
      record = (await store.recordsForDataset('book_source_groups')).single;
      expect(record.payload!['groups'], ['Unread', 'Favorites']);
      expect(record.dirty, isTrue);
      expect(record.hlc, isNot(uploadedHlc));

      await store.markUploaded([record]);
      final stableHlc = record.hlc;
      await adapters.scan(const WebDavSyncScope(), clock);
      record = (await store.recordsForDataset('book_source_groups')).single;
      expect(record.hlc, stableHlc);
      expect(record.dirty, isFalse);
    },
  );

  test('factory registration includes the source group adapter', () {
    final defaults = MetadataSyncAdapters(
      store: store,
      database: () async => database,
      bookSourceRegistry: registry,
    );

    expect(
      defaults.adapters.whereType<BookSourceGroupsSyncAdapter>(),
      hasLength(1),
    );
  });

  test('fresh empty scan does not outrank an older remote catalog', () async {
    final defaults = MetadataSyncAdapters(
      store: store,
      database: () async => database,
      bookSourceRegistry: registry,
    );
    final scope = _bookSourcesOnlyScope();

    await defaults.scan(
      scope,
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
    );
    expect(await store.recordsForDataset('book_source_groups'), isEmpty);

    final operation = _operation(
      hlc: '2000-0000-remote',
      groups: const ['Remote Empty'],
    );
    await store.applyRemoteBatch(
      SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: operation.hlc,
        operations: [operation],
      ),
      validateWinner: defaults.validate,
      applyWinner: defaults.apply,
    );
    await defaults.scan(
      scope,
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
    );

    expect(await registry.loadGroups(), ['Remote Empty']);
    final record = (await store.recordsForDataset('book_source_groups')).single;
    expect(record.hlc, operation.hlc);
    expect(record.dirty, isFalse);
  });

  test(
    'restore keeps source records, memberships, and referenced groups',
    () async {
      final source = _source(groups: const ['Pinned']);
      await registry.upsert(source);

      await applyRemote(
        sequence: 1,
        hlc: '2000-0000-remote',
        groups: const ['Empty', 'Reading'],
      );

      expect(await registry.loadGroups(), ['Empty', 'Reading', 'Pinned']);
      expect((await registry.load()).single.toJson(), source.toJson());

      await applyRemote(
        sequence: 2,
        hlc: '3000-0000-remote',
        groups: const ['Empty'],
      );
      expect(await registry.loadGroups(), ['Empty', 'Pinned']);
      expect((await registry.load()).single.groups, ['Pinned']);
    },
  );

  test('group-first rename batch removes the old referenced group', () async {
    final localSource = _source(groups: const ['Old']);
    await registry.upsert(localSource);
    final defaults = MetadataSyncAdapters(
      store: store,
      database: () async => database,
      bookSourceRegistry: registry,
    );
    await defaults.scan(
      _bookSourcesOnlyScope(),
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
    );
    await store.markUploaded(await store.dirtyRecords());

    final renamedSource = localSource.copyWith(groups: const ['New']);
    await store.applyRemoteBatch(
      SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '2000-0001-remote',
        operations: [
          _operation(hlc: '2000-0000-remote', groups: const ['New']),
          SyncOperation(
            dataset: 'book_sources',
            recordId: stableRecordId('book_source', renamedSource.id),
            entityKey: renamedSource.id,
            hlc: '2000-0001-remote',
            deleted: false,
            payload: {...renamedSource.toJson(), 'sync_schema': 1},
          ),
        ],
      ),
      validateWinner: defaults.validate,
      applyWinner: defaults.apply,
    );
    await defaults.scan(
      _bookSourcesOnlyScope(),
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
    );

    expect((await registry.load()).single.groups, ['New']);
    expect(await registry.loadGroups(), ['New']);
  });

  test(
    'disabled scope defers restore until book source sync is enabled',
    () async {
      await registry.createGroup('Local');
      final operation = _operation(
        hlc: '2000-0000-remote',
        groups: const ['Remote Empty', 'Remote First'],
      );

      await store.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: operation.hlc,
          operations: [operation],
        ),
        validateWinner: adapters.validate,
        applyWinner: (txn, winner) => adapters.apply(
          txn,
          winner,
          scope: const WebDavSyncScope(bookSources: false),
        ),
      );
      expect(await registry.loadGroups(), ['Local']);
      expect(
        await store.getState(
          'locally_observed:book_source_groups:${BookSourceGroupsSyncAdapter.catalogRecordId}',
        ),
        isNull,
      );

      await adapters.scan(
        const WebDavSyncScope(),
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
      );
      expect(await registry.loadGroups(), ['Remote Empty', 'Remote First']);
      final record = (await store.recordsForDataset(
        'book_source_groups',
      )).single;
      expect(record.hlc, operation.hlc);
      expect(record.dirty, isFalse);
    },
  );

  test(
    'invalid catalog rejects the complete remote batch atomically',
    () async {
      await registry.createGroup('Local');
      final invalid = SyncOperation(
        dataset: 'book_source_groups',
        recordId: BookSourceGroupsSyncAdapter.catalogRecordId,
        entityKey: BookSourceGroupsSyncAdapter.catalogRecordId,
        hlc: '2000-0000-remote',
        deleted: false,
        payload: const {
          'sync_schema': 1,
          'groups': ['Valid', ' Valid'],
        },
      );

      await expectLater(
        store.applyRemoteBatch(
          SyncBatch.create(
            deviceId: 'remote',
            sequence: 1,
            createdHlc: invalid.hlc,
            operations: [
              const SyncOperation(
                dataset: 'future_dataset',
                recordId: 'future-record',
                entityKey: 'future-record',
                hlc: '2000-0000-remote',
                deleted: false,
                payload: {'value': true},
              ),
              invalid,
            ],
          ),
          validateWinner: adapters.validate,
          applyWinner: adapters.apply,
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (error) => error.code,
            'code',
            WebDavSyncErrorCode.corruptRemoteData,
          ),
        ),
      );

      expect(await registry.loadGroups(), ['Local']);
      expect(await store.recordsForDataset('book_source_groups'), isEmpty);
      expect(await store.recordsForDataset('future_dataset'), isEmpty);
      expect(await store.cursorFor('remote'), 0);
    },
  );

  test(
    'large registries preserve groups through background sync decoding',
    () async {
      final source = RegisteredBookSource.fromJson({
        ..._source(groups: const ['Member']).toJson(),
        'description': List.filled(270000, 'x').join(),
      });
      await registry.upsert(source);
      await registry.createGroup('Empty');
      await registry.reorderGroups(const ['Empty', 'Member']);
      expect(await registry.loadGroupsForSync(), ['Empty', 'Member']);
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );
      expect(
        (await store.recordsForDataset('book_source_groups')).single.payload,
        {
          'sync_schema': 1,
          'groups': ['Empty', 'Member'],
        },
      );
    },
  );

  test('damaged local registry cannot publish an empty catalog', () async {
    final damagedStorage = _MemoryRegistryStorage('{invalid json');
    final damagedRegistry = BookSourceRegistry(storage: damagedStorage);
    final damagedAdapter = BookSourceGroupsSyncAdapter(store, damagedRegistry);

    await expectLater(
      damagedAdapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.localDataCorrupt,
        ),
      ),
    );
    expect(await store.recordsForDataset('book_source_groups'), isEmpty);

    await expectLater(
      database.transaction(
        (txn) => damagedAdapter.apply(
          txn,
          _operation(hlc: '2000-0000-remote', groups: const ['Remote']),
        ),
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.localDataCorrupt,
        ),
      ),
    );
    expect(damagedStorage.raw, '{invalid json');
  });
}

WebDavSyncScope _bookSourcesOnlyScope() => const WebDavSyncScope(
  books: false,
  progress: false,
  bookmarks: false,
  notes: false,
  readingSessions: false,
  readerSettings: false,
  replaceRules: false,
);

SyncOperation _operation({required String hlc, required List<String> groups}) =>
    SyncOperation(
      dataset: 'book_source_groups',
      recordId: BookSourceGroupsSyncAdapter.catalogRecordId,
      entityKey: BookSourceGroupsSyncAdapter.catalogRecordId,
      hlc: hlc,
      deleted: false,
      payload: {'sync_schema': 1, 'groups': groups},
    );

RegisteredBookSource _source({required List<String> groups}) =>
    RegisteredBookSource(
      id: 'org.example.books',
      name: 'Example Books',
      description: 'Example source',
      manifestUrl: Uri.parse(
        'https://example.org/.well-known/open-reading-source.json',
      ),
      apiBaseUrl: Uri.parse('https://example.org/api/'),
      protocolVersion: '1.4',
      languages: const ['en'],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      groups: groups,
      addedAt: DateTime.utc(2026, 9, 8),
    );

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  _MemoryRegistryStorage([this.raw]);

  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
