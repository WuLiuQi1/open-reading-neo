import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/home/widgets/home_tablet_top_backdrop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses a continuously decreasing Gaussian radius', (tester) async {
    final blurred = await _renderBackdrop(
      tester,
      blurEnabled: true,
      pattern: _BackdropPattern.verticalEdge,
    );
    final original = await _renderBackdrop(
      tester,
      blurEnabled: false,
      pattern: _BackdropPattern.verticalEdge,
    );

    const topY = 24;
    const middleY = 92;
    const lowerY = 148;
    final topSpread = _edgeSpread(blurred, y: topY);
    final middleSpread = _edgeSpread(blurred, y: middleY);
    final lowerSpread = _edgeSpread(blurred, y: lowerY);

    expect(
      topSpread,
      greaterThanOrEqualTo(middleSpread + 2),
      reason: 'The upper edge must use a visibly larger Gaussian radius.',
    );
    expect(
      middleSpread,
      greaterThanOrEqualTo(lowerSpread + 2),
      reason: 'The Gaussian radius must keep decreasing towards the page.',
    );
    expect(
      _normalizedCenterJump(blurred, y: middleY),
      lessThan(0.14),
      reason:
          'A fixed-radius blur faded with opacity leaves a sharp copy of the '
          'original edge. The middle region must remain a real Gaussian with '
          'a radius greater than about 5px.',
    );

    for (final y in const [topY, middleY, lowerY]) {
      for (final x in const [24, 48, 272, 296]) {
        expect(
          _colorDistance(blurred.pixel(x, y), original.pixel(x, y)),
          lessThanOrEqualTo(12),
          reason:
              'Uniform areas should stay close to their original color; a '
              'heavy surface tint would make the top look like a glass slab.',
        );
      }
    }

    _expectClearTail(blurred, original);
  });

  testWidgets('blurs detail along both image axes', (tester) async {
    final blurred = await _renderBackdrop(
      tester,
      blurEnabled: true,
      pattern: _BackdropPattern.checker,
    );
    final original = await _renderBackdrop(
      tester,
      blurEnabled: false,
      pattern: _BackdropPattern.checker,
    );

    final horizontalRatio = _contrastRatio(
      blurred.pixel(20, 28),
      blurred.pixel(28, 28),
      original.pixel(20, 28),
      original.pixel(28, 28),
    );
    final verticalRatio = _contrastRatio(
      blurred.pixel(28, 20),
      blurred.pixel(28, 28),
      original.pixel(28, 20),
      original.pixel(28, 28),
    );

    expect(
      horizontalRatio,
      lessThan(0.55),
      reason: 'The variable Gaussian must blur horizontally.',
    );
    expect(
      verticalRatio,
      lessThan(0.55),
      reason: 'The variable Gaussian must blur vertically.',
    );
    _expectClearTail(blurred, original);
  });

  testWidgets('averages 1dp stripes without sparse-sampling artifacts', (
    tester,
  ) async {
    for (final dpr in [1.0, 2.0, 3.0]) {
      final verticalStripes = await _renderBackdrop(
        tester,
        blurEnabled: true,
        devicePixelRatio: dpr,
        pattern: _BackdropPattern.fineVerticalStripes,
      );
      final horizontalStripes = await _renderBackdrop(
        tester,
        blurEnabled: true,
        devicePixelRatio: dpr,
        pattern: _BackdropPattern.fineHorizontalStripes,
      );

      final horizontalSamples = [
        for (var x = 100; x <= 120; x++)
          _luminance(verticalStripes.pixel(x, 62)),
      ];
      final verticalSamples = [
        for (var y = 54; y <= 70; y++)
          _luminance(horizontalStripes.pixel(120, y)),
      ];

      for (final samples in [horizontalSamples, verticalSamples]) {
        expect(
          samples,
          everyElement(inInclusiveRange(112.0, 144.0)),
          reason:
              'A real Gaussian convolution should average alternating 1dp '
              'stripes to their middle tone.',
        );
        final darkest = samples.reduce((a, b) => a < b ? a : b);
        final lightest = samples.reduce((a, b) => a > b ? a : b);
        expect(
          lightest - darkest,
          lessThanOrEqualTo(5),
          reason:
              'Adjacent pixels must not lock onto alternating stripe phases. '
              'Large oscillation indicates sparse nearest-neighbour taps.',
        );
      }
    }
  });

  testWidgets('keeps the Gaussian profile stable across device pixel ratios', (
    tester,
  ) async {
    const sampleRows = [24, 92, 148];
    final spreadsByPixelRatio = <double, List<int>>{};

    for (final pixelRatio in const [1.0, 2.0, 3.0]) {
      final pixels = await _renderBackdrop(
        tester,
        blurEnabled: true,
        pattern: _BackdropPattern.verticalEdge,
        devicePixelRatio: pixelRatio,
      );
      spreadsByPixelRatio[pixelRatio] = [
        for (final y in sampleRows) _edgeSpread(pixels, y: y),
      ];
    }

    for (var row = 0; row < sampleRows.length; row++) {
      final logicalSpreads = [
        for (final pixelRatio in const [1.0, 2.0, 3.0])
          spreadsByPixelRatio[pixelRatio]![row],
      ];
      final smallest = logicalSpreads.reduce((a, b) => a < b ? a : b);
      final largest = logicalSpreads.reduce((a, b) => a > b ? a : b);
      expect(
        largest - smallest,
        lessThanOrEqualTo(2),
        reason:
            'The edge spread at logical y=${sampleRows[row]} must stay within '
            '2dp across DPR 1, 2, and 3. Actual: $logicalSpreads.',
      );
    }
  });

  testWidgets('clamps both texture axes on dense displays', (tester) async {
    for (final dpr in [1.0, 2.0, 3.0]) {
      for (final pattern in [
        _BackdropPattern.verticalEdge,
        _BackdropPattern.horizontalEdge,
      ]) {
        final pixels = await _renderBackdrop(
          tester,
          blurEnabled: true,
          pattern: pattern,
          devicePixelRatio: dpr,
        );
        final edgePoints = pattern == _BackdropPattern.verticalEdge
            ? const [Offset(0, 24), Offset(319, 24)]
            : const [Offset(120, 0), Offset(120, 167)];
        expect(
          _colorDistance(
            pixels.pixel(edgePoints[0].dx.toInt(), edgePoints[0].dy.toInt()),
            _dark,
          ),
          lessThanOrEqualTo(2),
        );
        expect(
          _colorDistance(
            pixels.pixel(edgePoints[1].dx.toInt(), edgePoints[1].dy.toInt()),
            _light,
          ),
          lessThanOrEqualTo(2),
        );
      }
    }
  });

  testWidgets('disabled blur is transparent and never intercepts input', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      _TestScene(
        boundaryKey: boundaryKey,
        blurEnabled: false,
        pattern: _BackdropPattern.checker,
        devicePixelRatio: 1,
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    final ignorePointer = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(HomeTabletTopBackdrop),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignorePointer.ignoring, isTrue);

    final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;
    for (final point in const [
      Offset(4, 4),
      Offset(31, 37),
      Offset(147, 82),
      Offset(279, 151),
      Offset(9, 175),
    ]) {
      final x = point.dx.toInt();
      final y = point.dy.toInt();
      expect(
        pixels.pixel(x, y),
        _checkerColorAt(x, y),
        reason: 'Disabling blur must leave the entire overlay transparent.',
      );
    }
  });
}

