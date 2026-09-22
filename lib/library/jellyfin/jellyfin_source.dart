import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:coriander_player/app_settings.dart';
import 'package:coriander_player/library/audio_library.dart';
import 'package:coriander_player/library/jellyfin/dpapi.dart';
import 'package:coriander_player/lyric/lrc.dart';
import 'package:coriander_player/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Jellyfin 客户端相关常量
const String _kClientName = "Coriander Player";
const String _kDeviceName = "Coriander Player Desktop";

/// 连接结果
class JellyfinAuthResult {
  final bool success;
  final String? error;

  const JellyfinAuthResult(this.success, [this.error]);
}

/// Jellyfin 媒体服务器音源。
///
/// 负责：登录鉴权、拉取音乐、把 Jellyfin item 转换为 [Audio]、配置持久化。
///
/// 说明：AccessToken 属于敏感信息，和其他配置一样以明文保存在
/// `%Documents%\coriander_player\jellyfin.json`（与本项目既有配置的存储方式一致）。
class JellyfinSource {
  JellyfinSource._() {
    // 注册运行时 URL 解析器：把 token 留在内存，不写入任何持久化文件
    jellyfinStreamUrlResolver = (sourceId) {
      if (!isLoggedIn) return null;
      return "$baseUrl/Audio/$sourceId/stream?static=true&api_key=$accessToken";
    };
    jellyfinCoverUrlResolver = (coverItemId) {
      if (!isLoggedIn) return null;
      return "$baseUrl/Items/$coverItemId/Images/Primary?api_key=$accessToken";
    };
  }

  static final JellyfinSource _instance = JellyfinSource._();
  static JellyfinSource get instance => _instance;

  /// 服务器地址，形如 `https://jellyfin.example.com`（不含结尾斜杠）
  String? baseUrl;
  String? username;
  String? userId;
  String? accessToken;
  String? serverName;

  /// 设备唯一标识（首次使用时生成并持久化）
  String? deviceId;

  /// 拉取到的 Jellyfin 歌曲（内存缓存）
  List<Audio> songs = [];

  /// 按专辑、艺术家聚合，供浏览页使用
  Map<String, Album> albumCollection = {};
  Map<String, Artist> artistCollection = {};

  bool get isLoggedIn =>
      baseUrl != null && accessToken != null && userId != null;

  final _client = http.Client();

  /// 生成 Jellyfin 要求的 Authorization 头。
  /// 这是 Jellyfin 12.0 仍然支持的登录/鉴权方式（`MediaBrowser` 方案）。
  String _authHeader() {
    final buffer = StringBuffer('MediaBrowser ');
    buffer.write('Client="$_kClientName", ');
    buffer.write('Device="$_kDeviceName", ');
    buffer.write('DeviceId="${deviceId ?? "unknown"}", ');
    buffer.write('Version="${AppSettings.version}"');
    if (accessToken != null) {
      buffer.write(', Token="$accessToken"');
    }
    return buffer.toString();
  }

  Map<String, String> _headers() => {
        "Authorization": _authHeader(),
        "Content-Type": "application/json",
        "Accept": "application/json",
      };

