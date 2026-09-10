import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;

  setUp(() => evaluator = QuickJsSourceScriptEvaluator());
  tearDown(() => evaluator.dispose());

  SourceScriptContext context({String jsLib = ''}) => SourceScriptContext(
    source: ReadingSourceConfig.fromJson({
      'bookSourceName': 'Yiove compatibility fixture',
      'bookSourceUrl': 'https://api-bc.wtzw.com',
      'jsLib': jsLib,
    }),
  );

  test('decrypts the Yiove Qimao AES rule through JavaImporter', () {
    expect(
      evaluator.evaluate(r'''
var content = 'MDEyMzQ1Njc4OWFiY2RlZrJ/Mx27qcsr+xsAT5+RQ68=';

var javaImport = new JavaImporter();
javaImport.importPackage(
    Packages.java.lang,
    Packages.javax.crypto.spec,
    Packages.javax.crypto,
    Packages.java.util
);
with(javaImport) {
    function decode(content) {
        var ivEncData = Base64.getDecoder().decode(String(content));
        var key = SecretKeySpec(String("242ccb8230d709e1").getBytes(), "AES");
        var iv = IvParameterSpec(Arrays.copyOfRange(ivEncData, 0, 16));
        var chipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        chipher.init(2, key, iv);
        return String(chipher.doFinal(Arrays.copyOfRange(ivEncData, 16, ivEncData.length)));
    }
}
decode(content);
''', context()),
      '章节正文',
    );
  });

  test('matches Java byte array copyOfRange boundaries', () {
    expect(
      evaluator.evaluate(
        'Packages.java.util.Arrays.copyOfRange([1, 2], 1, 4)',
        context(),
      ),
      [2, 0, 0],
    );
    expect(
      evaluator.evaluate(
        'Packages.java.util.Arrays.copyOfRange([1, 2], 2, 2)',
        context(),
      ),
      isEmpty,
    );
    for (final script in [
      'Packages.java.util.Arrays.copyOfRange([1, 2], -1, 1)',
      'Packages.java.util.Arrays.copyOfRange([1, 2], 3, 4)',
      'Packages.java.util.Arrays.copyOfRange([1, 2], 2, 1)',
    ]) {
      expect(() => evaluator.evaluate(script, context()), throwsA(anything));
    }
  });

  test('shares declarations created by eval inside jsLib', () {
    expect(
      evaluator.evaluate(
        "fromEval('正文')",
        context(
          jsLib: '''
eval("var sharedPrefix = '章节：'; function fromEval(value) { return sharedPrefix + value; }");
''',
        ),
      ),
      '章节：正文',
    );
  });
}
