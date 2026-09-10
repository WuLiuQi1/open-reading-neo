import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';

void main() {
  test(
    'FULL image style does not turn the Yiove classical text source into manga',
    () {
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': '古典文学（优）',
        'bookSourceGroup': '小说源',
        'bookSourceType': 0,
        'bookSourceUrl': 'http://yz4.chaoxing.com',
        'ruleToc': {'chapterList': 'tag.li'},
        'ruleContent': {
          'content': 'class.ztArtCon@tag.p@html||body@html',
          'imageStyle': 'FULL',
        },
      });

      expect(source.isImageSource, isFalse);
      expect(source.effectiveBookType, 8);
    },
  );

  test('declared and legacy image-rule sources still route to manga', () {
    final declared = ReadingSourceConfig.fromJson({
      'bookSourceName': '明确图片源',
      'bookSourceType': 2,
      'bookSourceUrl': 'https://comic.example',
      'ruleToc': {'chapterList': '.chapter'},
      'ruleContent': {'content': 'body@html', 'imageStyle': 'FULL'},
    });
    final legacy = ReadingSourceConfig.fromJson({
      'bookSourceName': '旧图片源',
      'bookSourceType': 0,
      'bookSourceUrl': 'https://legacy-comic.example',
      'ruleToc': {'chapterList': '.chapter'},
      'ruleContent': {'content': 'img@data-src'},
    });

    for (final source in [declared, legacy]) {
      expect(source.isImageSource, isTrue);
      expect(source.effectiveBookType, 64);
    }
  });
}
