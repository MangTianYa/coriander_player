import 'package:coriander_player/app_preference.dart';
import 'package:coriander_player/component/audio_tile.dart';
import 'package:coriander_player/library/audio_library.dart';
import 'package:coriander_player/library/jellyfin/jellyfin_source.dart';
import 'package:coriander_player/page/page_scaffold.dart';
import 'package:coriander_player/page/uni_page.dart';
import 'package:coriander_player/page/uni_page_components.dart';
import 'package:coriander_player/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class JellyfinPage extends StatefulWidget {
  const JellyfinPage({super.key});

  @override
  State<JellyfinPage> createState() => _JellyfinPageState();
}

class _JellyfinPageState extends State<JellyfinPage> {
  final _source = JellyfinSource.instance;

  /// 正在同步（拉取音乐）
  bool _syncing = false;
  int _loaded = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    // 已登录但内存里还没有歌曲时，自动同步一次
    if (_source.isLoggedIn && _source.songs.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _loaded = 0;
      _total = 0;
    });
    try {
      await _source.fetchSongs(onProgress: (loaded, total) {
        if (!mounted) return;
        setState(() {
          _loaded = loaded;
          _total = total;
        });
      });
    } catch (err) {
      showTextOnSnackBar("同步失败：$err");
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _showLoginDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => const _JellyfinLoginDialog(),
    );
    if (ok == true && mounted) {
      setState(() {});
      _sync();
    }
  }

  Future<void> _logout() async {
    await _source.logout();
    if (mounted) setState(() {});
  }

  Future<void> _clearCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("清除缓存"),
        content: const Text("将清除本地缓存的 Jellyfin 歌曲列表。\n下次可重新同步获取。是否继续？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("清除"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _source.clearCache();
    if (mounted) {
      setState(() {});
      showTextOnSnackBar("已清除 Jellyfin 缓存");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_source.isLoggedIn) {
      return _buildLoggedOut(context);
    }
    return _buildLoggedIn(context);
  }

  Widget _buildLoggedOut(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PageScaffold(
      title: "Jellyfin",
      actions: const [],
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.cloud_off, size: 64.0, color: scheme.onSurface),
            const SizedBox(height: 16.0),
            Text(
              "连接到 Jellyfin 媒体服务器",
              style: TextStyle(color: scheme.onSurface, fontSize: 18.0),
            ),
            const SizedBox(height: 16.0),
            FilledButton.icon(
              onPressed: _showLoginDialog,
              icon: const Icon(Symbols.login),
              label: const Text("登录"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoggedIn(BuildContext context) {
    if (_syncing) {
      final scheme = Theme.of(context).colorScheme;
      return PageScaffold(
        title: "Jellyfin",
        subtitle: _source.username,
        actions: const [],
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16.0),
              Text(
                _total > 0 ? "正在同步 $_loaded / $_total" : "正在连接服务器…",
                style: TextStyle(color: scheme.onSurface),
              ),
            ],
          ),
        ),
      );
    }

    final contentList = List<Audio>.from(_source.songs);
    final multiSelectController = MultiSelectController<Audio>();

    return UniPage<Audio>(
      pref: AppPreference.instance.jellyfinPagePref,
      title: "Jellyfin",
      subtitle: "${_source.username} · ${contentList.length} 首乐曲",
      contentList: contentList,
      primaryAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            tooltip: "同步音乐库",
            onPressed: _sync,
            icon: const Icon(Symbols.sync),
          ),
          const SizedBox(width: 8.0),
          IconButton.filledTonal(
            tooltip: "清除缓存",
            onPressed: _clearCache,
            icon: const Icon(Symbols.cleaning_services),
          ),
          const SizedBox(width: 8.0),
          IconButton.filledTonal(
            tooltip: "退出登录",
            onPressed: _logout,
            icon: const Icon(Symbols.logout),
          ),
        ],
      ),
      contentBuilder: (context, item, i, multiSelectController) => AudioTile(
        audioIndex: i,
        playlist: contentList,
        multiSelectController: multiSelectController,
      ),
      enableShufflePlay: true,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: contentList,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: "标题",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.title.localeCompareTo(b.title));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.title.localeCompareTo(a.title));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.artist,
          name: "艺术家",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.artist.localeCompareTo(b.artist));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.artist.localeCompareTo(a.artist));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.album,
          name: "专辑",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.album.localeCompareTo(b.album));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.album.localeCompareTo(a.album));
                break;
            }
          },
        ),
      ],
    );
  }
}

class _JellyfinLoginDialog extends StatefulWidget {
  const _JellyfinLoginDialog();

  @override
  State<_JellyfinLoginDialog> createState() => _JellyfinLoginDialogState();
}

class _JellyfinLoginDialogState extends State<_JellyfinLoginDialog> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 预填上次登录的服务器地址和用户名
    _serverController.text = JellyfinSource.instance.baseUrl ?? "";
    _usernameController.text = JellyfinSource.instance.username ?? "";
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final server = _serverController.text.trim();
    final username = _usernameController.text.trim();
    if (server.isEmpty || username.isEmpty) {
      setState(() => _error = "请填写服务器地址和用户名");
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await JellyfinSource.instance.login(
      serverUrl: server,
      username: username,
      password: _passwordController.text,
    );

    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _loading = false;
        _error = result.error ?? "登录失败";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text("登录 Jellyfin"),
      content: SizedBox(
        width: 360.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _serverController,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: "服务器地址",
                hintText: "https://jellyfin.example.com",
                prefixIcon: Icon(Symbols.dns),
              ),
            ),
            const SizedBox(height: 16.0),
            TextField(
              controller: _usernameController,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: "用户名",
                prefixIcon: Icon(Symbols.person),
              ),
            ),
            const SizedBox(height: 16.0),
            TextField(
              controller: _passwordController,
              enabled: !_loading,
              obscureText: true,
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(
                labelText: "密码",
                prefixIcon: Icon(Symbols.password),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: _loading ? null : _login,
          child: _loading
              ? const SizedBox(
                  width: 18.0,
                  height: 18.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                )
              : const Text("登录"),
        ),
      ],
    );
  }
}
