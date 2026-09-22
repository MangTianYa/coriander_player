import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:coriander_player/app_settings.dart';
import 'package:coriander_player/src/rust/api/tag_reader.dart';
import 'package:coriander_player/utils.dart';
import 'package:flutter/painting.dart';

/// 音乐来源
enum AudioSourceType {
  /// 本地文件
  local,

  /// Jellyfin 媒体服务器
  jellyfin;

  static AudioSourceType fromName(String? name) {
    for (var value in AudioSourceType.values) {
      if (value.name == name) return value;
    }
    return AudioSourceType.local;
  }
}

/// 由 Jellyfin 模块注册：根据 item id 实时生成带鉴权的流地址。
///
/// 采用「运行时解析」而非「存储完整 URL」，避免把 AccessToken（api_key）
/// 随 [Audio.toMap] 写入 playlists.json 等文件（那会绕过 DPAPI 加密），
/// 同时保证重新登录、token 轮换后地址依然有效。
String? Function(String sourceId)? jellyfinStreamUrlResolver;

/// 由 Jellyfin 模块注册：根据封面所在 item id 实时生成带鉴权的图片地址。
String? Function(String coverItemId)? jellyfinCoverUrlResolver;

/// from index.json
class AudioLibrary {
  List<AudioFolder> folders;

  AudioLibrary._(this.folders);

  /// 所有音乐
  List<Audio> audioCollection = [];

  Map<String, Artist> artistCollection = {};

  Map<String, Album> albumCollection = {};

  /// must call [initFromIndex]
  static AudioLibrary get instance {
    _instance ?? AudioLibrary._([]);
    return _instance!;
  }

  static AudioLibrary? _instance;

  /// 目前 index 结构：
  /// ```json
  /// {
  ///     "folders": [
  ///         {
  ///             "audios": [
  ///                 {...},
  ///                 ...
  ///             ],
  ///             ...
  ///         },
  ///         ...
  ///     ],
  ///     "version": 110
  /// }
  /// ```
  static Future<void> initFromIndex() async {
    try {
      final supportPath = (await getAppDataDir()).path;
      final indexPath = "$supportPath\\index.json";

      final indexStr = File(indexPath).readAsStringSync();
      final Map indexJson = json.decode(indexStr);
      final List foldersJson = indexJson["folders"];
      final List<AudioFolder> folders = [];

      for (Map folderMap in foldersJson) {
        final List audiosJson = folderMap["audios"];
        final List<Audio> audios = [];
        for (Map audioMap in audiosJson) {
          audios.add(Audio.fromMap(audioMap));
        }
        folders.add(AudioFolder.fromMap(folderMap, audios));
      }

      _instance = AudioLibrary._(folders);

      instance.artistCollection.clear();
      instance.albumCollection.clear();
      instance._buildCollections();
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }

  void _buildCollections() {
    for (var f in folders) {
      audioCollection.addAll(f.audios);
    }

    for (Audio audio in audioCollection) {
      for (String artistName in audio.splitedArtists) {
        /// 如果artistCollection中有artistName指向的artist，putIfAbsent会返回该artist。
        /// 随后往这个artist里添加该audio。
        ///
        /// 如果没有，创建一个名字为artistName的空艺术家，并将artistName与之相连。
        /// 随后往这个artist里添加该audio。
        artistCollection
            .putIfAbsent(artistName, () => Artist(name: artistName))
            .works
            .add(audio);
      }

      /// 如果albumCollection中有audio.album指向的album，putIfAbsent会返回该album。
      /// 随后往这个album里添加该audio。
      ///
      /// 如果没有，创建一个名字为audio.album的空艺术家，并将audio.album与之相连。
      /// 随后往这个album里添加该audio。
      albumCollection
          .putIfAbsent(audio.album, () => Album(name: audio.album))
          .works
          .add(audio);
    }

    /// 将艺术家和专辑链接起来
    for (Artist artist in artistCollection.values) {
      for (Audio audio in artist.works) {
        artist.albumsMap.putIfAbsent(
          audio.album,
          () => albumCollection[audio.album]!,
        );
      }
    }

    /// 将专辑和艺术家链接起来
    for (Album album in albumCollection.values) {
      for (Audio audio in album.works) {
        for (String artistName in audio.splitedArtists) {
          album.artistsMap.putIfAbsent(
            artistName,
            () => artistCollection[artistName]!,
          );
        }
      }
    }
  }

  @override
  String toString() {
    return folders.toString();
  }
}

class AudioFolder {
  List<Audio> audios;

  /// absolute path
  String path;

  /// secs since UNIX EPOCH
  int modified;

  /// secs since UNIX EPOCH
  int latest;

  AudioFolder(this.audios, this.path, this.modified, this.latest);

  factory AudioFolder.fromMap(Map map, List<Audio> audios) =>
      AudioFolder(audios, map["path"], map["modified"], map["latest"]);

  @override
  String toString() {
    return {
      "audios": audios.toString(),
      "path": path,
      "modified":
          DateTime.fromMillisecondsSinceEpoch(modified * 1000).toString(),
    }.toString();
  }
}

class Audio {
  String title;

  /// 从音乐标签中读取的艺术家字符串，可能包含多个艺术家，以“、”，“/”等分隔。
  String artist;

  /// 分割[artist]得到的结果
  List<String> splitedArtists;

  String album;

  /// 0: 没有track
  int track;

  /// audio's duration in secs
  int duration;

  /// kbps
  int? bitrate;

