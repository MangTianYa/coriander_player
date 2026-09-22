// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:coriander_player/app_preference.dart';
import 'package:coriander_player/src/bass/bass_wasapi.dart' as BASS;
import 'package:coriander_player/utils.dart';
import 'package:ffi/ffi.dart' as ffi;
import 'package:path/path.dart' as path;
import 'package:coriander_player/src/bass/bass.dart' as BASS;
import 'dart:ffi' as ffi;

enum PlayerState {
  /// stop() has been called or the end of an audio has been reached
  stopped,

  /// start() has been called
  playing,

  /// pause() has been called
  paused,

  /// BASS_Pause() has been called or stopping unexpectedly (eg. a USB soundcard being disconnected).
  /// In either case, playback will be resumed by BASS_Start.
  pausedDevice,

  ///Playback of the stream has been stalled due to a lack of sample data.
  ///Playback will automatically resume once there is sufficient data to do so.
  stalled,

  /// the end of an audio has been reached
  completed,

  unknown,
}

const BASS_PLUGINS = [
  "BASS\\bassape.dll",
  "BASS\\bassdsd.dll",
  "BASS\\bassflac.dll",
  "BASS\\bassmidi.dll",
  "BASS\\bassopus.dll",
  "BASS\\basswv.dll"
];

class BassPlayer {
  late final ffi.DynamicLibrary _bassLib;
  late final ffi.DynamicLibrary _bassWasapiLib;
  late final BASS.Bass _bass;
  late final BASS.BassWasapi _bassWasapi;

  String? _fPath;
  int? _fstream;

  /// 当前音源是否为网络流（URL）
  bool _fIsUrl = false;

  /// 加载代次。每次调用 [setSource]/[setSourceAsync] 自增，
  /// 用于识别异步创建网络流期间用户又切歌的情况（丢弃过期的流句柄）。
  int _loadGeneration = 0;

  /// 当前音源是否真正开始过播放。
  /// 网络流刚创建时可能瞬时报告 stopped（尚未缓冲/播放），
  /// 若此时误判为“播放完成”会触发自动切歌导致不停重播。
  /// 只有真正播放过（观察到 playing）之后，stopped 才视为播放结束。
  bool _hasStartedPlaying = false;

  /// 是否启用 wasapi 独占模式
  bool wasapiExclusive = false;

  Timer? _positionUpdater;
  final _positionStreamController = StreamController<double>.broadcast();
  final _playerStateStreamController =
      StreamController<PlayerState>.broadcast();

  /// audio's length in seconds
  double get length => _fstream == null
      ? 1.0
      : _bass.BASS_ChannelBytes2Seconds(_fstream!,
          _bass.BASS_ChannelGetLength(_fstream!, BASS.BASS_POS_BYTE));

  /// current position in seconds
  double get position => _fstream == null
      ? 0.0
      : _bass.BASS_ChannelBytes2Seconds(_fstream!,
          _bass.BASS_ChannelGetPosition(_fstream!, BASS.BASS_POS_BYTE));

  PlayerState get playerState {
    if (_fstream == null) {
      return PlayerState.unknown;
    }

    switch (_bass.BASS_ChannelIsActive(_fstream!)) {
      case BASS.BASS_ACTIVE_STOPPED:
        return PlayerState.stopped;
      case BASS.BASS_ACTIVE_PLAYING:
        if (wasapiExclusive) {
          /// wasapi exclusive's channel is a decoding channel,
          /// will be BASS_ACTIVE_PLAYING as long as there is still data to decode.
          /// So here we check BASS_WASAPI_IsStarted to
          /// judge between BASS_ACTIVE_PLAYING and BASS_ACTIVE_PAUSED
          return _bassWasapi.BASS_WASAPI_IsStarted() == BASS.TRUE
              ? PlayerState.playing
              : PlayerState.paused;
        }
        return PlayerState.playing;
      case BASS.BASS_ACTIVE_PAUSED:
        return PlayerState.paused;
      case BASS.BASS_ACTIVE_PAUSED_DEVICE:
        return PlayerState.pausedDevice;
      case BASS.BASS_ACTIVE_STALLED:
        return PlayerState.stalled;
      default:
        return PlayerState.unknown;
    }
  }

  double get volumeDsp {
    if (_fstream == null) return 0;

    final volDsp = ffi.malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
    _bass.BASS_ChannelGetAttribute(_fstream!, BASS.BASS_ATTRIB_VOLDSP, volDsp);
    return volDsp.value;
  }

  /// update every 33ms
  Stream<double> get positionStream => _positionStreamController.stream;

