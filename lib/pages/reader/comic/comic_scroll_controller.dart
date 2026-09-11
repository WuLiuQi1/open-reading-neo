import 'package:flutter/material.dart';

/// Pixel geometry shared by comic layout, progress and deliberate navigation.
/// Corrections are applied before layout, so a changed chapter window cannot
/// recycle the visible page using an obsolete offset first.
class ComicScrollController extends ScrollController {
  List<Key> _keys = const [];
  List<double> _offsets = const [0];
  Map<Key, int> _indices = const {};
  double _pendingCorrection = 0;
  double _initialOffset = 0;

  double offsetOf(int index) => _offsets[index];
  double extentOf(int index) => _offsets[index + 1] - _offsets[index];
  int? indexOf(Key key) => _indices[key];

  int indexAt(double offset) {
    var low = 0;
    var high = _keys.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_offsets[middle + 1] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low.clamp(0, _keys.length - 1);
  }

  void updateGeometry(
    List<Key> keys,
    List<double> extents, {
    required int initialIndex,
  }) {
    final pixels = hasClients ? position.pixels + _pendingCorrection : 0.0;
    var anchor = _keys.isEmpty ? null : indexAt(pixels);
    // If the partially visible loader itself changes height, retain the next
    // visible page rather than pushing the content already being read away.
    if (anchor != null &&
        hasClients &&
        anchor + 1 < _keys.length &&
        pixels > _offsets[anchor] &&
        _offsets[anchor + 1] < pixels + position.viewportDimension) {
      final newIndex = keys.indexOf(_keys[anchor]);
      if (newIndex >= 0 && extents[newIndex] != extentOf(anchor)) {
        anchor++;
      }
    }
    final anchorKey = anchor == null ? null : _keys[anchor];
    final within = anchor == null ? 0.0 : pixels - _offsets[anchor];
    final offsets = <double>[0];
    for (final extent in extents) {
      offsets.add(offsets.last + extent);
    }
    _keys = keys;
    _offsets = offsets;
    _indices = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    if (!hasClients) {
      _initialOffset = offsetOf(initialIndex.clamp(0, keys.length - 1));
      return;
    }
    final newIndex = _indices[anchorKey];
    if (newIndex != null) {
      // Retain a pixel within the same page, including negative overscroll.
      // A shrinking placeholder cannot retain a pixel that no longer exists.
      final local = within < extentOf(newIndex)
          ? within
          : (extentOf(newIndex) - 1).clamp(0.0, double.infinity);
      _pendingCorrection += offsetOf(newIndex) + local - pixels;
    }
  }

  double _takeCorrection() {
    final correction = _pendingCorrection;
    _pendingCorrection = 0;
    return correction;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ComicScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: _initialOffset,
    takeCorrection: _takeCorrection,
  );
}

class _ComicScrollPosition extends ScrollPositionWithSingleContext {
  _ComicScrollPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required super.initialPixels,
    required this.takeCorrection,
  });

  final double Function() takeCorrection;
  bool _anchored = false;

  @override
  bool applyViewportDimension(double viewportDimension) {
    final accepted = super.applyViewportDimension(viewportDimension);
    final correction = takeCorrection();
    if (correction == 0) return accepted;
    correctBy(correction);
    _anchored = true;
    return false;
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    if (_anchored) {
      _anchored = false;
      return true;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}
