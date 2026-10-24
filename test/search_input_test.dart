import 'dart:async';

import 'package:duanju_app/search_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'search suggestions debounce, highlight, select and suppress stale results',
    (tester) async {
      final controller = TextEditingController();
      final calls = <String>[], searches = <String>[];
      final first = Completer<List<String>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: SearchInput(
                controller: controller,
                hint: '搜索',
                onSearch: searches.add,
                suggestions: (query) async {
                  calls.add(query);
                  return query == '永' ? first.future : ['永世长青'];
                },
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '永');
      await tester.pump(const Duration(milliseconds: 299));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, ['永']);
      await tester.enterText(find.byType(TextField), '永世');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      first.complete(['旧候选']);
      await tester.pumpAndSettle();
      expect(find.text('旧候选'), findsNothing);
      final item = find.byKey(const ValueKey('search-suggestion-0'));
      expect(item, findsOneWidget);
      final text = tester.widget<Text>(
        find.descendant(of: item, matching: find.byType(Text)).first,
      );
      expect(text.textSpan!.toPlainText(), '永世长青');
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(searches, ['永世长青']);
      expect(controller.text, '永世长青');
      expect(item, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('suggestion failure still allows a manual search and clearing', (
    tester,
  ) async {
    final controller = TextEditingController();
    final searches = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            controller: controller,
            hint: '搜索',
            onSearch: searches.add,
            suggestions: (_) async => throw StateError('offline'),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '重生');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    expect(searches, ['重生']);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'pinyin initials query matches the local library offline without the remote api',
    (tester) async {
      final controller = TextEditingController();
      final searches = <String>[];
      final remoteCalls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchInput(
              controller: controller,
              hint: '搜索',
              onSearch: searches.add,
              suggestions: (query) async {
                remoteCalls.add(query);
                return [];
              },
              localTitles: ['复仇者联盟', '斗罗大陆', '藏海花'],
            ),
          ),
        ),
      );
      // 纯字母输入 fczlm：命中本地片库「复仇者联盟」，且不该触发远端。
      await tester.enterText(find.byType(TextField), 'fczlm');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(remoteCalls, isEmpty, reason: '纯字母首字母查询应离线走本地片库');
      final item = find.byKey(const ValueKey('search-suggestion-0'));
      expect(
        tester
            .widget<Text>(
              find.descendant(of: item, matching: find.byType(Text)).first,
            )
            .textSpan!
            .toPlainText(),
        '复仇者联盟',
      );
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(searches, ['复仇者联盟']);
      expect(controller.text, '复仇者联盟');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'pinyin initials query with no local hit stays empty when there is no remote either',
    (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchInput(
              controller: controller,
              hint: '搜索',
              onSearch: (_) {},
              // 没有远端联想，纯字母本地又没命中 → 不弹任何候选。
              localTitles: ['复仇者联盟'],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
