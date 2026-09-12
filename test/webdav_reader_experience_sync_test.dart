import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/core/reader/paged_image_reader_settings.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/core/reader/reader_custom_theme.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_tap_zones.dart';
import 'package:xxread/core/reader/reader_theme_order.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_clock.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database database;
  late SyncChangeStore changeStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT,
        filePath TEXT NOT NULL,
        format TEXT NOT NULL,
        importDate INTEGER NOT NULL,
        content_hash TEXT,
        source_id TEXT,
        source_book_id TEXT
      )
    ''');
    await WebDavSyncSchemaMigration.migrate(database);
    changeStore = SyncChangeStore(database: () async => database);
  });

  tearDown(() => database.close());

  test(
    'automatic paging preferences round-trip without starting paging',
    () async {
      final original = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      addTearDown(original.dispose);
      for (final selection in const [
        ReaderAutoPageTurnSelection(
          mode: ReaderAutoPageTurnMode.timed,
          seconds: 21,
        ),
        ReaderAutoPageTurnSelection(
          mode: ReaderAutoPageTurnMode.sweep,
          seconds: 8.5,
        ),
        ReaderAutoPageTurnSelection(
          mode: ReaderAutoPageTurnMode.continuous,
          seconds: 42,
        ),
        ReaderAutoPageTurnSelection(
          mode: ReaderAutoPageTurnMode.interval,
          seconds: 17,
        ),
      ]) {
        await original.applySelection(selection);
      }
      await original.setShortcutVisible(false);
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );
      final records = (await changeStore.recordsForDataset('reader_settings'))
          .where((record) => record.recordId.startsWith('auto_page_turn_'))
          .toList();
      expect(records, hasLength(7));

      SharedPreferences.setMockInitialValues(<String, Object>{});
      for (final record in records) {
        final operation = record.toOperation();
        await adapter.validate(operation);
        await database.transaction((txn) => adapter.apply(txn, operation));
      }
      final restored = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      addTearDown(restored.dispose);
      await restored.loadInterval();
      expect(restored.modeFor(false), ReaderAutoPageTurnMode.sweep);
      expect(restored.modeFor(true), ReaderAutoPageTurnMode.interval);
      expect(restored.secondsFor(ReaderAutoPageTurnMode.timed), 21);
      expect(restored.secondsFor(ReaderAutoPageTurnMode.sweep), 8.5);
      expect(restored.secondsFor(ReaderAutoPageTurnMode.continuous), 42);
      expect(restored.secondsFor(ReaderAutoPageTurnMode.interval), 17);
      expect(restored.shortcutVisible, isFalse);
      expect(restored.isActive, isFalse);
      expect(restored.isRunning, isFalse);
    },
  );

  test(
    'automatic paging sync migrates the legacy interval without losing new speeds',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ReaderAutoPageTurnController.intervalPreferenceKey: 24,
        ReaderAutoPageTurnController.timedSecondsPreferenceKey: 9.5,
      });
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );
      final values = {
        for (final record in await changeStore.recordsForDataset(
          'reader_settings',
        ))
          record.entityKey: record.payload?['value'],
      };
      expect(values['auto_page_turn_timed_seconds'], 9.5);
      expect(values['auto_page_turn_vertical_interval_seconds'], 24);
      expect(values.containsKey('auto_page_turn_sweep_seconds'), isFalse);
      expect(values.containsKey('auto_page_turn_continuous_seconds'), isFalse);
      expect(values.containsKey('auto_page_turn_horizontal_mode'), isFalse);
      expect(values.containsKey('auto_page_turn_vertical_mode'), isFalse);
      expect(values.containsKey('auto_page_turn_shortcut_visible'), isFalse);
    },
  );

  test(
    'automatic paging restores deferred settings once after scope is enabled',
    () async {
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      final adapters = MetadataSyncAdapters(
        store: changeStore,
        database: () async => database,
        registeredAdapters: [adapter],
      );
      const key = 'auto_page_turn_sweep_seconds';
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 3000,
      );
      // Match SyncEngine's first scan before downloading older remote data.
      await adapters.scan(const WebDavSyncScope(), clock);
      expect(
        (await changeStore.recordsForDataset(
          'reader_settings',
        )).where((record) => record.recordId.startsWith('auto_page_turn_')),
        isEmpty,
      );
      const operation = SyncOperation(
        dataset: 'reader_settings',
        recordId: key,
        entityKey: key,
        hlc: '2000-0000-remote',
        deleted: false,
        payload: {'value': 12.5},
      );
      await changeStore.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: operation.hlc,
          operations: const [operation],
        ),
        validateWinner: adapters.validate,
        applyWinner: (txn, op) => adapters.apply(
          txn,
          op,
          scope: const WebDavSyncScope(readerSettings: false),
        ),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.get(ReaderAutoPageTurnController.sweepSecondsPreferenceKey),
        isNull,
      );
      await adapters.scan(const WebDavSyncScope(), clock);
      expect(
        preferences.getDouble(
          ReaderAutoPageTurnController.sweepSecondsPreferenceKey,
        ),
        12.5,
      );
      final restored = (await changeStore.recordsForDataset(
        'reader_settings',
      )).singleWhere((record) => record.recordId == key);
      expect(restored.hlc, operation.hlc);
      expect(restored.dirty, isFalse);

      await changeStore.markUploaded(await changeStore.dirtyRecords());
      await adapters.scan(const WebDavSyncScope(), clock);
      expect(await changeStore.dirtyRecords(), isEmpty);
      await preferences.setDouble(
        ReaderAutoPageTurnController.sweepSecondsPreferenceKey,
        18,
      );
      await adapters.scan(const WebDavSyncScope(), clock);
      final changed = (await changeStore.dirtyRecords()).single;
      expect(changed.recordId, key);
      expect(changed.payload?['value'], 18);
    },
  );

  test('automatic paging duration restores within supported bounds', () async {
    final adapter = ReaderSettingsSyncAdapter(
      changeStore,
      () async => database,
    );
    for (final entry in const {
      'auto_page_turn_timed_seconds': -1,
      'auto_page_turn_sweep_seconds': 900,
    }.entries) {
      final operation = SyncOperation(
        dataset: 'reader_settings',
        recordId: entry.key,
        entityKey: entry.key,
        hlc: '2000-0000-remote',
        deleted: false,
        payload: {'value': entry.value},
      );
      await adapter.validate(operation);
      await database.transaction((txn) => adapter.apply(txn, operation));
    }
    final restored = ReaderAutoPageTurnController(onAdvance: () async => true);
    addTearDown(restored.dispose);
    await restored.loadInterval();
    expect(restored.secondsFor(ReaderAutoPageTurnMode.timed), 5);
    expect(restored.secondsFor(ReaderAutoPageTurnMode.sweep), 120);
  });

  for (final entry in const <String, Object>{
    'auto_page_turn_horizontal_mode': 'continuous',
    'auto_page_turn_vertical_mode': 'sweep',
    'auto_page_turn_timed_seconds': '15',
    'auto_page_turn_shortcut_visible': 'false',
  }.entries) {
    test(
      'invalid ${entry.key} rejects the whole batch before changing settings',
      () async {
        final adapters = MetadataSyncAdapters(
          store: changeStore,
          database: () async => database,
          registeredAdapters: [
            ReaderSettingsSyncAdapter(changeStore, () async => database),
          ],
        );
        final batch = SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: '2000-0000-remote',
          operations: [
            const SyncOperation(
              dataset: 'reader_settings',
              recordId: 'font_size',
              entityKey: 'font_size',
              hlc: '2000-0000-remote',
              deleted: false,
              payload: {'value': 27},
            ),
            SyncOperation(
              dataset: 'reader_settings',
              recordId: entry.key,
              entityKey: entry.key,
              hlc: '2001-0000-remote',
              deleted: false,
              payload: {'value': entry.value},
            ),
          ],
        );
        final before = await const ReaderSettingsStore().load();
        await expectLater(
          changeStore.applyRemoteBatch(
            batch,
            validateWinner: adapters.validate,
            applyWinner: adapters.apply,
          ),
          throwsA(isA<WebDavSyncFailure>()),
        );
        expect(
          (await const ReaderSettingsStore().load()).fontSize,
          before.fontSize,
        );
        expect(await changeStore.cursorFor('remote'), 0);
        expect(await changeStore.recordsForDataset('reader_settings'), isEmpty);
      },
    );
  }

  test(
    'reader settings scan covers current text and navigation controls',
    () async {
      const settingsStore = ReaderSettingsStore();
      await settingsStore.save(
        const ReaderSettings(
          fontSize: 23,
          textBrightness: 72,
          dimTextInDarkMode: false,
          fontWeight: 600,
          lineHeight: 1.9,
          letterSpacing: 0.4,
          textAlignment: ReaderTextAlignment.justified,
          horizontalMargin: 21,
          topMargin: 7,
          bottomMargin: 5,
          themeId: 'night',
          pageMode: ReaderPageMode.pageCurl,
          firstLineIndent: 3,
          paragraphSpacing: 1,
          pullBookmarkEnabled: true,
          tapPageAnimationEnabled: false,
          tabletTwoPageEnabled: false,
        ),
      );
      await settingsStore.saveScrollByChapter(true);
      await settingsStore.save(
        (await settingsStore.load()).copyWith(chapterTitlePageEnabled: false),
      );
      await settingsStore.saveTapZones(
        ReaderTapZones.defaults.withAction(0, ReaderTapZoneAction.nextChapter),
      );
      await const PagedImageReaderSettingsStore().saveBackground(
        ImageReaderBackground.gray,
      );

      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );

      final records = await changeStore.recordsForDataset('reader_settings');
      final values = <String, Object?>{
        for (final record in records)
          record.entityKey: record.payload?['value'],
      };
      expect(values['font_size'], 23.0);
      expect(values['text_brightness'], 72);
      expect(values['font_weight'], 600);
      expect(values['letter_spacing'], 0.4);
      expect(values['text_alignment'], 'justified');
      expect(values['page_mode'], 'pageCurl');
      expect(values['scroll_by_chapter'], isTrue);
      expect(values['txt_chapter_title_page'], isFalse);
      expect(values['tap_zones'], contains('nextChapter'));
      expect(values['image_reader_background'], 'gray');
    },
  );

  test(
    'remote reader settings are validated and normalized before saving',
    () async {
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );

      await database.transaction(
        (txn) => adapter.apply(
          txn,
          const SyncOperation(
            dataset: 'reader_settings',
            recordId: 'font_size',
            entityKey: 'font_size',
            hlc: '1000-0000-remote',
            deleted: false,
            payload: {'value': 99},
          ),
        ),
      );
      await database.transaction(
        (txn) => adapter.apply(
          txn,
          const SyncOperation(
            dataset: 'reader_settings',
            recordId: 'page_mode',
            entityKey: 'page_mode',
            hlc: '1001-0000-remote',
            deleted: false,
            payload: {'value': 'verticalScroll'},
          ),
        ),
      );

      final restored = await const ReaderSettingsStore().load();
      expect(restored.fontSize, ReaderSettings.maxFontSize);
      expect(restored.pageMode, ReaderPageMode.verticalScroll);
    },
  );

  test(
    'an invalid setting rejects the whole remote batch before commit',
    () async {
      const settingsStore = ReaderSettingsStore();
      final before = await settingsStore.load();
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      final adapters = MetadataSyncAdapters(
        store: changeStore,
        database: () async => database,
        registeredAdapters: [adapter],
      );
      final batch = SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '2000-0000-remote',
        operations: const [
          SyncOperation(
            dataset: 'reader_settings',
            recordId: 'font_size',
            entityKey: 'font_size',
            hlc: '2000-0000-remote',
            deleted: false,
            payload: {'value': 27},
          ),
          SyncOperation(
            dataset: 'reader_settings',
            recordId: 'page_mode',
            entityKey: 'page_mode',
            hlc: '2001-0000-remote',
            deleted: false,
            payload: {'value': 'not-a-page-mode'},
          ),
        ],
      );

      await expectLater(
        changeStore.applyRemoteBatch(
          batch,
          validateWinner: adapters.validate,
          applyWinner: adapters.apply,
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (failure) => failure.code,
            'code',
            WebDavSyncErrorCode.corruptRemoteData,
          ),
        ),
      );

      expect((await settingsStore.load()).fontSize, before.fontSize);
      expect(await changeStore.recordsForDataset('reader_settings'), isEmpty);
      expect(await changeStore.cursorFor('remote'), 0);
    },
  );

  test('disabled scopes still reject corrupt known records', () async {
    final adapter = ReaderSettingsSyncAdapter(
      changeStore,
      () async => database,
    );
    final adapters = MetadataSyncAdapters(
      store: changeStore,
      database: () async => database,
      registeredAdapters: [adapter],
    );
    final batch = SyncBatch.create(
      deviceId: 'remote',
      sequence: 1,
      createdHlc: '2000-0000-remote',
      operations: const [
        SyncOperation(
          dataset: 'reader_settings',
          recordId: 'page_mode',
          entityKey: 'page_mode',
          hlc: '2000-0000-remote',
          deleted: false,
          payload: {'value': 'not-a-page-mode'},
        ),
      ],
    );

    await expectLater(
      changeStore.applyRemoteBatch(
        batch,
        validateWinner: adapters.validate,
        applyWinner: (txn, operation) => adapters.apply(
          txn,
          operation,
          scope: const WebDavSyncScope(readerSettings: false),
        ),
      ),
      throwsA(isA<WebDavSyncFailure>()),
    );

    expect(await changeStore.recordsForDataset('reader_settings'), isEmpty);
    expect(await changeStore.cursorFor('remote'), 0);
  });

  test('old corrupt mirrors fail validation before materialization', () async {
    await database.insert('sync_records', {
      'dataset': 'reader_settings',
      'record_id': 'page_mode',
      'entity_key': 'page_mode',
      'payload_json': '{"value":"not-a-page-mode"}',
      'hlc': '1000-0000-old-client',
      'deleted': 0,
      'dirty': 0,
    });
    final before = await const ReaderSettingsStore().load();
    final adapters = MetadataSyncAdapters(
      store: changeStore,
      database: () async => database,
      registeredAdapters: [
        ReaderSettingsSyncAdapter(changeStore, () async => database),
      ],
    );

    await expectLater(
      adapters.scan(
        const WebDavSyncScope(),
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000),
      ),
      throwsA(isA<WebDavSyncFailure>()),
    );

    expect(
      (await const ReaderSettingsStore().load()).pageMode,
      before.pageMode,
    );
    expect(
      await changeStore.getState('locally_observed:reader_settings:page_mode'),
      isNull,
    );
  });

  test(
    'unknown reader settings remain queued for a future client upgrade',
    () async {
      const futureValueId = 'future_text_rendering';
      const futureTombstoneId = 'future_page_effect';
      final oldAdapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      final oldAdapters = MetadataSyncAdapters(
        store: changeStore,
        database: () async => database,
        registeredAdapters: [oldAdapter],
      );

      await changeStore.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'future-client',
          sequence: 1,
          createdHlc: '2000-0000-future-client',
          operations: const [
            SyncOperation(
              dataset: 'reader_settings',
              recordId: futureValueId,
              entityKey: futureValueId,
              hlc: '2000-0000-future-client',
              deleted: false,
              payload: {'value': 'subpixel'},
            ),
            SyncOperation(
              dataset: 'reader_settings',
              recordId: futureTombstoneId,
              entityKey: futureTombstoneId,
              hlc: '2001-0000-future-client',
              deleted: true,
            ),
          ],
        ),
        validateWinner: oldAdapters.validate,
        applyWinner: oldAdapters.apply,
      );

      for (final recordId in const [futureValueId, futureTombstoneId]) {
        expect(
          await changeStore.getState(
            'locally_observed:reader_settings:$recordId',
          ),
          isNull,
        );
      }

      final upgradedAdapter = _FutureReaderSettingsAdapter();
      final upgradedAdapters = MetadataSyncAdapters(
        store: changeStore,
        database: () async => database,
        registeredAdapters: [upgradedAdapter],
      );
      await upgradedAdapters.scan(
        const WebDavSyncScope(),
        HybridLogicalClock(deviceId: 'upgraded', nowMillis: () => 3000),
      );

      expect(upgradedAdapter.values[futureValueId], 'subpixel');
      expect(upgradedAdapter.deleted, contains(futureTombstoneId));
      expect(
        await changeStore.getState(
          'locally_observed:reader_settings:$futureValueId',
        ),
        '2000-0000-future-client',
      );
      expect(
        await changeStore.getState(
          'locally_observed:reader_settings:$futureTombstoneId',
        ),
        '2001-0000-future-client',
      );
    },
  );

  test(
    'custom themes sync colors but never expose local image paths',
    () async {
      const theme = ReaderCustomTheme(
        id: 'custom:paper',
        name: 'Paper',
        background: Color(0xFFF0E6D2),
        text: Color(0xFF30271F),
        controlBar: Color(0xFFE2D4BD),
        backgroundImagePath: '/private/device/paper.png',
        backgroundImageOpacity: 0.4,
      );
      await const ReaderCustomThemeStore().saveAll(const [theme]);
      await const ReaderThemeOrderStore().save(const ['night', 'custom:paper']);
      final adapter = ReaderThemesSyncAdapter(changeStore);

      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );

      final records = await changeStore.recordsForDataset('reader_themes');
      final themeRecord = records.singleWhere(
        (record) => record.entityKey == 'custom:paper',
      );
      expect(themeRecord.payload, isNot(contains('backgroundImagePath')));
      expect(themeRecord.payload, isNot(contains('background_image_path')));
      expect(
        records
            .singleWhere((record) => record.entityKey == 'theme_order')
            .payload,
        {
          'value': ['night', 'custom:paper'],
        },
      );
    },
  );

  test(
    'per-book image directions never expose reversible book identities',
    () async {
      final bookId = await database.insert('books', {
        'title': 'Comic',
        'author': 'Author',
        'filePath': '',
        'format': 'source',
        'importDate': 1,
        'source_id': 'https://reader.example/source?token=source-secret',
        'source_book_id': 'https://reader.example/book?id=1&token=book-secret',
      });
      await const PagedImageReaderSettingsStore().saveDirection(
        bookId,
        ImageReaderDirection.rtl,
      );
      await const PagedImageReaderSettingsStore().saveDirectionForKey(
        'comic:https://reader.example/book?token=comic-secret',
        ImageReaderDirection.rtl,
      );
      await changeStore.recordLocal(
        dataset: 'reader_settings',
        recordId: 'image_direction:legacy',
        entityKey: 'book:https://reader.example/book?token=legacy-secret',
        payload: const {'value': 'rtl'},
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'legacy', nowMillis: () => 500),
      );
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );

      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );

      final records = await changeStore.recordsForDataset('reader_settings');
      expect(
        records.where(
          (record) => record.recordId.startsWith('image_direction:'),
        ),
        isEmpty,
      );
      final encoded = records.map((record) => record.toOperation().toJson());
      expect('$encoded', isNot(contains('source-secret')));
      expect('$encoded', isNot(contains('book-secret')));
      expect('$encoded', isNot(contains('comic-secret')));
      expect('$encoded', isNot(contains('legacy-secret')));
    },
  );

  test(
    'clean remote image directions remain deferred for old clients',
    () async {
      const entityKey = 'book:source:missing-source:missing-book';
      final recordId =
          'image_direction:${stableRecordId('direction', entityKey)}';
      final adapter = ReaderSettingsSyncAdapter(
        changeStore,
        () async => database,
      );
      final adapters = MetadataSyncAdapters(
        store: changeStore,
        database: () async => database,
        registeredAdapters: [adapter],
      );

      await changeStore.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: '2000-0000-remote',
          operations: [
            SyncOperation(
              dataset: 'reader_settings',
              recordId: recordId,
              entityKey: entityKey,
              hlc: '2000-0000-remote',
              deleted: false,
              payload: const {'value': 'rtl'},
            ),
          ],
        ),
        validateWinner: adapters.validate,
        applyWinner: adapters.apply,
      );
      await adapters.scan(
        const WebDavSyncScope(),
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
      );

      final retained = (await changeStore.recordsForDataset(
        'reader_settings',
      )).singleWhere((record) => record.recordId == recordId);
      expect(retained.dirty, isFalse);
      expect(
        await changeStore.getState(
          'locally_observed:reader_settings:$recordId',
        ),
        isNull,
      );
    },
  );

  test(
    'remote custom theme updates preserve an existing local image',
    () async {
      const local = ReaderCustomTheme(
        id: 'custom:paper',
        name: 'Old',
        background: Color(0xFFFFFFFF),
        text: Color(0xFF000000),
        controlBar: Color(0xFFEEEEEE),
        backgroundImagePath: '/private/device/paper.png',
      );
      await const ReaderCustomThemeStore().save(local);
      final adapter = ReaderThemesSyncAdapter(changeStore);

      await database.transaction(
        (txn) => adapter.apply(
          txn,
          SyncOperation(
            dataset: 'reader_themes',
            recordId: stableRecordId('reader_theme', 'custom:paper'),
            entityKey: 'custom:paper',
            hlc: '1000-0000-remote',
            deleted: false,
            payload: const {
              'id': 'custom:paper',
              'name': 'New',
              'background': 0xFFF7EEDD,
              'text': 0xFF211A15,
              'controlBar': 0xFFEADCC6,
              'backgroundImageOpacity': 0.3,
            },
          ),
        ),
      );

      final restored = (await const ReaderCustomThemeStore().loadAll()).single;
      expect(restored.name, 'New');
      expect(restored.backgroundImagePath, '/private/device/paper.png');
    },
  );

  test(
    'replacement rules round-trip as opt-in user data with tombstones',
    () async {
      final service = ReplaceRuleService();
      addTearDown(service.close);
      await service.saveAll(const [
        ReplaceRule(
          id: 'rule-1',
          name: 'Clean spacing',
          pattern: r'\s+',
          replacement: ' ',
        ),
      ]);
      final adapter = ReplaceRulesSyncAdapter(changeStore, service: service);
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
      );

      final record = (await changeStore.recordsForDataset(
        'replace_rules',
      )).single;
      expect(record.entityKey, 'rule-1');
      expect(record.payload?['pattern'], r'\s+');

      await database.transaction(
        (txn) => adapter.apply(
          txn,
          SyncOperation(
            dataset: 'replace_rules',
            recordId: record.recordId,
            entityKey: 'rule-1',
            hlc: '2000-0000-remote',
            deleted: true,
            payload: record.payload,
          ),
        ),
      );
      expect(service.rules, isEmpty);
    },
  );

  test(
    'remote replacement rule order remains live in the current process',
    () async {
      final service = ReplaceRuleService();
      addTearDown(service.close);
      final adapter = ReplaceRulesSyncAdapter(changeStore, service: service);

      Future<void> applyRule(String id, int order) => database.transaction(
        (txn) => adapter.apply(
          txn,
          SyncOperation(
            dataset: 'replace_rules',
            recordId: stableRecordId('replace_rule', id),
            entityKey: id,
            hlc: '200$order-0000-remote',
            deleted: false,
            payload: {
              'id': id,
              'name': id,
              'pattern': id,
              'replacement': '',
              'isEnabled': true,
              'isRegex': false,
              'scopeTitle': false,
              'scopeContent': true,
              'order': order,
            },
          ),
        ),
      );

      await applyRule('later', 10);
      await applyRule('earlier', 1);

      expect(service.rules.map((rule) => rule.id), ['earlier', 'later']);
    },
  );

  test(
    'corrupt local theme JSON blocks sync without emitting tombstones',
    () async {
      const raw = '{not valid theme json';
      await changeStore.recordLocal(
        dataset: 'reader_themes',
        recordId: stableRecordId('reader_theme', 'custom:paper'),
        entityKey: 'custom:paper',
        payload: const {
          'id': 'custom:paper',
          'name': 'Backup',
          'background': 0xFFFFFFFF,
          'text': 0xFF000000,
          'controlBar': 0xFFEEEEEE,
          'backgroundImageOpacity': 0.2,
        },
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'remote', nowMillis: () => 1000),
      );
      await changeStore.markUploaded(await changeStore.dirtyRecords());
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(ReaderCustomThemeStore.storageKey, raw);

      await expectLater(
        ReaderThemesSyncAdapter(
          changeStore,
        ).scan(HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000)),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (failure) => failure.code,
            'code',
            WebDavSyncErrorCode.localDataCorrupt,
          ),
        ),
      );

      expect(preferences.getString(ReaderCustomThemeStore.storageKey), raw);
      final record = (await changeStore.recordsForDataset(
        'reader_themes',
      )).single;
      expect(record.deleted, isFalse);
      expect(record.dirty, isFalse);
    },
  );

  test(
    'replacement rules without stable IDs block sync without tombstones',
    () async {
      const raw = '[{"name":"Broken","pattern":"x","replacement":""}]';
      await changeStore.recordLocal(
        dataset: 'replace_rules',
        recordId: stableRecordId('replace_rule', 'rule-1'),
        entityKey: 'rule-1',
        payload: const {
          'id': 'rule-1',
          'name': 'Backup',
          'pattern': 'x',
          'replacement': 'y',
          'isEnabled': true,
          'isRegex': false,
          'scopeTitle': false,
          'scopeContent': true,
          'order': 0,
        },
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'remote', nowMillis: () => 1000),
      );
      await changeStore.markUploaded(await changeStore.dirtyRecords());
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(ReplaceRuleService.preferenceKey, raw);

      await expectLater(
        ReplaceRulesSyncAdapter(
          changeStore,
        ).scan(HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000)),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (failure) => failure.code,
            'code',
            WebDavSyncErrorCode.localDataCorrupt,
          ),
        ),
      );

      expect(preferences.getString(ReplaceRuleService.preferenceKey), raw);
      final record = (await changeStore.recordsForDataset(
        'replace_rules',
      )).single;
      expect(record.deleted, isFalse);
      expect(record.dirty, isFalse);
    },
  );
}

class _FutureReaderSettingsAdapter implements MetadataSyncAdapter {
  final Map<String, Object?> values = <String, Object?>{};
  final Set<String> deleted = <String>{};

  @override
  String get dataset => 'reader_settings';

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.deleted) {
      deleted.add(operation.entityKey);
    } else {
      values[operation.entityKey] = operation.payload?['value'];
    }
    return true;
  }

  @override
  Future<void> scan(HybridLogicalClock clock) async {}

  @override
  Future<void> validate(SyncOperation operation) async {}
}
