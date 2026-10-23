import 'package:media_kit/media_kit.dart';

/// Windows 桌面端 libmpv 播放参数收敛点。
///
/// 参考 guoappxxx 的 Windows 播放调优结论，把「花屏 / 卡顿」相关的几项
/// 从散落在各播放器里的临时补丁收敛到一处，guo（[PlayerScreen]）与
/// xigua（[XiguaPlayerScreen]）共用，避免两边参数漂移。
///
/// 只处理与 Windows 有关的项，Android / iOS / macOS 原有参数不动。
class WindowsPlaybackTuning {
  WindowsPlaybackTuning._();

  /// 硬解统一走 `d3d11va-copy`。
  ///
  /// media_kit 在 Windows 上固定 `vo=libmpv`（ANGLE 纹理回传给 Flutter 合成）。
  /// 直接 `d3d11va`（零拷贝互操作）在部分 NVIDIA / Intel 驱动上会让画面右侧、
  /// 底部出现绿边或整块花屏，切到 copy 模式（解码后拷回系统内存再上传纹理）
  /// 是当前最稳的一档，代价是少量内存带宽。
  static const hwdec = 'd3d11va-copy';

  /// 应用 Windows 端播放参数。必须在 `Player.open` 之前调用。
  ///
  /// [local] 为本地文件时不做网络相关项调整。
  static Future<void> apply(
    NativePlayer platform, {
    required bool local,
  }) async {
    Future<void> set(String key, String value) async {
      try {
        await platform.setProperty(key, value);
      } catch (_) {
        // 单个属性不被当前 libmpv 版本识别时跳过，不影响其余调优。
      }
    }

    await set('hwdec', hwdec);

    if (!local) {
      // cache-on-disk 会把网络流的缓存写盘，磁盘 I/O 抖动会直接变成卡顿；
      // 短剧单集体积小，内存缓存足够。
      await set('cache-on-disk', 'no');
      // hr-seek 精确寻址在流式源上要等到目标帧并重新解码，拖动进度条会
      // 明显卡住；改为关键帧寻址即时响应，观感更接近在线播放器。
      await set('hr-seek', 'no');
      await set('cache-secs', '20');
      await set('demuxer-readahead-secs', '20');
    }

    // 显卡跟不上时丢帧而不是把延迟越拖越长（音画不同步比偶发掉帧更难受）。
    await set('framedrop', 'vo');
    await set('video-sync', 'audio');
  }
}