  Stream<PlayerState> get playerStateStream =>
      _playerStateStreamController.stream;

  Timer _getPositionUpdater() {
    PlayerState? lastState;
    return Timer.periodic(
      const Duration(milliseconds: 33),
      (timer) {
        _positionStreamController.add(position);

        final state = playerState;

        if (state == PlayerState.stopped) {
          /// 只有真正播放过之后 stopped 才算播放完成，
          /// 避免网络流刚创建时的瞬时 stopped 被误判为完成而不停重播。
          if (_hasStartedPlaying) {
            _playerStateStreamController.add(PlayerState.completed);
          }
        } else {
          if (state == PlayerState.playing) {
            _hasStartedPlaying = true;
          }

          /// 网络流（Jellyfin）从缓冲(stalled)转为实际播放(playing)时，
          /// BASS 不会主动通知，播放/暂停按钮会一直停在“播放”图标。
          /// 这里在轮询中监测状态变化并推送，保证控件与实际播放状态同步。
          if (state != lastState) {
            _playerStateStreamController.add(state);
          }
        }

        lastState = state;
      },
    );
  }

  void _bassInit() {
    if (_bass.BASS_Init(
            1, 48000, BASS.BASS_DEVICE_REINIT, ffi.nullptr, ffi.nullptr) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_DEVICE:
          throw const FormatException("device is invalid.");
        case BASS.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
              "The BASS_DEVICE_REINIT flag cannot be used when device is -1. Use the real device number instead.");
        case BASS.BASS_ERROR_ALREADY:
          throw const FormatException(
              "The device has already been initialized. The BASS_DEVICE_REINIT flag can be used to request reinitialization.");
        case BASS.BASS_ERROR_ILLPARAM:
          throw const FormatException("win is not a valid window handle.");
        case BASS.BASS_ERROR_DRIVER:
          throw const FormatException("There is no available device driver.");
        case BASS.BASS_ERROR_BUSY:
          throw const FormatException(
              "Something else has exclusive use of the device.");
        case BASS.BASS_ERROR_FORMAT:
          throw const FormatException(
              "The specified format is not supported by the device. Try changing the freq parameter.");
        case BASS.BASS_ERROR_MEM:
          throw const FormatException("There is insufficient memory.");
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException(
              "Some other mystery problem! Maybe Something else has exclusive use of the device.");
      }
    }
  }

  void _startDevice() {
    if (_bass.BASS_Start() == BASS.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_INIT:
          _bassInit();
          _startDevice();
          break;
        case BASS.BASS_ERROR_BUSY:
          throw const FormatException(
              "The app's audio has been interrupted and cannot be resumed yet. (iOS only)");
        case BASS.BASS_ERROR_REINIT:
          throw const FormatException(
              "The device is currently being reinitialized or needs to be.");
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException(
              "Some other mystery problem! Maybe Something else has exclusive use of the device.");
      }
    }
  }

  /// load bass.dll from the exe's path\\BASS
  /// ensure that there's bass.dll at path of .exe\\BASS
  /// leave the device's output freq as it is
  BassPlayer() {
    final bassLibPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      "BASS",
      "bass.dll",
    );
    _bassLib = ffi.DynamicLibrary.open(bassLibPath);
    _bass = BASS.Bass(_bassLib);

    final bassWasapiLibPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      "BASS",
      "basswasapi.dll",
    );
    _bassWasapiLib = ffi.DynamicLibrary.open(bassWasapiLibPath);
    _bassWasapi = BASS.BassWasapi(_bassWasapiLib);

    // load add-ons to avoid using os codec or support more format
    for (final plugin in BASS_PLUGINS) {
      final pluginPathP = plugin.toNativeUtf16() as ffi.Pointer<ffi.Char>;
      final hplugin = _bass.BASS_PluginLoad(pluginPathP, BASS.BASS_UNICODE);

      if (hplugin == 0) {
        switch (_bass.BASS_ErrorGetCode()) {
          case BASS.BASS_ERROR_FILEOPEN:
            throw const FormatException("The file could not be opened.");
          case BASS.BASS_ERROR_FILEFORM:
            throw const FormatException("The file is not a plugin.");
          case BASS.BASS_ERROR_VERSION:
            throw const FormatException(
                "The plugin requires a different BASS version.");
          case BASS.BASS_ERROR_ALREADY:
            throw const FormatException("The plugin is already loaded.");
        }
      }
    }

    try {
      _bassInit();
    } catch (err) {
      LOGGER.e("[bass init] $err");
    }

    /// 网络流相关配置（用于 Jellyfin 等远程音源）
    try {
      // 连接超时 15s
      _bass.BASS_SetConfig(BASS.BASS_CONFIG_NET_TIMEOUT, 15000);
      // 读取超时 15s
      _bass.BASS_SetConfig(BASS.BASS_CONFIG_NET_READTIMEOUT, 15000);
      // 预缓冲 25%，减少卡顿
      _bass.BASS_SetConfig(BASS.BASS_CONFIG_NET_PREBUF, 25);
    } catch (err) {
      LOGGER.e("[bass net config] $err");
    }
  }

  /// true: 操作成功；false: 操作失败
  bool useExclusiveMode(bool exclusive) {
    final prevState = wasapiExclusive;
    try {
      final lastPos = position;
      if (prevState) {
        _bassWasapi.BASS_WASAPI_Free();
        _bassInit();
      }
      wasapiExclusive = exclusive;
      if (_fstream != null && _fPath != null) {
        setSource(_fPath!, isUrl: _fIsUrl);
        setVolumeDsp(AppPreference.instance.playbackPref.volumeDsp);
        seek(lastPos);
        start();
      }
      return true;
    } catch (err) {
      LOGGER.e("[use exclusive mode] $err");
      showTextOnSnackBar(err.toString());
    }
    wasapiExclusive = prevState;
    return false;
  }

  /// if setSource has been called once,
  /// it will pause current channel and free current stream.
  ///
  /// [isUrl] 为 true 时，[path] 被当作网络流地址（http/https），
  /// 使用 BASS_StreamCreateURL 创建流（用于 Jellyfin 等远程音源）。
  void setSource(String path, {bool isUrl = false}) {
    _loadGeneration++;
    _hasStartedPlaying = false;
    if (_fstream != null) {
      _positionUpdater?.cancel();
      freeFStream();
    }
    final pathPointer = path.toNativeUtf16() as ffi.Pointer<ffi.Void>;

    /// 设置 flags 为 BASS_UNICODE 才可以找到文件。
    const flags =
        BASS.BASS_UNICODE | BASS.BASS_SAMPLE_FLOAT | BASS.BASS_ASYNCFILE;
    const exclusiveFlags = flags | BASS.BASS_STREAM_DECODE;
    final usedFlags = wasapiExclusive ? exclusiveFlags : flags;

    final int handle;
    if (isUrl) {
      /// 网络流不使用 BASS_ASYNCFILE（那是本地文件异步读取标志）
      const urlFlags = BASS.BASS_UNICODE | BASS.BASS_SAMPLE_FLOAT;
      const urlExclusiveFlags = urlFlags | BASS.BASS_STREAM_DECODE;
      handle = _bass.BASS_StreamCreateURL(
        pathPointer,
        0,
        wasapiExclusive ? urlExclusiveFlags : urlFlags,
        ffi.nullptr,
        ffi.nullptr,
      );
    } else {
      handle = _bass.BASS_StreamCreateFile(
        BASS.FALSE,
        pathPointer,
        0,
        0,
        usedFlags,
      );
    }

    if (handle != 0) {
      _fstream = handle;
      _fPath = path;
      _fIsUrl = isUrl;
    } else {
      _fstream = null;
      _fPath = null;
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_INIT:
          _bassInit();
          setSource(path, isUrl: isUrl);
          break;
        case BASS.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
              "The BASS_STREAM_AUTOFREE flag cannot be combined with the BASS_STREAM_DECODE flag.");
        case BASS.BASS_ERROR_ILLPARAM:
          throw const FormatException(
              "The length must be specified when streaming from memory.");
        case BASS.BASS_ERROR_FILEOPEN:
          throw const FormatException("The file could not be opened.");
        case BASS.BASS_ERROR_FILEFORM:
          throw const FormatException(
              "The file's format is not recognised/supported.");
        case BASS.BASS_ERROR_NOTAUDIO:
          throw const FormatException(
              "The file does not contain audio, or it also contains video and videos are disabled.");
        case BASS.BASS_ERROR_CODEC:
          throw const FormatException(
              "The file uses a codec that is not available/supported. This can apply to WAV and AIFF files.");
        case BASS.BASS_ERROR_FORMAT:
          throw const FormatException("The sample format is not supported.");
        case BASS.BASS_ERROR_SPEAKER:
          throw const FormatException(
              "The specified SPEAKER flags are invalid.");
        case BASS.BASS_ERROR_MEM:
          throw const FormatException("There is insufficient memory.");
        case BASS.BASS_ERROR_NO3D:
          throw const FormatException("Could not initialize 3D support.");
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
  }

  /// 异步设置音源，避免网络流创建阻塞 UI 线程。
  ///
  /// 本地文件依旧走同步的 [setSource]（本地读取很快，且 [BASS_ASYNCFILE]
  /// 已让实际解码异步进行）。网络流（[isUrl] 为 true）时，
  /// [BASS_StreamCreateURL] 会阻塞到连接建立并完成预缓冲，
  /// 放在后台 isolate 里执行，主线程（UI）保持流畅，切歌不再卡顿。
  ///
  /// 若在后台创建期间用户又切了歌（[_loadGeneration] 变化），
  /// 则丢弃这次创建出来的过期流句柄。
  Future<void> setSourceAsync(String path, {bool isUrl = false}) async {
    if (!isUrl) {
      setSource(path, isUrl: false);
      return;
    }

    final generation = ++_loadGeneration;
    _hasStartedPlaying = false;

    if (_fstream != null) {
      _positionUpdater?.cancel();
      freeFStream();
      _fstream = null;
      _fPath = null;
    }

    const urlFlags = BASS.BASS_UNICODE | BASS.BASS_SAMPLE_FLOAT;
    const urlExclusiveFlags = urlFlags | BASS.BASS_STREAM_DECODE;
    final usedFlags = wasapiExclusive ? urlExclusiveFlags : urlFlags;

    final bassLibPath = _resolveBassLibPath();
    final url = path;

    // 在后台 isolate 里执行阻塞的网络流创建。
    // 返回 (handle, errorCode)。BASS 句柄是进程级全局的，可在主线程使用。
    final (handle, errorCode) = await Isolate.run<(int, int)>(() {
      final lib = ffi.DynamicLibrary.open(bassLibPath);
      final bass = BASS.Bass(lib);
      final urlPointer = url.toNativeUtf16();
      final h = bass.BASS_StreamCreateURL(
        urlPointer.cast<ffi.Void>(),
        0,
        usedFlags,
        ffi.nullptr,
        ffi.nullptr,
      );
      final e = h == 0 ? bass.BASS_ErrorGetCode() : 0;
      ffi.malloc.free(urlPointer);
      return (h, e);
    });

    // 期间用户又切歌了：丢弃这次创建的流。
    if (generation != _loadGeneration) {
      if (handle != 0) {
        _bass.BASS_StreamFree(handle);
      }
      return;
    }

    if (handle != 0) {
      _fstream = handle;
      _fPath = path;
      _fIsUrl = true;
    } else {
      _fstream = null;
      _fPath = null;
      if (errorCode == BASS.BASS_ERROR_INIT) {
        _bassInit();
        await setSourceAsync(path, isUrl: isUrl);
        return;
      }
      LOGGER.e("[set source url] BASS_StreamCreateURL failed: $errorCode");
      showTextOnSnackBar("网络音源加载失败（错误码 $errorCode）");
    }
  }

  String _resolveBassLibPath() => path.join(
        path.dirname(Platform.resolvedExecutable),
        "BASS",
        "bass.dll",
      );

  /// [BASS_ATTRIB_VOLDSP] attribute does have direct effect on decoding/recording channels.
  void setVolumeDsp(double volume) {
    if (_fstream == null) return;

    if (_bass.BASS_ChannelSetAttribute(
          _fstream!,
          BASS.BASS_ATTRIB_VOLDSP,
          volume,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case BASS.BASS_ERROR_ILLTYPE:
          throw const FormatException("attrib is not valid.");
        case BASS.BASS_ERROR_ILLPARAM:
          throw const FormatException("value is not valid.");
      }
    }
  }

  void _bassWasapiInit() {
    if (_bassWasapi.BASS_WASAPI_Init(
          -1,
          0,
          0,
          BASS.BASS_WASAPI_EXCLUSIVE | BASS.BASS_WASAPI_EVENT,
          0.05,
          0,
          ffi.Pointer<BASS.WASAPIPROC>.fromAddress(-1),
          ffi.Pointer<ffi.Void>.fromAddress(_fstream!),
        ) ==
        BASS.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_WASAPI:
          throw const FormatException("WASAPI is not available.");
        case BASS.BASS_ERROR_DEVICE:
          throw const FormatException("device is invalid.");
        case BASS.BASS_ERROR_ALREADY:
          _bassWasapi.BASS_WASAPI_Free();
          _bassWasapiInit();
          break;
        case BASS.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
              "Exclusive mode and/or event-driven buffering is unavailable on the device, or WASAPIPROC_PUSH is unavailable on input devices and when using event-driven buffering.");
        case BASS.BASS_ERROR_DRIVER:
          throw const FormatException("The driver could not be initialized.");
        case BASS.BASS_ERROR_HANDLE:
          throw const FormatException(
              "The BASS channel handle in user is invalid, or not of the required type.");
        case BASS.BASS_ERROR_FORMAT:
          throw const FormatException(
              "The specified format (or that of the BASS channel) is not supported by the device. If the BASS_WASAPI_AUTOFORMAT flag was specified, no other format could be found either.");
        case BASS.BASS_ERROR_BUSY:
          throw const FormatException(
              "The device is already in use, eg. another process may have initialized it in exclusive mode.");
        case BASS.BASS_ERROR_INIT:
          _bassInit();
          _bassWasapiInit();
          break;
        case BASS.BASS_ERROR_WASAPI_BUFFER:
          throw const FormatException(
              "buffer is too large or small (exclusive mode only).");
        case BASS.BASS_ERROR_WASAPI_CATEGORY:
          throw const FormatException(
              "The category/raw mode could not be set.");
        case BASS.BASS_ERROR_WASAPI_DENIED:
          throw const FormatException(
              "Access to the device is denied. This could be due to privacy settings.");
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
  }

  void _start_wasapiExclusive() {
    _bassWasapiInit();

    if (_bassWasapi.BASS_WASAPI_Start() == BASS.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_INIT:
          _bassWasapiInit();
          _start_wasapiExclusive();
          break;
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
    _playerStateStreamController.add(playerState);
    _positionUpdater = _getPositionUpdater();
  }

  /// start/resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void start() {
    if (_fstream == null) return;

    if (wasapiExclusive) {
      return _start_wasapiExclusive();
    }
    if (_bass.BASS_ChannelStart(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case BASS.BASS_ERROR_DECODE:
          throw const FormatException(
              "handle is a decoding channel, so cannot be played.");
        case BASS.BASS_ERROR_START:
          _startDevice();
          start();
          break;
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater = _getPositionUpdater();
  }

  void _pause_wasapiExclusive() {
    if (_bassWasapi.BASS_WASAPI_Stop(BASS.FALSE) == BASS.TRUE) {
      _playerStateStreamController.add(playerState);
      _positionUpdater?.cancel();
    }
  }

  /// pause channel, call [start] to resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void pause() {
    if (_fstream == null) return;

    if (wasapiExclusive) {
      return _pause_wasapiExclusive();
    }

    if (_bass.BASS_ChannelPause(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case BASS.BASS_ERROR_DECODE:
          throw const FormatException(
              "handle is a decoding channel, so cannot be played or paused.");
        case BASS.BASS_ERROR_NOPLAY:
          throw const FormatException("The channel is not playing.");
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
  }

  /// set channel's position to given [position]
  /// don't check if the position is valid.
  ///
  /// do nothing if [setSource] hasn't been called
  void seek(double position) {
    if (_fstream == null) return;

    if (_bass.BASS_ChannelSetPosition(
          _fstream!,
          _bass.BASS_ChannelSeconds2Bytes(_fstream!, position),
          BASS.BASS_POS_BYTE,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case BASS.BASS_ERROR_NOTFILE:
          throw const FormatException("The stream is not a file stream.");
        case BASS.BASS_ERROR_POSITION:
          throw const FormatException(
              "The requested position is invalid, eg. it is beyond the end or the download has not yet reached it.");
        case BASS.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
              "The requested mode is not available. Invalid flags are ignored and do not result in this error.");
        case BASS.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
  }

  /// It is not necessary to individually free the samples/streams/musics
  /// as these are all automatically freed after [setSource] or [free] is called.
  ///
  /// do nothing if [setSource] hasn't been called
  void freeFStream() {
    if (_fstream == null) return;

    if (_bass.BASS_StreamFree(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_HANDLE:
          LOGGER.w("StreamFree is called on a invalid handle.");
          break;
        case BASS.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
              "Device streams (STREAMPROC_DEVICE) cannot be freed.");
      }
    }
  }

  /// Frees all resources used by the output device,
  /// including all its samples, streams and MOD musics.
  ///
  /// Also free the bass.dll.
  void free() {
    if (wasapiExclusive) {
      _bassWasapi.BASS_WASAPI_Free();
    }

    if (_bass.BASS_Free() == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case BASS.BASS_ERROR_INIT:
          LOGGER.w("BASS_Free is called before BASS_Init complete normally.");
          break;
        case BASS.BASS_ERROR_BUSY:
          throw const FormatException(
              "The device is currently being reinitialized.");
      }
    }

    _bassWasapiLib.close();
    _bassLib.close();

    _positionUpdater?.cancel();
    _playerStateStreamController.close();
    _positionStreamController.close();
  }
}
