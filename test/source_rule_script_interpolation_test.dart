import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_catalog.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_rules.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_state.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;
  late SourceRuleEngine engine;
  late SourceRuleDocument document;

  setUp(() {
    evaluator = QuickJsSourceScriptEvaluator();
    engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Yiove fixture',
      'bookSourceUrl': 'https://api-bc.wtzw.com',
    });
    document = SourceRuleDocument.fromValue(
      {'id': 123456},
      Uri.parse('https://api-bc.wtzw.com/search'),
      scriptContext: SourceScriptContext(source: source),
    );
  });

  tearDown(() => evaluator.dispose());

  test(
    'interpolates Yiove JSON selectors before executing rule JavaScript',
    () {
      expect(
        engine.evaluateString(document, document.value, _yioveBookUrlRule),
        '123456:2937357107',
      );
    },
  );

  test(
    'interpolates Yiove JSON selectors before executing async rule JavaScript',
    () async {
      expect(
        await engine.evaluateStringAsync(
          document,
          document.value,
          _yioveBookUrlRule,
        ),
        '123456:2937357107',
      );
    },
  );

  test('list script interpolation uses the current item context', () async {
    const rule = r'''@js:
params={'id':{{$.id}}}
params.id
''';
    final currentItem = {'id': 654321};

    expect(engine.evaluateList(document, currentItem, rule), [654321]);
    expect(await engine.evaluateListAsync(document, currentItem, rule), [
      654321,
    ]);
  });

  test('scripted book URL is not treated as a static URL template', () {
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Yiove fixture',
      'bookSourceUrl': 'https://api-bc.wtzw.com',
      'ruleSearch': {'bookUrl': _yioveBookUrlRule},
    });
    final state = runtimeRuleStateFor(
      SourceRuntimeState(),
      SourceRuntimeRules(const SourceRuleEngine()),
      source,
      'https://api-bc.wtzw.com/api/v4/book/detail?id=123456',
      const {'preserved': 'yes'},
    );

    expect(state, {'preserved': 'yes'});
  });
}

const _yioveBookUrlRule = r'''@js:
sign_key='d3dGiJc651gSQ8w1'

params={'id':{{$.id}},'imei_ip':'2937357107','teeny_mode':0}

params.id+':'+params.imei_ip
''';
