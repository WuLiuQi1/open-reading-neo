import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

// This fixture focuses on the real discovery content, tablet toolbar, and
// progressive backdrop. The app shell's floating navigation is intentionally
// omitted instead of drawing a fake replacement or widening product injection.

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_sources_page.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/widgets/home_tablet_toolbar.dart';
import 'package:xxread/pages/home/widgets/home_tablet_top_backdrop.dart';
import 'package:xxread/utils/layout_helper.dart';
import 'package:xxread/utils/ui_style.dart';

final Map<String, Uri> _previewCoverUris = {};
Directory? _previewCacheRoot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final screenshotDirectory = Platform.environment['DISCOVERY_SCREENSHOT_DIR'];

  setUpAll(() async {
    if (screenshotDirectory == null) return;
    final fontPath = Platform.environment['TABLET_PREVIEW_FONT'];
    if (fontPath == null) return;
    final fontBytes = File(fontPath).readAsBytes();
    final text = FontLoader('TabletPreview');
    text.addFont(fontBytes.then(ByteData.sublistView));
    await text.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();

    _previewCacheRoot = await Directory.systemTemp.createTemp(
      'open-reading-discovery-covers-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _previewCacheRoot!.path,
        );
    final coverDirectory = Directory(
      '${_previewCacheRoot!.path}/${SourceCoverCache.directoryName}',
    );
    await coverDirectory.create(recursive: true);
    for (var index = 0; index < _previewTitles.length; index++) {
      final title = _previewTitles[index];
      final uri = Uri.parse(
        'https://preview.example/${Uri.encodeComponent(title)}.png',
      );
      final bytes = await _createPreviewCover(title, index);
      final key = sha256
          .convert(utf8.encode('${uri.toString()}\u0000'))
          .toString();
      await File(
        '${coverDirectory.path}/default:$key.img',
      ).writeAsBytes(bytes, flush: true);
      _previewCoverUris[title] = uri;
    }
  });

  tearDownAll(() async {
    if (_previewCacheRoot == null) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await _previewCacheRoot!.delete(recursive: true);
    _previewCacheRoot = null;
    _previewCoverUris.clear();
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'tablet discovery preview uses a sidebar and falls back in compact space',
    (tester) async {
      try {
        final sources = List.generate(24, _previewSource, growable: false);
        SharedPreferences.setMockInitialValues({
          'open_reading_book_sources_v1': jsonEncode(
            sources.map((source) => source.toJson()).toList(growable: false),
          ),
        });
        final registry = BookSourceRegistry();
        final client = _PreviewDiscoveryClient();
        final controller = BookSourcesPageController();
        final boundaryKey = GlobalKey();
        addTearDown(client.close);
        addTearDown(controller.dispose);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        if (screenshotDirectory != null) {
          await tester.runAsync(_prewarmPreviewCovers);
        }

        Future<void> pumpPreview(
          Size size, {
          Brightness brightness = Brightness.light,
          double textScale = 1,
          double keyboard = 0,
        }) async {
          await tester.binding.setSurfaceSize(size);
          final mediaQuery = MediaQueryData(
            size: size,
            devicePixelRatio: 1,
            viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            textScaler: TextScaler.linear(textScale),
          );
          final metrics = HomeMobileChromeMetrics.fromMediaQuery(
            mediaQuery,
            navigationAtTop: true,
            topBarContentHeight: (mediaQuery.textScaler.scale(30) + 12).clamp(
              60.0,
              double.infinity,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(
                brightness: brightness,
                colorSchemeSeed: const Color(0xFF356C88),
                fontFamily: screenshotDirectory == null
                    ? null
                    : 'TabletPreview',
                extensions: const [
                  UiStyleThemeExtension(style: AppUiStyle.glass),
                ],
              ),
              home: MediaQuery(
                data: mediaQuery,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: Scaffold(
                    body: HomeMobileChromeScope(
                      metrics: metrics,
                      child: Stack(
                        children: [
                          BookSourcesPage(
                            key: const ValueKey(
                              'tablet-discovery-preview-page',
                            ),
                            client: client,
                            registry: registry,
                            controller: controller,
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: HomeTabletTopBackdrop(
                              height: metrics.pageTopPadding,
                            ),
                          ),
                          Positioned(
                            top: metrics.toolbarTopInset,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: HomeTabletToolbar(
                                title: '发现',
                                height: metrics.topBarContentHeight,
                                horizontalPadding:
                                    LayoutHelper.tabletPageInsetForWidth(
                                      size.width,
                                    ),
                              ),
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
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> capture(String name, {bool requireCover = true}) async {
          if (screenshotDirectory == null) return;
          final rawImages = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .toList(growable: false);
          if (requireCover) {
            expect(
              rawImages,
              isNotEmpty,
              reason: 'A preview must render at least one real cover image.',
            );
          }
          for (final rawImage in rawImages) {
            expect(
              rawImage.image,
              isNotNull,
              reason: 'Every visible preview cover must finish decoding.',
            );
          }
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(screenshotDirectory).create(recursive: true);
            await File(
              '$screenshotDirectory/$name.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        void expectSidebarLayout() {
          final sidebar = find.byKey(const Key('bookSourceTabletSidebar'));
          final panel = find.byKey(const Key('bookSourceTabletSidebarPanel'));
          final header = find.byKey(const Key('bookSourceTabletHeader'));
          expect(sidebar, findsOneWidget);
          expect(panel, findsOneWidget);
          expect(header, findsOneWidget);
          expect(
            tester.getTopLeft(panel).dy,
            closeTo(tester.getTopLeft(header).dy, 0.1),
          );
          expect(
            tester.getTopRight(panel).dx,
            lessThan(tester.getTopLeft(header).dx),
          );
          final sourceList = tester.widget<CustomScrollView>(
            find.byKey(const PageStorageKey('bookSourceTabletSourceList')),
          );
          expect(
            sourceList.controller!.position.maxScrollExtent,
            greaterThan(0),
          );
        }

        await pumpPreview(const Size(1194, 834));
        expectSidebarLayout();
        final sidebarSearch = find.byKey(
          const Key('bookSourceTabletSourceSearch'),
        );
        await tester.enterText(sidebarSearch, '万卷');
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bookSourceTabletSource-preview-0')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(sidebarSearch, '');
        await tester.pumpAndSettle();

        expect(find.text('全部书源'), findsOneWidget);
        expect(find.text('万卷书城'), findsWidgets);
        expect(find.text('万卷书城 · 编辑精选'), findsOneWidget);
        expect(find.text('长安十二时辰'), findsOneWidget);
        final sidebarScroll = tester
            .widget<CustomScrollView>(
              find.byKey(const PageStorageKey('bookSourceTabletSourceList')),
            )
            .controller!;
        final contentScroll = tester
            .widget<CustomScrollView>(
              find.byKey(const Key('bookSourceDiscoverScrollView')),
            )
            .controller!;
        final contentOffset = contentScroll.offset;
        sidebarScroll.jumpTo(120);
        await tester.pump();
        expect(sidebarScroll.offset, 120);
        expect(contentScroll.offset, contentOffset);
        sidebarScroll.jumpTo(0);
        await tester.pump();
        await capture('tablet-discovery-landscape');

        await tester.tap(find.text('分类'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bookSourceDiscoveryChannel-preview-0-recent')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('bookSourceTabletBookGrid')),
          findsOneWidget,
        );
        expect(find.text('平凡的世界'), findsOneWidget);
        await capture('tablet-discovery-categories');

        await tester.tap(find.text('推荐'));
        await tester.pumpAndSettle();
        expect(find.text('长安十二时辰'), findsOneWidget);

        await pumpPreview(const Size(834, 1194));
        expectSidebarLayout();
        await capture('tablet-discovery-portrait');

        await pumpPreview(const Size(1194, 834), brightness: Brightness.dark);
        expectSidebarLayout();
        await capture('tablet-discovery-landscape-dark');

        await pumpPreview(const Size(600, 960));
        expect(find.byKey(const Key('bookSourceTabletSidebar')), findsNothing);
        expect(
          find.byKey(const Key('bookSourceDiscoverScopeControl')),
          findsOneWidget,
        );
        expect(find.text('长安十二时辰'), findsOneWidget);
        await capture('tablet-discovery-compact');

        await pumpPreview(const Size(834, 1194), textScale: 3);
        expect(find.byKey(const Key('bookSourceTabletSidebar')), findsNothing);
        expect(
          find.byKey(const Key('bookSourceDiscoverScopeControl')),
          findsOneWidget,
        );
        expect(find.text('长安十二时辰'), findsOneWidget);
        await tester.tap(find.text('分类'));
        await tester.pumpAndSettle();
        expect(find.text('平凡的世界'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('tablet-discovery-accessibility');

        await pumpPreview(const Size(1194, 600), keyboard: 300);
        expectSidebarLayout();
        expect(
          find.byKey(const Key('bookSourceTabletSourceSearch')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture('tablet-discovery-keyboard', requireCover: false);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

class _PreviewDiscoveryClient extends BookSourceClient {
  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source, {
    void Function(BookSourceDiscoveryPage)? onCached,
  }) async {
    final index = int.parse(source.id.split('-').last);
    const featuredTitles = _featuredTitles;
    return BookSourceDiscoveryPage(
      sections: [
        BookSourceDiscoverySection(
          id: '${source.id}-editors-picks',
          title: '${source.name} · 编辑精选',
          items: List.generate(
            featuredTitles.length,
            (bookIndex) => _book(
              '${source.id}-featured-$bookIndex',
              featuredTitles[(index + bookIndex) % featuredTitles.length],
              author: [
                '马伯庸',
                '汪曾祺',
                '毛姆',
                '小川糸',
                '阿西莫夫',
                '沈从文',
              ][(index + bookIndex) % featuredTitles.length],
            ),
            growable: false,
          ),
        ),
      ],
    );
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source, {
    void Function(List<BookSourceCategory>)? onCached,
  }) async {
    return const [
      BookSourceCategory(id: 'recent', name: '最近更新'),
      BookSourceCategory(id: 'literature', name: '文学小说'),
      BookSourceCategory(id: 'history', name: '历史人文'),
      BookSourceCategory(id: 'science-fiction', name: '科幻世界'),
      BookSourceCategory(id: 'completed', name: '完本精选'),
    ];
  }

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
    void Function(BookSourceSearchPage)? onCached,
  }) async {
    final items = [
      _book('${source.id}-browse-1', '平凡的世界', author: '路遥'),
      _book('${source.id}-browse-2', '献给阿尔吉侬的花束', author: '丹尼尔·凯斯'),
      _book('${source.id}-browse-3', '万历十五年', author: '黄仁宇'),
    ];
    return BookSourceSearchPage(
      items: items,
      page: 1,
      pageSize: items.length,
      total: items.length,
      hasMore: false,
    );
  }
}

RegisteredBookSource _previewSource(int index) {
  const names = [
    '万卷书城',
    '银河阅读',
    '长风文学',
    '栖霞书屋',
    '青灯小说',
    '云端藏书',
    '远山书屋',
    '星河文库',
  ];
  final name = index < names.length ? names[index] : '中文精选书源 ${index + 1}';
  return RegisteredBookSource(
    id: 'preview-$index',
    name: name,
    description: '收录文学、历史与科幻作品',
    manifestUrl: Uri.parse('https://source-${index + 1}.example/source.json'),
    apiBaseUrl: Uri.parse('https://source-${index + 1}.example/api/'),
    websiteUrl: Uri.parse('https://source-${index + 1}.example/'),
    protocolVersion: '1.1',
    languages: const ['zh-CN'],
    capabilities: const {'search', 'discover', 'categories', 'browse'},
    enabled: true,
    isFavorite: index == 0 || index == 3 || index == 7,
    groups: [index.isEven ? '文学收藏' : '综合书源'],
    addedAt: DateTime.utc(2026, 9, 7).subtract(Duration(days: index)),
  );
}

BookSourceBook _book(String id, String title, {required String author}) {
  return BookSourceBook(
    id: id,
    title: title,
    author: author,
    description: '一本适合安静阅读的作品。',
    categories: const ['文学'],
    coverUrl: _previewCoverUris[title],
    updatedAt: DateTime.utc(2026, 9, 7),
  );
}

const _featuredTitles = ['长安十二时辰', '人间草木', '月亮与六便士', '山茶文具店', '银河帝国', '边城'];

const _previewTitles = [..._featuredTitles, '平凡的世界', '献给阿尔吉侬的花束', '万历十五年'];

Future<Uint8List> _createPreviewCover(String title, int index) async {
  const colors = [
    Color(0xFF294C60),
    Color(0xFF725748),
    Color(0xFF395B4A),
    Color(0xFF5A4E78),
    Color(0xFF7B5B33),
    Color(0xFF355D70),
    Color(0xFF63444C),
    Color(0xFF3F5A68),
    Color(0xFF596141),
  ];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final background = Paint()..color = colors[index % colors.length];
  canvas.drawRect(const Rect.fromLTWH(0, 0, 360, 540), background);
  final accent = Paint()..color = const Color(0xFFE8D8B5);
  canvas.drawRect(const Rect.fromLTWH(34, 38, 4, 464), accent);
  canvas.drawRect(const Rect.fromLTWH(62, 72, 112, 3), accent);
  final titlePainter = TextPainter(
    text: TextSpan(
      text: title,
      style: const TextStyle(
        fontFamily: 'TabletPreview',
        color: Color(0xFFF8F2E7),
        fontSize: 42,
        fontWeight: FontWeight.w700,
        height: 1.42,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 244);
  titlePainter.paint(canvas, const Offset(62, 146));
  titlePainter.dispose();
  final markPainter = TextPainter(
    text: const TextSpan(
      text: 'OPEN READING',
      style: TextStyle(
        fontFamily: 'TabletPreview',
        color: Color(0xFFE8D8B5),
        fontSize: 15,
        letterSpacing: 2,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  markPainter.paint(canvas, const Offset(62, 456));
  markPainter.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(360, 540);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _prewarmPreviewCovers() async {
  for (final uri in _previewCoverUris.values) {
    final bytes = await SourceCoverCache.instance.load(uri);
    for (final width in [78, 132]) {
      final provider = ResizeImage(MemoryImage(bytes), width: width);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
      final frame = await codec.getNextFrame();
      PaintingBinding.instance.imageCache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: frame.image.clone())),
        ),
      );
      frame.image.dispose();
      codec.dispose();
    }
  }
}
