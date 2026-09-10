// Offscreen rendering + pixel readback diagnostic, NOT screen frame timing.
// Build a bundle, then run flutter_tester with --enable-impeller and an explicit
// --impeller-backend=metal on macOS. See the performance plan for commands.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:xxread/pages/home/widgets/home_tablet_top_backdrop.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final key = GlobalKey();
  for (final dpr in [2.0, 3.0]) {
    runApp(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: Center(
            child: OverflowBox(
              minWidth: 1194,
              maxWidth: 1194,
              minHeight: 208,
              maxHeight: 208,
              child: RepaintBoundary(
                key: key,
                child: const SizedBox(
                  width: 1194,
                  height: 208,
                  child: Stack(
                    children: [
                      Positioned.fill(child: CustomPaint(painter: _Pattern())),
                      HomeTabletTopBackdrop(height: 208),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Wait for the asynchronous shader load and its frame to complete.
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (_shaderLoaded(key)) break;
      if (attempt == 99) {
        throw StateError('Variable Gaussian shader did not load');
      }
    }
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final samples = <double>[];
    for (var frame = 0; frame < 55; frame++) {
      final watch = Stopwatch()..start();
      final image = await boundary.toImage(pixelRatio: dpr);
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      watch.stop();
      if (frame >= 5) samples.add(watch.elapsedMicroseconds / 1000);
    }
    samples.sort();
    stdout.writeln(
      'OFFSCREEN 1194x208 dpr=$dpr n=${samples.length} '
      'median=${samples[samples.length ~/ 2]}ms '
      'p90=${samples[(samples.length * .9).floor()]}ms',
    );
  }
  exit(0);
}

bool _shaderLoaded(GlobalKey key) {
  var loaded = false;
  void visit(Element element) {
    if (element.widget.key ==
        const ValueKey('tablet-variable-gaussian-filter')) {
      loaded = true;
    }
    element.visitChildren(visit);
  }

  final element = key.currentContext;
  if (element is Element) visit(element);
  return loaded;
}

class _Pattern extends CustomPainter {
  const _Pattern();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var y = 0; y < size.height; y += 8) {
      for (var x = 0; x < size.width; x += 8) {
        paint.color = (x ~/ 8 + y ~/ 8).isEven
            ? const Color(0xFFF8F8F8)
            : const Color(0xFF080808);
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 8, 8), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Pattern oldDelegate) => false;
}
