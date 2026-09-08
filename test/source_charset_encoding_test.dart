import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_encoding_api.dart';
import 'package:xxread/book_sources/source_engine/source_response_codec.dart';

void main() {
  group('Chinese source request encoding', () {
    test('uses Java replacement bytes outside GB2312 and GBK repertoires', () {
      expect(SourceResponseCodec.encode('€😀', 'gb2312'), [0x3f, 0x3f]);
      expect(SourceResponseCodec.encode('⊕', 'gb2312'), [0x3f]);
      expect(SourceResponseCodec.encode('―・', 'gb2312'), [
        0xa1,
        0xaa,
        0xa1,
        0xa4,
      ]);
      expect(SourceResponseCodec.encode('😀', 'gbk'), [0x3f]);
      expect(SourceResponseCodec.encode('€', 'gbk'), [0xa2, 0xe3]);
    });

    test('encodes GB18030 BMP, supplementary, and private-use characters', () {
      expect(SourceResponseCodec.encode('\u0080', 'gb18030'), [
        0x81,
        0x30,
        0x81,
        0x30,
      ]);
      expect(SourceResponseCodec.encode('😀', 'gb18030'), [
        0x94,
        0x39,
        0xfc,
        0x36,
      ]);
      expect(SourceResponseCodec.encode('\ue000', 'gb18030'), [0xaa, 0xa1]);
      expect(SourceResponseCodec.encode('\ue7c7', 'gb18030'), [
        0x81,
        0x35,
        0xf4,
        0x37,
      ]);
      expect(SourceResponseCodec.encode('\ue81e', 'gb18030'), [
        0x82,
        0x35,
        0x90,
        0x37,
      ]);
      expect(SourceResponseCodec.encode('\u9fb4', 'gb18030'), [0xfe, 0x59]);
    });

    test('shares exact Chinese charset bytes with script encoding helpers', () {
      const api = SourceScriptEncodingApi();

      expect(api.handle('strToBytes', ['€😀', 'GB2312']), [0x3f, 0x3f]);
      expect(api.handle('strToBytes', ['😀', 'GB18030']), [
        0x94,
        0x39,
        0xfc,
        0x36,
      ]);
      expect(api.handle('formEncode', ['😀', 'GB18030']), '%94%39%FC%36');
      expect(
        api.handle('bytesToStr', [
          const [0x94, 0x39, 0xfc, 0x36],
          'GB18030',
        ]),
        '😀',
      );
    });

    test('decodes GB18030 four-byte responses', () {
      final headers = Headers.fromMap({
        'content-type': ['text/plain; charset=gb18030'],
      });

      expect(
        SourceResponseCodec.decode(
          const [0x94, 0x39, 0xfc, 0x36],
          'utf-8',
          headers,
        ),
        '😀',
      );
    });
  });
}