  int? sampleRate;

  /// 本地文件：绝对路径；
  /// 远程（Jellyfin）：形如 `jellyfin://{itemId}` 的合成唯一键。
  /// 无论何种来源，[path] 都作为全局唯一标识（歌单、歌词来源、封面缓存的 key）。
  String path;

  /// secs since UNIX EPOCH
  int modified;

  /// secs since UNIX EPOCH
  int created;

  /// 标签来源（Lofty、Windows、null）
  String? by;

  /// 音乐来源：本地文件或 Jellyfin
  AudioSourceType source;

  /// 远程音源在服务器上的 id（如 Jellyfin item id）。本地音源为 null。
  String? sourceId;

  /// 远程音源封面所在的 item id（可能是曲目自身或所属专辑）。
  /// 为 null 表示没有封面。不含 token，可安全落盘。
  String? coverItemId;

  ImageProvider? _cover;

  /// 是否为远程音源
  bool get isRemote => source != AudioSourceType.local;

  /// 交给播放器的地址：远程音源实时解析出带鉴权的流地址，本地音源为文件路径。
  /// 未登录 / 无法解析时回退为 [path]（BASS 会报错并提示，属预期行为）。
  String get playablePath {
    if (isRemote && sourceId != null) {
      return jellyfinStreamUrlResolver?.call(sourceId!) ?? path;
    }
    return path;
  }

  /// 以“、”和“/”分割艺术家，会把名称中带有这些符号的艺术家分割。
  /// 暂时想不到别的方法。
  Audio(
    this.title,
    this.artist,
    this.album,
    this.track,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.path,
    this.modified,
    this.created,
    this.by, {
    this.source = AudioSourceType.local,
    this.sourceId,
    this.coverItemId,
  }) : splitedArtists = artist.split(
          RegExp(AppSettings.instance.artistSplitPattern),
        );

  factory Audio.fromMap(Map map) => Audio(
        map["title"],
        map["artist"],
        map["album"],
        map["track"] ?? 0,
        map["duration"] ?? 0,
        map["bitrate"],
        map["sample_rate"],
        map["path"],
        map["modified"],
        map["created"],
        map["by"],
        source: AudioSourceType.fromName(map["source"]),
        sourceId: map["source_id"],
        coverItemId: map["cover_item_id"],
      );

  Map toMap() => {
        "title": title,
        "artist": artist,
        "album": album,
        "track": track,
        "duration": duration,
        "bitrate": bitrate,
        "sample_rate": sampleRate,
        "path": path,
        "modified": modified,
        "created": created,
        "by": by,
        "source": source.name,
        "source_id": sourceId,
        "cover_item_id": coverItemId,
      };

  /// 读取音乐图片，自动适应缩放。
  /// 本地音源从文件标签读取；远程音源从服务器图片地址加载。
  Future<ImageProvider?> _getResizedPic({
    required int width,
    required int height,
  }) async {
    final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final w = (width * ratio).round();
    final h = (height * ratio).round();

    if (isRemote) {
      if (coverItemId == null) return null;

      final base = jellyfinCoverUrlResolver?.call(coverItemId!);
      if (base == null) return null;

      /// 让服务器按需返回合适尺寸的图片，减少流量与内存
      final sep = base.contains("?") ? "&" : "?";
      final sizedUrl = "$base${sep}fillWidth=$w&fillHeight=$h";
      return ResizeImage(NetworkImage(sizedUrl), width: w, height: h);
    }

    return getPictureFromPath(
      path: path,
      width: w,
      height: h,
    ).then((pic) {
      if (pic == null) return null;

      return MemoryImage(pic);
    });
  }

  /// 缓存ImageProvider而不是Uint8List（bytes）
  /// 缓存bytes时，每次加载图片都要重新解码，内存占用很大。快速滚动时能到700mb
  /// 缓存ImageProvider不用重新解码。快速滚动时最多250mb
  /// 48*48
  Future<ImageProvider?> get cover {
    if (_cover == null) {
      return _getResizedPic(width: 48, height: 48).then((value) {
        if (value == null) return null;

        _cover = value;
        return _cover;
      });
    }
    return Future.value(_cover);
  }

  /// audio detail page 不需要频繁调用，所以不缓存图片
  /// 200 * 200
  Future<ImageProvider?> get mediumCover =>
      _getResizedPic(width: 200, height: 200);

  /// now playing 不需要频繁调用，所以不缓存图片
  /// size: 400 * devicePixelRatio（屏幕缩放大小）
  Future<ImageProvider?> get largeCover =>
      _getResizedPic(width: 400, height: 400);

  @override
  String toString() {
    return {
      "title": title,
      "artist": artist,
      "album": album,
      "path": path,
      "modified":
          DateTime.fromMillisecondsSinceEpoch(modified * 1000).toString(),
      "created": DateTime.fromMillisecondsSinceEpoch(created * 1000).toString(),
    }.toString();
  }
}

class Artist {
  String name;

  /// 所有专辑
  Map<String, Album> albumsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 只能用在artist detail page
  /// 200*200
  Future<ImageProvider?> get picture =>
      works.first._getResizedPic(width: 200, height: 200);

  Artist({required this.name});
}

class Album {
  String name;

  /// 参与的艺术家
  Map<String, Artist> artistsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 只能用在album detail page
  /// 200*200
  Future<ImageProvider?> get cover =>
      works.first._getResizedPic(width: 200, height: 200);

  Album({required this.name});
}
