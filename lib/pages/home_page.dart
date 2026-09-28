import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/script.dart';
import '../services/crash_reporter.dart';
import '../services/script_store.dart';
import 'edit_page.dart';
import 'teleprompter_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Script>? _scripts;

  @override
  void initState() {
    super.initState();
    _reload();
    _maybeShowCrashReport();
  }

  /// 上次闪退的堆栈(原生层落盘),弹窗让用户复制反馈
  Future<void> _maybeShowCrashReport() async {
    final crash = await CrashReporter.instance.lastCrash();
    if (crash == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检测到上次异常退出'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请截图或复制以下内容发给开发者,可帮助快速定位问题:',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    crash,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: crash));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('已复制')));
              }
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () async {
              await CrashReporter.instance.clear();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('清除并关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _reload() async {
    final list = await ScriptStore.instance.list();
    if (mounted) setState(() => _scripts = list);
  }

  Future<void> _openEdit([Script? script]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditPage(script: script),
    ));
    _reload();
  }

  Future<void> _openPrompter(Script script) async {
    if (script.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('脚本是空的,先写点内容吧')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TeleprompterPage(script: script),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scripts = _scripts;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Hinter 口播提词器',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(),
        icon: const Icon(Icons.add),
        label: const Text('新建脚本'),
      ),
      body: scripts == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                if (scripts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                        child: Text('还没有脚本\n点右下角新建一份口播稿',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38))),
                  ),
                for (final s in scripts)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      title: Text(s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${s.text.trim().characters.take(40).join()}'
                        '${s.text.trim().length > 40 ? '…' : ''}\n'
                        '共 ${s.text.trim().length} 字',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.play_circle_fill,
                            color: Color(0xFFFFB300), size: 34),
                        tooltip: '开始口播',
                        onPressed: () => _openPrompter(s),
                      ),
                      onTap: () => _openEdit(s),
                      onLongPress: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text('删除「${s.title}」?'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await ScriptStore.instance.delete(s.id);
                          _reload();
                        }
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}
