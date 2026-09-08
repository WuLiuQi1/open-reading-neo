import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
  final base = Uri.parse('https://books.test/');

  test('encodes search query in the configured charset and keeps escapes', () {
    final request = SourceRequestTemplate.parse(
      '/search?searchkey={{key}}&submit=%CB%D1%CB%F7,{"charset":"GBK"}',
      baseUri: base,
      variables: const {'key': '中文'},
    );
    expect(
      request.url.toString(),
      'https://books.test/search?searchkey=%D6%D0%CE%C4&submit=%CB%D1%CB%F7',
    );
  });

  test('encodes literal and interpolated form fields using GBK', () {
    final request = SourceRequestTemplate.parse(
      '/search,{"method":"POST","charset":"gbk",'
      '"body":"关键词={{key}}&p={{page}}"}',
      baseUri: base,
      variables: const {'key': '中文 空', 'page': '2'},
    );
    expect(request.body, '%B9%D8%BC%FC%B4%CA=%D6%D0%CE%C4+%BF%D5&p=2');
  });

  test('keeps GB18030 four-byte and legacy replacement bytes in requests', () {
    final gb18030 = SourceRequestTemplate.parse(
      '/search?q={{key}},{"charset":"gb18030"}',
      baseUri: base,
      variables: const {'key': '😀'},
    );
    // Uri canonicalizes escaped ASCII digits; decoding still yields the same
    // four GB18030 bytes. Form bodies preserve Java's full byte escaping.
    expect(gb18030.url.toString(), 'https://books.test/search?q=%949%FC6');
    final gb18030Form = SourceRequestTemplate.parse(
      '/search,{"method":"POST","charset":"gb18030","body":"q={{key}}"}',
      baseUri: base,
      variables: const {'key': '😀'},
    );
    expect(gb18030Form.body, 'q=%94%39%FC%36');
    final gb2312 = SourceRequestTemplate.parse(
      '/search,{"method":"POST","charset":"gb2312","body":"q={{key}}"}',
      baseUri: base,
      variables: const {'key': '€😀'},
    );
    expect(gb2312.body, 'q=%3F%3F');
    final gbk = SourceRequestTemplate.parse(
      '/search,{"method":"POST","charset":"gbk","body":"q={{key}}"}',
      baseUri: base,
      variables: const {'key': '😀'},
    );
    expect(gbk.body, 'q=%3F');
  });

  test('expands Legado page alternatives inside POST options', () {
    for (final page in [1, 2, 3]) {
      final request = SourceRequestTemplate.parse(
        '/search,{"method":"POST","charset":"gbk",'
        '"body":"searchkey={{key}}<,&page={{page}}>"}',
        baseUri: base,
        variables: {'key': '中文', 'page': '$page'},
      );
      expect(
        request.body,
        'searchkey=%D6%D0%CE%C4${page == 1 ? '' : '&page=$page'}',
      );
    }
    final withoutVariable = SourceRequestTemplate.parse(
      '/search,{"method":"POST","body":"scope=<first,later>",'
      '"headers":{"Referer":"https://books.test/<first,later>"}}',
      baseUri: base,
      variables: const {'page': '2'},
    );
    expect(withoutVariable.body, 'scope=later');
    expect(withoutVariable.headers['Referer'], 'https://books.test/later');
  });

  test('page alternatives do not remove literal HTML from a typed body', () {
    final request = SourceRequestTemplate.parse(
      '/search,${jsonEncode({
        'method': 'POST',
        'body': '<div style="font-family:Arial,sans-serif">{{key}}<br data-x="a,b"/></div>',
        'headers': {'Content-Type': 'text/html'},
      })}',
      baseUri: base,
      variables: const {'key': '中文', 'page': '2'},
    );
    expect(
      request.body,
      '<div style="font-family:Arial,sans-serif">中文<br data-x="a,b"/></div>',
    );
  });

  test(
    'keeps JSON values and header variables as text without URL escaping',
    () {
      const key = '中文 "quoted" & /';
      final request = SourceRequestTemplate.parse(
        '/search,${jsonEncode({
          'method': 'POST',
          'body': {
            'query': '{{key}}',
            'items': ['{{key}}'],
          },
          'headers': {'Referer': '{{bookUrl}}'},
        })}',
        baseUri: base,
        variables: const {'key': key, 'bookUrl': 'https://books.test/book/1'},
      );
      expect(jsonDecode(request.body!), {
        'query': key,
        'items': [key],
      });
      expect(request.headers['Referer'], 'https://books.test/book/1');
    },
  );

  test(
    'preserves JSON string bodies when interpolated text contains quotes',
    () {
      final request = SourceRequestTemplate.parse(
        '/search,${jsonEncode({
          'method': 'POST',
          'body': jsonEncode({'query': '{{key}}'}),
        })}',
        baseUri: base,
        variables: const {'key': '中"文'},
      );
      expect(jsonDecode(request.body!), {'query': '中"文'});
    },
  );

  test(
    'preserves encoded forms without charset and explicitly typed bodies',
    () {
      final encoded = SourceRequestTemplate.parse(
        '/search,{"method":"POST","body":"q=%D6%D0+%CE%C4&flag&empty="}',
        baseUri: base,
      );
      expect(encoded.body, 'q=%D6%D0+%CE%C4&flag&empty=');
      final explicit = SourceRequestTemplate.parse(
        '/search,${jsonEncode({
          'method': 'POST',
          'body': 'q={{key}}',
          'headers': {'Content-Type': 'text/plain'},
        })}',
        baseUri: base,
        variables: const {'key': '中文'},
      );
      expect(explicit.body, 'q=中文');
    },
  );

  test(
    'sends the configured GBK search bytes over the real HTTP transport',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<String>();
      server.listen((request) async {
        received.complete(await utf8.decoder.bind(request).join());
        request.response.write('ok');
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      await transport.send(
        SourceRequestTemplate.parse(
          '/search,{"method":"POST","charset":"gbk","body":"q={{key}}"}',
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          variables: const {'key': '中文'},
        ),
      );
      expect(await received.future, 'q=%D6%D0%CE%C4');
    },
  );
}
