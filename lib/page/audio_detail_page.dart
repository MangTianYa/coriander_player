import 'package:coriander_player/utils.dart';
import 'package:coriander_player/library/audio_library.dart';
import 'package:coriander_player/library/jellyfin/jellyfin_source.dart';
import 'package:coriander_player/component/album_tile.dart';
import 'package:coriander_player/component/artist_tile.dart';
import 'package:coriander_player/src/rust/api/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AudioDetailPage extends StatelessWidget {
  const AudioDetailPage({super.key, required this.audio});

  final Audio audio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Jellyfin 音源的艺术家/专辑聚合在 JellyfinSource，
    // 本地音源聚合在 AudioLibrary。用错集合会因空值取用崩溃、页面变灰白。
    final isJellyfin = audio.source == AudioSourceType.jellyfin;
    final artistCollection = isJellyfin
        ? JellyfinSource.instance.artistCollection
        : AudioLibrary.instance.artistCollection;
    final albumCollection = isJellyfin
        ? JellyfinSource.instance.albumCollection
        : AudioLibrary.instance.albumCollection;

    final artists = <Artist>[
      for (final name in audio.splitedArtists)
        if (artistCollection[name] != null) artistCollection[name]!,
    ];
    final album = albumCollection[audio.album];
    const space = SizedBox(height: 12.0);

    final styleTitle = TextStyle(fontSize: 22, color: scheme.onSurface);
    final styleContent = TextStyle(fontSize: 16, color: scheme.onSurface);
    final placeholder = Icon(
      Symbols.broken_image,
      color: scheme.onSurface,
      size: 200,
    );

    return Material(
      color: scheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 96.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16.0,
              runSpacing: 16.0,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                FutureBuilder(
                  future: audio.mediumCover,
                  builder: (context, snapshot) =>
                      switch (snapshot.connectionState) {
                    ConnectionState.done => snapshot.data == null
                        ? placeholder
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(8.0),
                            child: Image(
                              image: snapshot.data!,
                              width: 200,
                              height: 200,
                              errorBuilder: (_, __, ___) => placeholder,
                            ),
                          ),
                    _ => const SizedBox(
                        width: 200,
                        height: 200,
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                  },
                ),
                Text(audio.title, style: styleTitle),
              ],
            ),
            space,

            /// artists
            _AudioDetailTile(
              title: "艺术家",
              detail: Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: List.generate(
                  artists.length,
                  (i) {
                    return SizedBox(
                      width: 300,
                      child: ArtistTile(artist: artists[i]),
                    );
                  },
                ),
              ),
            ),

            /// album
            if (album != null)
              _AudioDetailTile(
                title: "专辑",
                detail: AlbumTile(album: album),
              )
            else
              _AudioDetailTile(
                title: "专辑",
                detail: Text(audio.album, style: styleContent),
              ),
            _AudioDetailTile(
              title: "音轨",
              detail: Text(audio.track.toString()),
            ),
            _AudioDetailTile(
              title: "时长",
              detail: Text(Duration(
                milliseconds: (audio.duration * 1000).toInt(),
              ).toStringHMMSS()),
            ),
            _AudioDetailTile(
              title: "码率",
              detail: Text(audio.bitrate == null ? "未知" : "${audio.bitrate} kbps"),
            ),
            _AudioDetailTile(
              title: "采样率",
              detail:
                  Text(audio.sampleRate == null ? "未知" : "${audio.sampleRate} hz"),
            ),

            /// path / 来源
            if (isJellyfin) ...[
              Text("来源", style: styleTitle),
              const SizedBox(height: 8),
              Text(
                "Jellyfin 服务器${JellyfinSource.instance.serverName == null ? "" : "（${JellyfinSource.instance.serverName}）"}",
                style: styleContent,
              ),
              const SizedBox(height: 4),
              Text("ID：${audio.sourceId ?? "未知"}", style: styleContent),
            ] else ...[
              Wrap(
                spacing: 8.0,
                children: [
                  Text("路径", style: styleTitle),
                  TextButton(
                    onPressed: () async {
                      final result = await showInExplorer(path: audio.path);

                      if (!result && context.mounted) {
                        showTextOnSnackBar("打开失败");
                      }
                    },
                    child: const Text("在文件资源管理器中显示"),
                  )
                ],
              ),
              const SizedBox(height: 8),
              Text(audio.path, style: styleContent),
            ],
            space,

            /// modified
            _AudioDetailTile(
              title: "修改时间",
              detail: Text(
                DateTime.fromMillisecondsSinceEpoch(
                  audio.modified * 1000,
                ).toString(),
              ),
            ),

            /// created
            _AudioDetailTile(
              title: "创建时间",
              detail: Text(
                DateTime.fromMillisecondsSinceEpoch(
                  audio.created * 1000,
                ).toString(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioDetailTile extends StatelessWidget {
  const _AudioDetailTile({
    required this.title,
    required this.detail,
  });

  final String title;
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 22, color: scheme.onSurface)),
          const SizedBox(height: 4.0),
          detail,
        ],
      ),
    );
  }
}