  /// 规范化服务器地址：去掉结尾斜杠，补全 scheme
  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.endsWith("/")) u = u.substring(0, u.length - 1);
    if (!u.startsWith("http://") && !u.startsWith("https://")) {
      u = "http://$u";
    }
    return u;
  }

  static String _genDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
  }

  /// 使用用户名和密码登录 Jellyfin 服务器
  Future<JellyfinAuthResult> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    try {
      final base = _normalizeBaseUrl(serverUrl);
      deviceId ??= _genDeviceId();

      // 登录时还没有 token
      accessToken = null;
      final resp = await _client
          .post(
            Uri.parse("$base/Users/AuthenticateByName"),
            headers: {
              "Authorization": _authHeader(),
              "Content-Type": "application/json",
              "Accept": "application/json",
            },
            body: json.encode({"Username": username, "Pw": password}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        return JellyfinAuthResult(
          false,
          "登录失败：${resp.statusCode} ${resp.reasonPhrase ?? ""}",
        );
      }

      final Map body = json.decode(utf8.decode(resp.bodyBytes));
      baseUrl = base;
      this.username = username;
      accessToken = body["AccessToken"];
      userId = (body["User"] as Map?)?["Id"];
      serverName = body["ServerId"];

      if (accessToken == null || userId == null) {
        return const JellyfinAuthResult(false, "服务器未返回有效的登录凭证");
      }

      await saveConfig();
      return const JellyfinAuthResult(true);
    } on SocketException {
      return const JellyfinAuthResult(false, "无法连接到服务器，请检查地址与网络");
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
      return JellyfinAuthResult(false, err.toString());
    }
  }

  /// 退出登录并清除本地配置
  Future<void> logout() async {
    try {
      if (isLoggedIn) {
        await _client
            .post(Uri.parse("$baseUrl/Sessions/Logout"), headers: _headers())
            .timeout(const Duration(seconds: 10));
      }
    } catch (err) {
      LOGGER.w("[jellyfin logout] $err");
    } finally {
      accessToken = null;
      userId = null;
      username = null;
      serverName = null;
      await clearCache();
      await saveConfig();
    }
  }

  /// 把 Jellyfin 音乐 item 转换成 [Audio]
  Audio _itemToAudio(Map item) {
    final id = item["Id"] as String;
    final title = (item["Name"] as String?) ?? "未知标题";
    final artists =
        (item["Artists"] as List?)?.whereType<String>().toList() ?? const [];
    final artistStr = artists.isEmpty
        ? ((item["AlbumArtist"] as String?) ?? "未知艺术家")
        : artists.join("、");
    final album = (item["Album"] as String?) ?? "未知专辑";
    final track = (item["IndexNumber"] as int?) ?? 0;
    final runTimeTicks = (item["RunTimeTicks"] as num?) ?? 0;
    final duration = (runTimeTicks / 10000000).round();

    int created = 0;
    final dateCreated = item["DateCreated"] as String?;
    if (dateCreated != null) {
      created =
          (DateTime.tryParse(dateCreated)?.millisecondsSinceEpoch ?? 0) ~/ 1000;
    }

    // 从 MediaStreams 里读取音频流的采样率与码率
    int? bitrate;
    int? sampleRate;
    final mediaStreams = item["MediaStreams"] as List?;
    if (mediaStreams != null) {
      for (final s in mediaStreams) {
        if (s is Map && s["Type"] == "Audio") {
          final sr = s["SampleRate"];
          if (sr is num) sampleRate = sr.toInt();
          final br = s["BitRate"];
          if (br is num) bitrate = (br / 1000).round(); // bps -> kbps
          break;
        }
      }
    }

    // 封面所在 item：优先曲目自身的 Primary，其次专辑
    String? coverItemId;
    final imageTags = item["ImageTags"] as Map?;
    if (imageTags != null && imageTags["Primary"] != null) {
      coverItemId = id;
    } else if (item["AlbumId"] != null) {
      coverItemId = item["AlbumId"] as String;
    }

    return Audio(
      title,
      artistStr,
      album,
      track,
      duration,
      bitrate,
      sampleRate,
      "jellyfin://$id",
      created,
      created,
      "Jellyfin",
      source: AudioSourceType.jellyfin,
      sourceId: id,
      coverItemId: coverItemId,
    );
  }

  /// 从服务器分页拉取全部音乐
  Future<void> fetchSongs({
    void Function(int loaded, int total)? onProgress,
  }) async {
    if (!isLoggedIn) return;

    const pageSize = 200;
    int startIndex = 0;
    int total = -1;
    final List<Audio> result = [];

    while (true) {
      final uri = Uri.parse("$baseUrl/Items").replace(queryParameters: {
        "UserId": userId!,
        "IncludeItemTypes": "Audio",
        "Recursive": "true",
        "Fields": "DateCreated,MediaStreams",
        "SortBy": "AlbumArtist,Album,SortName",
        "SortOrder": "Ascending",
        "StartIndex": "$startIndex",
        "Limit": "$pageSize",
      });

      final resp = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode != 200) {
        throw HttpException(
          "拉取音乐失败：${resp.statusCode} ${resp.reasonPhrase ?? ""}",
        );
      }

      final Map body = json.decode(utf8.decode(resp.bodyBytes));
      final items = (body["Items"] as List?) ?? const [];
      total = (body["TotalRecordCount"] as int?) ?? items.length;

      for (final item in items) {
        try {
          result.add(_itemToAudio(item as Map));
        } catch (err) {
          // 单条数据异常不影响整体同步
          LOGGER.w("[jellyfin] 跳过无法解析的曲目：$err");
        }
      }

      onProgress?.call(result.length, total);

      startIndex += pageSize;
      if (items.isEmpty || result.length >= total) break;
    }

    songs = result;
    _buildCollections();
    await saveSongsCache();
  }

  /// 按专辑、艺术家聚合（供浏览使用）
  void _buildCollections() {
    albumCollection = {};
    artistCollection = {};

    for (final audio in songs) {
      for (final artistName in audio.splitedArtists) {
        artistCollection
            .putIfAbsent(artistName, () => Artist(name: artistName))
            .works
            .add(audio);
      }
      albumCollection
          .putIfAbsent(audio.album, () => Album(name: audio.album))
          .works
          .add(audio);
    }

    for (final artist in artistCollection.values) {
      for (final audio in artist.works) {
        artist.albumsMap.putIfAbsent(
          audio.album,
          () => albumCollection[audio.album]!,
        );
      }
    }
    for (final album in albumCollection.values) {
      for (final audio in album.works) {
        for (final artistName in audio.splitedArtists) {
          final artist = artistCollection[artistName];
          if (artist != null) {
            album.artistsMap.putIfAbsent(artistName, () => artist);
          }
        }
      }
    }
  }

  /// 从 Jellyfin 服务器获取歌曲歌词。
  ///
  /// 使用 Jellyfin 10.9+/12.0 的 `/Audio/{itemId}/Lyrics` 接口，
  /// 返回形如 `{ "Lyrics": [ { "Text": "...", "Start": <ticks> }, ... ] }`。
  /// `Start` 单位为 tick（100ns），需换算为毫秒。
  ///
  /// 若服务器没有该曲目的歌词、接口不可用或解析失败，返回 null（交由上层回退到在线匹配）。
  Future<Lrc?> getLyric(Audio audio) async {
    if (!isLoggedIn) return null;
    if (audio.source != AudioSourceType.jellyfin || audio.sourceId == null) {
      return null;
    }

    try {
      final uri = Uri.parse("$baseUrl/Audio/${audio.sourceId}/Lyrics");
      final resp = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return null;

      final Map body = json.decode(utf8.decode(resp.bodyBytes));
      final lyricList = (body["Lyrics"] as List?) ?? const [];
      if (lyricList.isEmpty) return null;

      final lines = <LrcLine>[];
      for (final item in lyricList) {
        if (item is! Map) continue;
        final text = (item["Text"] as String?) ?? "";
        final startTicks = item["Start"] as num?;
        final startMs = startTicks == null ? 0 : (startTicks / 10000).round();
        lines.add(LrcLine(
          Duration(milliseconds: startMs),
          text,
          isBlank: text.trim().isEmpty,
        ));
      }

      if (lines.isEmpty) return null;

      // 计算每行时长（下一行起始 - 本行起始）
      for (var i = 0; i < lines.length - 1; i++) {
        final delta = lines[i + 1].start - lines[i].start;
        lines[i].length = delta.isNegative ? Duration.zero : delta;
      }
      lines.last.length = Duration.zero;

      return Lrc(lines, LrcSource.web);
    } catch (err, trace) {
      LOGGER.w("[jellyfin lyric] $err", stackTrace: trace);
      return null;
    }
  }

  Future<File> get _configFile async {
    final dir = (await getAppDataDir()).path;
    return File(p.join(dir, "jellyfin.json"));
  }

  Future<File> get _songsCacheFile async {
    final dir = (await getAppDataDir()).path;
    return File(p.join(dir, "jellyfin_songs.json"));
  }

  /// 把当前歌曲列表缓存到本地，避免每次启动都要联网同步。
  /// 只缓存非敏感的元数据（[Audio.toMap]，不含 token）。
  Future<void> saveSongsCache() async {
    try {
      final file = await _songsCacheFile;
      await file.create(recursive: true);
      final data = songs.map((a) => a.toMap()).toList();
      file.writeAsStringSync(json.encode(data));
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }

  /// 从本地缓存读取歌曲列表。缓存不存在或解析失败时保持 songs 为空。
  Future<void> readSongsCache() async {
    try {
      final file = await _songsCacheFile;
      if (!file.existsSync()) return;

      final List data = json.decode(file.readAsStringSync());
      final result = <Audio>[];
      for (final item in data) {
        try {
          result.add(Audio.fromMap(item as Map));
        } catch (err) {
          LOGGER.w("[jellyfin cache] 跳过无法解析的曲目：$err");
        }
      }
      songs = result;
      _buildCollections();
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }

  /// 清除本地缓存（歌曲列表及内存聚合），保留登录状态。
  Future<void> clearCache() async {
    try {
      final file = await _songsCacheFile;
      if (file.existsSync()) file.deleteSync();
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
    songs = [];
    albumCollection = {};
    artistCollection = {};
  }

  /// 从 jellyfin.json 读取配置
  Future<void> readConfig() async {
    try {
      final file = await _configFile;
      if (!file.existsSync()) return;

      final Map map = json.decode(file.readAsStringSync());
      baseUrl = map["baseUrl"];
      username = map["username"];
      userId = map["userId"];
      serverName = map["serverName"];
      deviceId = map["deviceId"] ?? _genDeviceId();

      // AccessToken 使用 DPAPI 加密存储；旧版明文也能被 unprotect 兼容读取
      final storedToken = map["accessToken"] as String?;
      if (storedToken != null && storedToken.isNotEmpty) {
        accessToken = Dpapi.instance.unprotect(storedToken);
        // 若读取到的是旧版明文（没有 dpapi 前缀），重新以密文写回
        if (accessToken != null &&
            !storedToken.startsWith(Dpapi.prefix)) {
          await saveConfig();
        }
      } else {
        accessToken = null;
      }

      // 已登录则加载本地歌曲缓存，无需每次启动都联网同步
      if (isLoggedIn) {
        await readSongsCache();
      }
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }

  /// 保存配置到 jellyfin.json
  Future<void> saveConfig() async {
    try {
      final file = await _configFile;
      final map = {
        "baseUrl": baseUrl,
        "username": username,
        "userId": userId,
        // AccessToken 用 DPAPI（当前用户作用域）加密后保存
        "accessToken":
            accessToken == null ? null : Dpapi.instance.protect(accessToken!),
        "serverName": serverName,
        "deviceId": deviceId,
      };
      await file.create(recursive: true);
      file.writeAsStringSync(json.encode(map));
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }
}