const _sceneSize = Size(320, 200);
const _backdropHeight = 184.0;
const _clearTailStart = 168.0;
const _edgeX = 160;
const _checkerCellSize = 8;
const _dark = Color(0xFF080808);
const _light = Color(0xFFF8F8F8);

enum _BackdropPattern {
  verticalEdge,
  horizontalEdge,
  checker,
  fineVerticalStripes,
  fineHorizontalStripes,
}

Future<_PixelBuffer> _renderBackdrop(
  WidgetTester tester, {
  required bool blurEnabled,
  required _BackdropPattern pattern,
  double devicePixelRatio = 1,
}) async {
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    _TestScene(
      boundaryKey: boundaryKey,
      blurEnabled: blurEnabled,
      pattern: pattern,
      devicePixelRatio: devicePixelRatio,
    ),
  );
  await tester.pump();

  if (blurEnabled && ui.ImageFilter.isShaderFilterSupported) {
    const filterKey = ValueKey('tablet-variable-gaussian-filter');
    for (var attempt = 0; attempt < 120; attempt++) {
      if (find.byKey(filterKey).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byKey(filterKey),
      findsOneWidget,
      reason: 'Impeller must settle on the variable Gaussian shader filter.',
    );
  }

  final pixels = (await tester.runAsync(
    () => _capture(boundaryKey, pixelRatio: devicePixelRatio),
  ))!;
  final output = Platform.environment['TABLET_BLUR_PIXELS_DIR'];
  if (output != null) {
    await tester.runAsync(() async {
      await Directory(output).create(recursive: true);
      await File(
        '$output/${pattern.name}-$devicePixelRatio-$blurEnabled.rgba',
      ).writeAsBytes(pixels.bytes);
    });
  }
  return pixels;
}

Future<_PixelBuffer> _capture(
  GlobalKey boundaryKey, {
  double pixelRatio = 1,
}) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return _PixelBuffer(
    data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    (boundary.size.width * pixelRatio).round(),
    pixelRatio,
  );
}

int _edgeSpread(_PixelBuffer pixels, {required int y}) {
  final dark = _meanLuminance(pixels, y: y, startX: 24, endX: 64);
  final light = _meanLuminance(pixels, y: y, startX: 256, endX: 296);
  final range = light - dark;
  expect(range, greaterThan(150));

  int? twentyPercentX;
  int? eightyPercentX;
  for (var x = 96; x <= 224; x++) {
    final normalized = (_luminance(pixels.pixel(x, y)) - dark) / range;
    twentyPercentX ??= normalized >= 0.2 ? x : null;
    eightyPercentX ??= normalized >= 0.8 ? x : null;
  }
  expect(twentyPercentX, isNotNull);
  expect(eightyPercentX, isNotNull);
  return eightyPercentX! - twentyPercentX!;
}

