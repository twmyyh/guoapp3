import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    RouteRepository repository,
    ScriptedPlayer platform, {
    Size? size,
    FakeViewPadding? padding,
    ThemeData? theme,
  }) async {
    SharedPreferences.setMockInitialValues({});
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
    }
    if (padding != null) {
      tester.view.padding = padding;
    }
    final store = LocalStore(await SharedPreferences.getInstance());
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          initialPosition: 7,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settleOperations(tester);
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    await settleOperations(tester);
    expect(player.disposed, isTrue);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'duplicate errors refresh once while keeping progress, rate and pause state',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await tester.tap(find.byKey(const ValueKey('player-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭菜单'));
      await tester.pumpAndSettle();
      await player.seek(const Duration(seconds: 28));
      await tester.pump();
      await tester.tap(find.byTooltip('暂停播放'));
      await settleOperations(tester);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      // 同步抛出的两条错误只会触发一次刷新（不会重复排队），
      // 且首次恢复只重开当前线路，不立刻跳到备用线路。
      expect(repository.primaryCalls, 2);
      expect(repository.fallbackCalls, 0);
      expect(player.opened.last.start, const Duration(seconds: 28));
      expect(player.state.rate, 1.5);
      expect(player.played.last, isFalse);
      expect(repository.active.length, 1);
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'recovery exhaustion releases sessions and manual retry keeps the saved position',
    (tester) async {
      final repository = RouteRepository()..broken = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settleOperations(tester);
      }
      // 新播放器的恢复阶梯：刷新当前线路 -> 切备用线路 -> 停止。
      // 只有两条线路，因此备用线路只尝试一次，之后不再空转重试。
      expect(repository.primaryCalls, 2);
      expect(repository.fallbackCalls, 1);
      expect(find.text('暂时无法播放'), findsOneWidget);
      expect(repository.active, isEmpty);
      await tester.pump(const Duration(seconds: 25));
      expect(repository.primaryCalls + repository.fallbackCalls, 3);
      repository.broken = false;
      await tester.tap(find.text('重试播放'));
      await settleOperations(tester);
      expect(player.opened.last.start, const Duration(seconds: 7));
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'switching episodes ignores a delayed fallback and frees both old plans',
    (tester) async {
      final repository = RouteRepository()..deferFallback = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      // 第一次错误只刷新当前线路，需要再失败一次才会请求备用线路（延迟返回）。
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      expect(repository.pending, isNotNull);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settleOperations(tester);
      final currentURL = player.opened.last.uri;
      final late = PlaybackPlan(
        url: 'https://media.test/late.mp4',
        session: 'late',
      );
      repository.active.add(late.session);
      repository.pending!.complete(late);
      await settleOperations(tester);
      expect(player.opened.last.uri, currentURL);
      expect(repository.active.length, 1);
      expect(repository.active, isNot(contains('late')));
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets('picture-in-picture hides app overlay controls', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      switch (call.method) {
        case 'pictureInPictureStatus':
          return {'supported': true, 'active': false};
        case 'enterPictureInPicture':
          return {'supported': true, 'active': true, 'requested': true};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsOneWidget,
      );
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('简介'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-picture-in-picture')));
      await tester.pump();
      await tester.pump();
      await settleOperations(tester);
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-speed')), findsNothing);
      expect(find.byKey(const ValueKey('player-quality')), findsNothing);
      expect(find.byKey(const ValueKey('player-progress')), findsNothing);
      expect(find.text('选集'), findsNothing);
      expect(find.text('简介'), findsNothing);
      expect(find.text('下载'), findsNothing);
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile taps toggle controls and double taps toggle playback', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        size: const Size(390, 844),
        padding: const FakeViewPadding(top: 32),
      );
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      expect(surface.top, greaterThanOrEqualTo(32));
      final tapPoint = Offset(surface.center.dx, surface.top + 12);
      expect(find.byTooltip('暂停播放'), findsOneWidget);
      await tester.tapAt(tapPoint);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      expect(player.state.playing, isTrue);
      await tester.tapAt(tapPoint);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      expect(player.state.playing, isTrue);

      await tester.tapAt(tapPoint);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(tapPoint);
      await tester.pump();
      expect(player.state.playing, isFalse);

      await tester.pump(kDoubleTapTimeout);
      await tester.tapAt(tapPoint);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(tapPoint);
      await tester.pump();
      expect(player.state.playing, isTrue);
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });

  testWidgets('compact player tools stay clustered instead of evenly spread', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'pictureInPictureStatus') {
        return {'supported': true, 'active': false};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      final speed = tester.getRect(find.byKey(const ValueKey('player-speed')));
      final quality = tester.getRect(
        find.byKey(const ValueKey('player-quality')),
      );
      final pip = tester.getRect(
        find.byKey(const ValueKey('player-picture-in-picture')),
      );
      expect(quality.left - speed.right, lessThan(8));
      expect(pip.left - quality.right, lessThan(8));
      expect(pip.right, greaterThan(330));
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('holding fast forward hides feedback and controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        size: const Size(390, 844),
        theme: ThemeData.light(),
      );
      // 控制条 4 秒后自动隐藏；右侧中央的弹幕按钮只在控制条可见时挡住触摸，
      // 因此等它退场后再长按，才等价于真实播放中的手势。
      await tester.pump(const Duration(seconds: 5));
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      final target = Offset(surface.right - 20, surface.center.dy);
      final gesture = await tester.startGesture(target);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 200));
      expect(player.rates.last, 2);
      // 长按期间只在画面中央留一行「2 倍速 · 松开恢复」提示。
      expect(find.textContaining('松开恢复'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-speed')).hitTestable(),
        findsNothing,
      );
      await gesture.up();
      await tester.pump();
      expect(player.rates.last, 1);
      expect(find.textContaining('恢复'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.textContaining('恢复'), findsNothing);
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'desktop idle hides controls while hover and keys bring them back',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final repository = RouteRepository();
        final player = ScriptedPlayer();
        await mount(tester, repository, player, size: const Size(1280, 720));
        final controls = find.byKey(const ValueKey('player-speed'));
        expect(controls.hitTestable(), findsOneWidget);
        final surface = tester.getRect(
          find.byKey(const ValueKey('player-gesture-surface')),
        );
        // 空闲 4 秒后自动隐藏。
        await tester.pump(const Duration(seconds: 5));
        expect(controls.hitTestable(), findsNothing);

        // 桌面端鼠标移动即唤出控制条（与 xxx 播放器一致）。
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: Offset(surface.center.dx, surface.center.dy),
        );
        await mouse.moveTo(Offset(surface.center.dx, surface.center.dy - 40));
        await tester.pump();
        expect(controls.hitTestable(), findsOneWidget);

        // 空格暂停/继续。
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(player.state.playing, isFalse);
        expect(controls.hitTestable(), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(player.state.playing, isTrue);

        // 方向键回退 5 秒，并在画面中央给出提示。
        final before = player.state.position;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(player.state.position, before - const Duration(seconds: 5));
        expect(find.textContaining('后退至'), findsOneWidget);

        await mouse.removePointer();
        await unmount(tester, player);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
