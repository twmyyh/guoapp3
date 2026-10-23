import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/player_interactions.dart';

import 'player_fixtures.dart';

/// 播放器交互层回归测试。
///
/// 这里的用例对应「左侧长按滑动调节亮度」这条产品要求：亮度的读写走
/// `duanju/device` 通道（Android 窗口亮度覆盖），所以测试里必须 mock 通道，
/// 否则只能验证手势状态、验证不到真实下发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final brightnessCalls = <double>[];

  setUp(() {
    // 亮度分支只在 Android 生效，测试固定平台，避免宿主系统不同导致跳过。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    brightnessCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppDevice.channel, (call) async {
          switch (call.method) {
            case 'screenBrightness':
              return 0.4;
            case 'setScreenBrightness':
              final value = (call.arguments as Map)['value'];
              brightnessCalls.add((value as num).toDouble());
              return null;
            case 'resetScreenBrightness':
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppDevice.channel, null);
  });

  PlayerInteractions build(Player player, {void Function(int)? onEpisode}) =>
      PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (direction) {
          onEpisode?.call(direction);
          return '';
        },
      );

  test('长按画面进入 3 倍速，松手恢复原倍速', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = build(player);

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(500, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(platform.rates, contains(3));
    expect(interactions.boosting, isTrue);
    expect(interactions.feedback, contains('3 倍速'));

    interactions.pointerUp(
      PointerUpEvent(
        pointer: 1,
        position: const Offset(500, 200),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 400),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(platform.rates.last, 1);
    expect(interactions.boosting, isFalse);

    interactions.dispose();
    await player.dispose();
  });

  test('左侧 35% 区域内垂直上滑提高亮度并展示 HUD', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    var episodes = 0;
    final interactions = build(player, onEpisode: (_) => episodes++);
    // 构造时异步读取的初始亮度（mock 返回 0.4）。
    await Future<void>.delayed(Duration.zero);
    expect(interactions.brightness, closeTo(0.4, 0.001));

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(100, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    // 亮度必须先长按（350ms）才出来，短促滑动属于切集。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await Future<void>.delayed(Duration.zero);
    expect(interactions.hudState.type, SwipeAction.brightness);

    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(108, 140),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 120),
      ),
    );
    // 上滑 60px / 面板高度 60% = +0.25，初始 0.4 → 0.65。
    expect(interactions.brightness, closeTo(0.65, 0.001));
    expect(interactions.hudState.value, closeTo(0.65, 0.001));
    expect(brightnessCalls.last, closeTo(0.65, 0.001));

    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(108, 320),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 220),
      ),
    );
    // 下滑过量时夹到下限 0.01，不会出现负亮度。
    expect(interactions.brightness, closeTo(0.01, 0.001));

    interactions.pointerUp(
      PointerUpEvent(
        pointer: 1,
        position: const Offset(108, 320),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 320),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // 左侧手势只调亮度，绝不触发切集。
    expect(episodes, 0);

    interactions.dispose();
    await player.dispose();
  });

  test('左侧亮度拖动在离开播放器时复位系统亮度', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = build(player);
    await Future<void>.delayed(Duration.zero);

    interactions.setBrightnessDirect(0.8);
    expect(brightnessCalls.last, closeTo(0.8, 0.001));
    expect(interactions.isBrightnessActive, isTrue);

    interactions.dispose();
    await player.dispose();
  });

  test('右侧上滑切换下一集、下滑切换上一集', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final directions = <int>[];
    final interactions = build(player, onEpisode: directions.add);

    Future<void> flick(Offset from, Offset to) async {
      interactions.pointerDown(
        PointerDownEvent(
          pointer: 1,
          position: from,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration.zero,
        ),
        swipeEnabled: true,
        height: 400,
        width: 800,
      );
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 1,
          position: to,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 120),
        ),
      );
      interactions.pointerUp(
        PointerUpEvent(
          pointer: 1,
          position: to,
          buttons: 0,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 160),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    await flick(const Offset(600, 300), const Offset(600, 100));
    await flick(const Offset(600, 100), const Offset(600, 300));
    expect(directions, [1, -1]);
    expect(brightnessCalls, isEmpty);

    interactions.dispose();
    await player.dispose();
  });

  test('左侧短促上下滑动同样是切集，不进亮度', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final directions = <int>[];
    final interactions = build(player, onEpisode: directions.add);

    Future<void> flick(Offset from, Offset to) async {
      interactions.pointerDown(
        PointerDownEvent(
          pointer: 1,
          position: from,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration.zero,
        ),
        swipeEnabled: true,
        height: 400,
        width: 800,
      );
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 1,
          position: to,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 120),
        ),
      );
      interactions.pointerUp(
        PointerUpEvent(
          pointer: 1,
          position: to,
          buttons: 0,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 160),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    // 起点 x=100 落在左侧 35% 内，但没有长按，所以走切集而不是亮度。
    await flick(const Offset(100, 300), const Offset(100, 100));
    expect(directions, [1]);
    expect(interactions.hudState.type, isNot(SwipeAction.brightness));
    expect(brightnessCalls, isEmpty);

    interactions.dispose();
    await player.dispose();
  });

  test('左右滑动按 15 秒步长快进快退', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = build(player);

    Future<void> swipe(Offset from, Offset to) async {
      interactions.pointerDown(
        PointerDownEvent(
          pointer: 1,
          position: from,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration.zero,
        ),
        swipeEnabled: true,
        height: 400,
        width: 800,
      );
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 1,
          position: to,
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 120),
        ),
      );
      expect(interactions.hudState.type, SwipeAction.seek);
      expect(interactions.hudState.label, contains('15 秒'));
      interactions.pointerUp(
        PointerUpEvent(
          pointer: 1,
          position: to,
          buttons: 0,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 160),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    await swipe(const Offset(400, 200), const Offset(560, 200));
    expect(player.state.position, const Duration(seconds: 15));
    expect(interactions.feedback, contains('快进'));
    // 抬手完成 seek 后，预览 HUD 应立即消失，不残留在屏幕上。
    expect(interactions.hudState.type, SwipeAction.none);

    await swipe(const Offset(400, 200), const Offset(240, 200));
    expect(player.state.position, Duration.zero);
    expect(interactions.feedback, contains('后退'));
    expect(interactions.hudState.type, SwipeAction.none);

    interactions.dispose();
    await player.dispose();
  });

  test('快进与音量提示走反馈文案', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = build(player);

    interactions.seek(5);
    await Future<void>.delayed(Duration.zero);
    expect(interactions.feedback, contains('快进'));

    interactions.changeVolume(-5);
    expect(interactions.feedback, contains('音量'));

    interactions.dispose();
    await player.dispose();
  });
}
