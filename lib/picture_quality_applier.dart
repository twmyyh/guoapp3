import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'picture_quality.dart';
import 'video_enhancement_assets.dart';
import 'video_enhancement_mpv.dart';

/// 三态画质档（原画/锐化/Anime4K）在 libmpv 播放器上的跨平台应用器。
///
/// 与 [VideoEnhancementController] 的自适应增强并存、互不管理对方的效果：
/// - 原画：清除本应用器添加的滤镜与着色器；
/// - 锐化：mpv 内建 `unsharp` 视频滤镜（带独立 label，便于精确移除）；
/// - Anime4K：加载 assets 中已校验的 `Anime4K_Upscale_Denoise_CNN_x2_S.glsl`
///   到 `glsl-shaders`，并配套 `fbo-format` 等渲染选项。
///
/// 在 GPU 渲染管线缺失、片源尺寸未就绪或非原生播放器时静默退化为原画，
/// 不阻断播放。监听 `videoParams`：片源尺寸确定后自动重新套用当前画质档。
class PictureQualityApplier {
  PictureQualityApplier(this.player)
    : _native = player.platform is NativePlayer
          ? player.platform as NativePlayer
          : null,
      _mpv = player.platform is NativePlayer
          ? VideoEnhancementMpv(player.platform as NativePlayer)
          : null {
    _subscription = player.stream.videoParams.listen((_) {
      unawaited(apply(_current));
    });
  }

  final Player player;
  final NativePlayer? _native;
  final VideoEnhancementMpv? _mpv;
  StreamSubscription<VideoParams>? _subscription;

  static const _filterLabel = 'duanju_sharpen';

  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  bool _sharpenActive = false;
  bool _animeActive = false;
  String? _ownedAnimeShader;

  PictureQualityPreferences _current = const PictureQualityPreferences();

  /// 最近一次**成功**落地的档位。切集 / 尺寸变化会让 `videoParams` 反复触发，
  /// 同档位重复 clear + add 会重建 mpv 的滤镜链，渲染管线会闪一下，
  /// 开播瞬间尤其容易表现为卡顿或半帧花屏，故用它对账。
  PictureQualityPreferences? _applied;

  PictureQualityPreferences get preferences => _current;

  /// 非原生（libmpv）播放器时安全空转。
  bool get supported => _mpv != null;

  bool get _playerDisposed => _native?.disposed ?? true;

  /// 应用指定画质档。偏好由上层（guo/xigua 共享）传入，切换播放器不丢失。
  Future<void> apply(PictureQualityPreferences value) {
    _current = value;
    return _enqueue(() => _apply(value));
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  Future<void> _apply(PictureQualityPreferences value) async {
    final mpv = _mpv;
    if (mpv == null || _closed || _playerDisposed) return;
    try {
      await mpv.initialize();
    } catch (_) {
      return;
    }
    if (_closed || _playerDisposed) return;
    if (value == _applied && _effectsMounted(mpv, value)) return;
    _clearOwnEffects();
    try {
      switch (value.mode) {
        case PictureQualityMode.original:
          break;
        case PictureQualityMode.sharpen:
          _applySharpen(mpv, value.strength);
        case PictureQualityMode.anime4k:
          await _applyAnime4K(mpv);
      }
      _applied = value;
    } catch (_) {
      // 增强不可用：清掉刚加的效果，退化为原画，不阻断播放。
      _clearOwnEffects();
      _applied = null;
    }
  }

  /// 当前档位的效果是否仍挂在 mpv 上（别的模块可能把人清掉）。
  bool _effectsMounted(
    VideoEnhancementMpv mpv,
    PictureQualityPreferences value,
  ) {
    switch (value.mode) {
      case PictureQualityMode.original:
        return !_sharpenActive && !_animeActive;
      case PictureQualityMode.sharpen:
        if (!_sharpenActive) return false;
        final filters = mpv.read('vf');
        return filters is List &&
            filters.any((item) => item is Map && item['label'] == _filterLabel);
      case PictureQualityMode.anime4k:
        final shader = _ownedAnimeShader;
        if (!_animeActive || shader == null) return false;
        return _shaderList(mpv).contains(shader);
    }
  }

  void _applySharpen(VideoEnhancementMpv mpv, int strength) {
    final clamped = strength.clamp(0, 100);
    final radius = (0.8 + clamped / 100 * 1.2).toStringAsFixed(2);
    final amount = (clamped / 100 * 0.6).toStringAsFixed(3);
    mpv.command([
      'vf',
      'add',
      '@$_filterLabel:unsharp=luma_radius=$radius:luma_strength=$amount',
    ]);
    _sharpenActive = true;
  }

  Future<void> _applyAnime4K(VideoEnhancementMpv mpv) async {
    final shaderPath = await VideoEnhancementAssets.prepare(
      VideoEnhancementAssets.anime,
    );
    if (_closed) return;
    mpv.set('fbo-format', 'rgba16f');
    mpv.set('scale', 'spline36');
    mpv.set('dscale', 'mitchell');
    mpv.set('cscale', 'bilinear');
    mpv.set('correct-downscaling', 'yes');
    final current = _shaderList(mpv);
    if (!current.contains(shaderPath)) {
      mpv.setStrings('glsl-shaders', [...current, shaderPath]);
    }
    _ownedAnimeShader = shaderPath;
    _animeActive = true;
  }

  List<String> _shaderList(VideoEnhancementMpv mpv) {
    final value = mpv.read('glsl-shaders');
    if (value is! List) return const [];
    return value.whereType<String>().toList();
  }

  void _clearOwnEffects() {
    if (_closed) return;
    final mpv = _mpv;
    if (mpv == null) return;
    try {
      if (_sharpenActive) {
        final filters = mpv.read('vf');
        if (filters is List &&
            filters.any(
              (item) => item is Map && item['label'] == _filterLabel,
            )) {
          mpv.command(['vf', 'remove', '@$_filterLabel']);
        }
        _sharpenActive = false;
      }
    } catch (_) {
      _sharpenActive = false;
    }
    try {
      if (_animeActive && _ownedAnimeShader != null) {
        final remaining = _shaderList(
          mpv,
        ).where((item) => item != _ownedAnimeShader).toList();
        mpv.setStrings('glsl-shaders', remaining);
        mpv.set('fbo-format', 'bgr0');
        _ownedAnimeShader = null;
        _animeActive = false;
      }
    } catch (_) {
      _ownedAnimeShader = null;
      _animeActive = false;
    }
  }

  Future<void> dispose() async {
    if (_closed) {
      await _subscription?.cancel();
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    final tail = _tail;
    _tail = Future<void>.value();
    await tail;
    _clearOwnEffects();
    _mpv?.closed = true;
  }
}
