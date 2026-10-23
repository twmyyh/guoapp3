import 'package:media_kit/media_kit.dart';

/// Windows 桌面端 libmpv 播放参数收敛点。
///
/// 参考 guoappxxx 的 Windows 播放调优结论，把「花屏 / 卡顿」相关的几项
/// 从散落在各播放器里的临时补丁收敛到一处，guo（[PlayerScreen]）与
/// xigua（[XiguaPlayerScreen]）共用，避免两边参数漂移。
///
/// 只处理与 Windows 有关的项，Android / iOS / macOS 原有参数不动。
///
/// 设计原则：**Windows 上只减负、不加策略**。凡是会让 mpv 主动丢帧或
/// 抢带宽的选项一律不开，交回 mpv 自身的默认调度（这也是 guoappxxx 在
/// Windows 上不卡的直接原因）。
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
      // cache-on-disk 会把网络流的 demuxer 缓存写进磁盘临时文件
      // （media_kit 默认显式设成 yes）。磁盘 I/O 一旦抖动就直接变成画面卡顿，
      // 而短剧单集体积小，纯内存缓存完全够用。
      await set('cache-on-disk', 'no');
      // hr-seek 精确寻址在流式源上要等到目标帧并逐帧重新解码，拖动进度条会
      // 明显顿住；改为关键帧寻址即时响应，观感更接近在线播放器。
      await set('hr-seek', 'no');
      // 预读时长保持 mpv 默认量级（10 秒）。此前抬到 20 秒会让播放器在开播
      // 瞬间向站源连发一串分片请求，与其它预取叠加后抢同一条连接预算，
      // 反而把正在播的那一片拖慢。
      await set('cache-secs', '10');
    }

    // 这里刻意不再设置 video-sync：`video-sync=audio` 本来就是 mpv 默认值。
    //
    // framedrop 则要**显式写回 no**：libmpv 是进程内单实例，属性带记忆，
    // xigua 播放器的手机端默认档会先把它设成 `vo`（见 XiguaPlayerScreen 的
    // 参数表），若不覆盖回来，桌面端仍会「渲染稍慢就丢帧」，表现为画面一顿一顿。
    await set('framedrop', 'no');
  }
}