double _normalizedCenterJump(_PixelBuffer pixels, {required int y}) {
  final dark = _meanLuminance(pixels, y: y, startX: 24, endX: 64);
  final light = _meanLuminance(pixels, y: y, startX: 256, endX: 296);
  return (_luminance(pixels.pixel(_edgeX, y)) -
              _luminance(pixels.pixel(_edgeX - 1, y)))
          .abs() /
      (light - dark);
}

double _meanLuminance(
  _PixelBuffer pixels, {
  required int y,
  required int startX,
  required int endX,
}) {
  var total = 0.0;
  for (var x = startX; x < endX; x++) {
    total += _luminance(pixels.pixel(x, y));
  }
  return total / (endX - startX);
}

double _contrastRatio(
  Color blurredA,
  Color blurredB,
  Color originalA,
  Color originalB,
) {
  final blurred = (_luminance(blurredA) - _luminance(blurredB)).abs();
  final original = (_luminance(originalA) - _luminance(originalB)).abs();
  return blurred / original;
}

double _luminance(Color color) {
  return color.r * 54.213 + color.g * 182.376 + color.b * 18.411;
}

double _colorDistance(Color first, Color second) {
  return ((first.r - second.r).abs() +
          (first.g - second.g).abs() +
          (first.b - second.b).abs()) *
      255 /
      3;
}

void _expectClearTail(_PixelBuffer blurred, _PixelBuffer original) {
  for (final point in const [
    Offset(3, _clearTailStart),
    Offset(91, _clearTailStart + 5),
    Offset(159, _clearTailStart + 11),
    Offset(247, _clearTailStart + 15),
  ]) {
    expect(
      blurred.pixel(point.dx.toInt(), point.dy.toInt()),
      original.pixel(point.dx.toInt(), point.dy.toInt()),
      reason: 'The bottom 16dp must contain neither blur nor tint at $point.',
    );
  }
}

Color _checkerColorAt(int x, int y) {
  final isLight = (x ~/ _checkerCellSize + y ~/ _checkerCellSize).isEven;
  return isLight ? _light : _dark;
}

class _TestScene extends StatelessWidget {
  const _TestScene({
    required this.boundaryKey,
    required this.blurEnabled,
    required this.pattern,
    required this.devicePixelRatio,
  });

  final GlobalKey boundaryKey;
  final bool blurEnabled;
  final _BackdropPattern pattern;
  final double devicePixelRatio;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          surface: Colors.white,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: _sceneSize,
          devicePixelRatio: devicePixelRatio,
        ),
        child: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox.fromSize(
                size: _sceneSize,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: _BackdropPainter(pattern)),
                    Align(
                      alignment: Alignment.topCenter,
                      child: HomeTabletTopBackdrop(
                        height: _backdropHeight,
                        blurEnabled: blurEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.pattern);

  final _BackdropPattern pattern;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    if (pattern == _BackdropPattern.verticalEdge) {
      paint.color = _dark;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, _edgeX.toDouble(), size.height),
        paint,
      );
      paint.color = _light;
      canvas.drawRect(
        Rect.fromLTWH(_edgeX.toDouble(), 0, size.width - _edgeX, size.height),
        paint,
      );
      return;
    }

    if (pattern == _BackdropPattern.horizontalEdge) {
      paint.color = _dark;
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height / 2), paint);
      paint.color = _light;
      canvas.drawRect(
        Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2),
        paint,
      );
      return;
    }

    if (pattern == _BackdropPattern.fineVerticalStripes) {
      for (var x = 0; x < size.width; x++) {
        paint.color = x.isEven ? _dark : _light;
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 1, size.height), paint);
      }
      return;
    }

    if (pattern == _BackdropPattern.fineHorizontalStripes) {
      for (var y = 0; y < size.height; y++) {
        paint.color = y.isEven ? _dark : _light;
        canvas.drawRect(Rect.fromLTWH(0, y.toDouble(), size.width, 1), paint);
      }
      return;
    }

    for (var y = 0; y < size.height; y += _checkerCellSize) {
      for (var x = 0; x < size.width; x += _checkerCellSize) {
        paint.color = _checkerColorAt(x, y);
        canvas.drawRect(
          Rect.fromLTWH(
            x.toDouble(),
            y.toDouble(),
            _checkerCellSize.toDouble(),
            _checkerCellSize.toDouble(),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter oldDelegate) {
    return pattern != oldDelegate.pattern;
  }
}

class _PixelBuffer {
  _PixelBuffer(this.bytes, this.width, this.devicePixelRatio);

  final Uint8List bytes;
  final int width;
  final double devicePixelRatio;

  Color pixel(int x, int y) {
    // Sample the centre physical pixel of each logical pixel. This lets all
    // profile assertions remain in logical dp while the captured image and
    // shader input texture genuinely use the requested device pixel ratio.
    final physicalX = ((x + 0.5) * devicePixelRatio).floor();
    final physicalY = ((y + 0.5) * devicePixelRatio).floor();
    final offset = (physicalY * width + physicalX) * 4;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  }
}
