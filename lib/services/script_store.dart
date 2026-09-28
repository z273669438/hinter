import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/script.dart';

/// 脚本持久化:每份脚本一个 JSON 文件,存放在应用文档目录下。
class ScriptStore {
  ScriptStore._();
  static final ScriptStore instance = ScriptStore._();

  Directory? _dir;

  Future<Directory> _scriptsDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory(p.join(docs.path, 'hinter', 'scripts'));
    await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<File> _fileOf(String id) async =>
      File(p.join((await _scriptsDir()).path, '$id.json'));

  Future<List<Script>> list() async {
    final dir = await _scriptsDir();
    final scripts = <Script>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        scripts
            .add(Script.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // 忽略损坏的脚本文件
      }
    }
    scripts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return scripts;
  }

  Future<void> save(Script script) async {
    script.updatedAt = DateTime.now();
    await (await _fileOf(script.id))
        .writeAsString(const JsonEncoder.withIndent(' ').convert(script.toJson()));
  }

  Future<void> delete(String id) async {
    final f = await _fileOf(id);
    if (await f.exists()) await f.delete();
  }
}
