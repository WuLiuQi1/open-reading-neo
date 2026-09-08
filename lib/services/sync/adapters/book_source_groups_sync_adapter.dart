import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../book_sources/services/book_source_registry.dart';
import '../sync_change_store.dart';
import '../sync_clock.dart';
import '../sync_models.dart';
import '../sync_protocol.dart';
import 'metadata_sync_adapters.dart';

/// Syncs the ordered book-source group directory as one user catalog.
///
/// Memberships remain on `book_sources`; this record carries only normalized
/// group names, including groups that currently have no members.
class BookSourceGroupsSyncAdapter implements MetadataSyncAdapter {
  BookSourceGroupsSyncAdapter(this.store, this.registry);

  static const String catalogRecordId = 'group_catalog';

  final SyncChangeStore store;
  final BookSourceRegistry registry;

  @override
  String get dataset => 'book_source_groups';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    late final List<String> groups;
    try {
      groups = await registry.loadGroupsForSync();
    } on FormatException {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'Local book source groups are damaged; sync was stopped without '
        'changing the remote catalog.',
      );
    }
    if (groups.isEmpty && (await store.recordsForDataset(dataset)).isEmpty) {
      // A fresh device has not observed a catalog yet. Publishing an empty
      // snapshot before download could beat an older remote catalog by HLC.
      return;
    }
    await store.recordLocal(
      dataset: dataset,
      recordId: catalogRecordId,
      entityKey: catalogRecordId,
      payload: {'sync_schema': 1, 'groups': groups},
      deleted: false,
      clock: clock,
    );
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId != catalogRecordId ||
        operation.entityKey != catalogRecordId ||
        operation.deleted) {
      throw _corruptGroupCatalog('The synced source group catalog is invalid.');
    }
    _validatedGroups(operation.payload);
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    await validate(operation);
    try {
      await registry.applySyncedGroups(_validatedGroups(operation.payload));
    } on FormatException {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'Local book source groups are damaged; the remote catalog was kept '
        'for a later retry.',
      );
    }
    return true;
  }

  List<String> _validatedGroups(Map<String, dynamic>? payload) {
    if (payload == null ||
        payload['sync_schema'] != 1 ||
        payload['groups'] is! List) {
      throw _corruptGroupCatalog(
        'The synced source group catalog contains invalid data.',
      );
    }
    final groups = <String>[];
    final seen = <String>{};
    for (final item in payload['groups']! as List) {
      if (item is! String ||
          item.isEmpty ||
          item != item.trim() ||
          !seen.add(item)) {
        throw _corruptGroupCatalog(
          'The synced source group catalog contains invalid group names.',
        );
      }
      groups.add(item);
    }
    return groups;
  }
}

WebDavSyncFailure _corruptGroupCatalog(String message) =>
    WebDavSyncFailure(WebDavSyncErrorCode.corruptRemoteData, message);
