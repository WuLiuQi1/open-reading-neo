import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../utils/glass_config.dart';

/// Full-width, top-aligned backdrop with a Gaussian radius that decreases with y.
/// Controls are painted separately by the shell and never enter this filter.
class HomeTabletTopBackdrop extends StatefulWidget {
  const HomeTabletTopBackdrop({
    super.key,
    required this.height,
    this.blurEnabled = true,
  }) : assert(height >= 0);

  final double height;
  final bool blurEnabled;

  @override
  State<HomeTabletTopBackdrop> createState() => _HomeTabletTopBackdropState();
}

class _HomeTabletTopBackdropState extends State<HomeTabletTopBackdrop> {
  static const _clearTail = 16.0;
  static ui.FragmentProgram? _program;
  ui.Image? _samplerSeed;
  ui.FragmentShader? _vertical;
  ui.FragmentShader? _horizontal;
  bool _loadFailed = false;
  final _fallbackBackdrop = BackdropKey();

  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program =
          _program ??
          await ui.FragmentProgram.fromAsset(
            'shaders/tablet_variable_gaussian.frag',
          );
      _program = program;
      if (!mounted) return;
      // Configure the input sampler's filtering. ImageFilter.shader replaces
      // sampler 0's texture with the live backdrop, retaining this descriptor.
      // Linear sampling combines adjacent Gaussian taps in one GPU lookup.
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.transparent, BlendMode.src);
      final picture = recorder.endRecording();
      final ui.Image seed;
      try {
        seed = await picture.toImage(1, 1);
      } finally {
        picture.dispose();
      }
      if (!mounted) {
        seed.dispose();
        return;
      }
      setState(() {
        _samplerSeed = seed;
        _vertical = program.fragmentShader();
        _horizontal = program.fragmentShader();
        _vertical!.setImageSampler(0, seed, filterQuality: FilterQuality.low);
        _horizontal!.setImageSampler(0, seed, filterQuality: FilterQuality.low);
      });
    } catch (error, stack) {
      debugPrint('Tablet Gaussian shader could not load: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _vertical?.dispose();
    _horizontal?.dispose();
    _samplerSeed?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clearHeight = math.max(0.0, widget.height - _clearTail);
    // Keep every downward sample inside the top region: radius is 3 sigma.
    final sigma = math.min(GlassEffectConfig.appBarBlur * 2, clearHeight / 3);
    final enabled =
        widget.blurEnabled && !GlassEffectConfig.shouldDisableBlur && sigma > 0;
    Widget? filter;
    if (enabled && !_loadFailed && _vertical != null && _horizontal != null) {
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      for (final shader in [_vertical!, _horizontal!]) {
        // 0/1 (input texture size) and sampler 0 are supplied by the engine.
        shader.setFloat(2, clearHeight * pixelRatio);
        // Bound the kernel on exceptionally dense displays (3 sigma <= 384px).
        shader.setFloat(3, math.min(sigma * pixelRatio, 128));
      }
      _vertical!.setFloat(4, 0);
      _vertical!.setFloat(5, 1);
      _horizontal!.setFloat(4, 1);
      _horizontal!.setFloat(5, 0);
      filter = ClipRect(
        child: BackdropFilter(
          key: const ValueKey('tablet-variable-gaussian-filter'),
          // Vertical must run FIRST: horizontal sampling then stays on the
          // same y and uses the same sigma for both axes at each output pixel.
          filter: ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(_horizontal!),
            inner: ui.ImageFilter.shader(_vertical!),
          ),
          child: const SizedBox.expand(),
        ),
      );
    } else if (enabled &&
        (!ui.ImageFilter.isShaderFilterSupported || _loadFailed)) {
      // Older Skia backends cannot run ImageFilter.shader. Approximate the
      // radius curve with narrow native Gaussian bands, never an opacity fade.
      // Draw bottom to top to limit cross-band sampling of stronger blur.
      const bands = 32;
      filter = Stack(
        children: [
          for (var i = bands - 1; i >= 0; i--)
            Positioned(
              top: clearHeight * i / bands,
              height: clearHeight / bands,
              left: 0,
              right: 0,
              child: ClipRect(
                child: BackdropFilter(
                  backdropGroupKey: _fallbackBackdrop,
                  filter: ui.ImageFilter.blur(
                    sigmaX: sigma * (1 - (i + 0.5) / bands),
                    sigmaY: sigma * (1 - (i + 0.5) / bands),
                    tileMode: TileMode.clamp,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ],
      );
    }
    return IgnorePointer(
      child: SizedBox(
        width: double.infinity,
        height: widget.height,
        child: filter,
      ),
    );
  }
}
