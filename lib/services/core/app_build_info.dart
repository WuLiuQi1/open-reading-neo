import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _appUpdateChannel = MethodChannel('com.niki.xxread/app_update');

Future<String> readAppReleaseBuildNumber(PackageInfo info) async {
  // Android package versionCode may contain an ABI offset. If the native
  // release identity is unavailable, never substitute that different number.
  final platformBuild = info.buildNumber.trim();
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return platformBuild;
  }

  try {
    final value = await _appUpdateChannel.invokeMethod<Object?>(
      'getReleaseBuildNumber',
    );
    final normalized = value?.toString().trim() ?? '';
    if (!RegExp(r'^[0-9]+$').hasMatch(normalized)) return '';
    final number = int.tryParse(normalized);
    return number != null && number > 0 ? number.toString() : '';
  } on PlatformException {
    return '';
  } on MissingPluginException {
    return '';
  }
}
