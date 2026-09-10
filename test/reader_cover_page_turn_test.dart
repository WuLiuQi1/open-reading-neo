import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_page_turn_geometry.dart';
import 'package:xxread/widgets/reader_cover_page_turn.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/widgets/reader_shader_page_curl.dart';

void main() {
  Future<void> pumpCover(
    WidgetTester tester, {
    required ReaderCoverPageTurnController controller,
    required ReaderPageSnapshot current,
    ReaderPageSnapshot? forward,
    ReaderPageSnapshot? backward,
    VoidCallback? onTurnForward,
    VoidCallback? onTurnBackward,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 700,
            child: ReaderCoverPageTurn(
              controller: controller,
              currentPage: current,
              forwardPage: forward,
              backwardPage: backward,
              onTurnForward: onTurnForward ?? () {},
              onTurnBackward: onTurnBackward ?? () {},
              paperColor: Colors.white,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('programmatic forward turn reports the reader page change', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      forward: _snapshot('next'),
      onTurnForward: () => forwardTurns++,
    );

    final turn = controller.turnForward();
    await tester.pumpAndSettle();
    await turn;

    expect(forwardTurns, 1);
    expect(controller.debugIsIdle, isTrue);
  });

  testWidgets('programmatic backward turn slides the previous sheet back in', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var backwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      backward: _snapshot('previous'),
      onTurnBackward: () => backwardTurns++,
    );

    final turn = controller.turnBackward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(controller.debugDirection, ReaderPageTurnDirection.backward);
    expect(find.text('previous'), findsOneWidget);
    await tester.pumpAndSettle();
    await turn;

    expect(backwardTurns, 1);
  });

  testWidgets('programmatic turn without a neighbour completes as a no-op', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      onTurnForward: () => forwardTurns++,
    );

    await controller.turnForward();
    await tester.pumpAndSettle();

    expect(forwardTurns, 0);
    expect(controller.debugIsIdle, isTrue);
  });

  testWidgets('rapid programmatic turns are queued instead of dropped', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    final pages = List.generate(4, (index) => _snapshot('page-$index'));
    var pageIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) => Center(
            child: SizedBox(
              width: 400,
              height: 700,
              child: ReaderCoverPageTurn(
                controller: controller,
                currentPage: pages[pageIndex],
                backwardPage: pageIndex > 0 ? pages[pageIndex - 1] : null,
                forwardPage: pageIndex + 1 < pages.length
                    ? pages[pageIndex + 1]
                    : null,
                onTurnForward: () => setHostState(() => pageIndex++),
                onTurnBackward: () => setHostState(() => pageIndex--),
                paperColor: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final first = controller.turnForward();
    final second = controller.turnForward();
    await tester.pumpAndSettle();
    await Future.wait([first, second]);

    expect(pageIndex, 2);
    expect(find.text('page-2'), findsOneWidget);
  });

  testWidgets('a drag past the commit threshold turns the page forward', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      forward: _snapshot('next'),
      onTurnForward: () => forwardTurns++,
    );

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('next'), findsOneWidget);
    expect(controller.debugTopSheetOffset, lessThan(-100));
    // Let the tracked velocity decay so the distance threshold decides.
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(forwardTurns, 1);
    expect(controller.debugIsIdle, isTrue);
  });

  testWidgets('a forward neighbour refresh does not cancel the active drag', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var forward = _snapshot('loading-next');
    var backward = _snapshot('previous');
    var originalForwardTurns = 0;
    var replacementForwardTurns = 0;
    VoidCallback onTurnForward = () => originalForwardTurns++;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            updateHost = setHostState;
            return Center(
              child: SizedBox(
                width: 400,
                height: 700,
                child: ReaderCoverPageTurn(
                  controller: controller,
                  currentPage: _snapshot('current'),
                  forwardPage: forward,
                  backwardPage: backward,
                  onTurnForward: onTurnForward,
                  onTurnBackward: () {},
                  paperColor: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.debugTopSheetOffset, lessThan(-100));

    updateHost(() {
      forward = _snapshot('loaded-next');
      backward = _snapshot('updated-previous');
      onTurnForward = () => replacementForwardTurns++;
    });
    await tester.pump();

    expect(controller.debugTopSheetOffset, lessThan(-100));
    expect(find.text('loading-next'), findsOneWidget);
    expect(find.text('loaded-next'), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(originalForwardTurns, 1);
    expect(replacementForwardTurns, 0);
    expect(controller.debugIsIdle, isTrue);
  });

  testWidgets('a disappearing forward neighbour finishes the active drag', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    ReaderPageSnapshot? forward = _snapshot('next');
    var forwardTurns = 0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            updateHost = setHostState;
            return Center(
              child: SizedBox(
                width: 400,
                height: 700,
                child: ReaderCoverPageTurn(
                  controller: controller,
                  currentPage: _snapshot('current'),
                  forwardPage: forward,
                  onTurnForward: () => forwardTurns++,
                  onTurnBackward: () {},
                  paperColor: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 16));

    updateHost(() => forward = null);
    await tester.pump();
    expect(find.text('next'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(forwardTurns, 1);
    await controller.turnForward();
    await tester.pumpAndSettle();
    expect(forwardTurns, 1);
  });

  testWidgets('an arriving forward neighbour is used after the active drag', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    ReaderPageSnapshot? forward;
    var forwardTurns = 0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            updateHost = setHostState;
            return Center(
              child: SizedBox(
                width: 400,
                height: 700,
                child: ReaderCoverPageTurn(
                  controller: controller,
                  currentPage: _snapshot('current'),
                  forwardPage: forward,
                  onTurnForward: () => forwardTurns++,
                  onTurnBackward: () {},
                  paperColor: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 16));

    updateHost(() => forward = _snapshot('loaded-next'));
    await tester.pump();
    expect(controller.debugTopSheetOffset, greaterThan(-40));
    expect(find.text('loaded-next'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(forwardTurns, 0);

    final nextTurn = controller.turnForward();
    await tester.pumpAndSettle();
    await nextTurn;
    expect(forwardTurns, 1);
  });

  testWidgets('a current page replacement cancels the active drag', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var current = _snapshot('current');
    var forwardTurns = 0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            updateHost = setHostState;
            return Center(
              child: SizedBox(
                width: 400,
                height: 700,
                child: ReaderCoverPageTurn(
                  controller: controller,
                  currentPage: current,
                  forwardPage: _snapshot('next'),
                  onTurnForward: () => forwardTurns++,
                  onTurnBackward: () {},
                  paperColor: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 16));

    updateHost(() => current = _snapshot('replacement-current'));
    await tester.pump();
    expect(controller.debugTopSheetOffset, 0);
    expect(controller.debugIsIdle, isTrue);
    expect(find.text('replacement-current'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(forwardTurns, 0);
  });

  testWidgets('a short slow drag springs back without turning', (tester) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      forward: _snapshot('next'),
      onTurnForward: () => forwardTurns++,
    );

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(forwardTurns, 0);
    expect(controller.debugIsIdle, isTrue);
    expect(controller.debugTopSheetOffset, 0);
    expect(find.text('current'), findsOneWidget);
  });

  testWidgets('a fast fling commits even from a short drag', (tester) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      forward: _snapshot('next'),
      onTurnForward: () => forwardTurns++,
    );

    await tester.fling(find.text('current'), const Offset(-90, 0), 1400);
    await tester.pumpAndSettle();

    expect(forwardTurns, 1);
  });

  testWidgets('dragging right pulls the previous sheet in and commits', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var backwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      backward: _snapshot('previous'),
      onTurnBackward: () => backwardTurns++,
    );

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('previous'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(backwardTurns, 1);
  });

  testWidgets('dragging with no neighbour rubber-bands instead of turning', (
    tester,
  ) async {
    final controller = ReaderCoverPageTurnController();
    var forwardTurns = 0;

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      onTurnForward: () => forwardTurns++,
    );

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final stretched = controller.debugTopSheetOffset!;
    expect(stretched, lessThan(0));
    expect(stretched, greaterThan(-40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(forwardTurns, 0);
    expect(controller.debugTopSheetOffset, 0);
  });

  testWidgets('a vertical drag leaves the sheet untouched', (tester) async {
    final controller = ReaderCoverPageTurnController();

    await pumpCover(
      tester,
      controller: controller,
      current: _snapshot('current'),
      forward: _snapshot('next'),
    );

    final gesture = await tester.startGesture(const Offset(200, 350));
    await gesture.moveBy(const Offset(-4, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-120, 30));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.debugTopSheetOffset, 0);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.debugIsIdle, isTrue);
  });

  testWidgets('renders opaque sheets over the paper colour', (tester) async {
    final controller = ReaderCoverPageTurnController();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 700,
            child: ReaderCoverPageTurn(
              controller: controller,
              currentPage: _snapshot('current'),
              forwardPage: _snapshot('next'),
              backwardPage: _snapshot('previous'),
              onTurnForward: () {},
              onTurnBackward: () {},
              paperColor: Colors.amber,
            ),
          ),
        ),
      ),
    );

    expect(find.text('current'), findsOneWidget);
    expect(find.text('next'), findsNothing);
    expect(find.text('previous'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.amber,
      ),
      findsNWidgets(2),
    );
  });
}

ReaderPageSnapshot _snapshot(String id) => ReaderPageSnapshot(
  key: ReaderPageSnapshotKey(
    pageIdentity: id,
    layoutFingerprint: 'layout',
    themeId: 'day',
  ),
  contentRevision: 0,
  child: Text(id),
);
