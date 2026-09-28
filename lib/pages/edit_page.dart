import 'package:flutter/material.dart';

import '../models/script.dart';
import '../services/script_store.dart';

class EditPage extends StatefulWidget {
  const EditPage({super.key, this.script});

  final Script? script;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController _title;
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    final s = widget.script;
    _title = TextEditingController(text: s?.title ?? '');
    _text = TextEditingController(text: s?.text ?? '');
  }

  Script _build() => Script(
        id: widget.script?.id ?? Script.newId(),
        title: _title.text.trim().isEmpty ? '未命名脚本' : _title.text.trim(),
        text: _text.text,
      );

  Future<void> _save() async {
    final s = _build();
    if (s.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('脚本内容不能为空')));
      return;
    }
    await ScriptStore.instance.save(s);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final charCount = _text.text.trim().length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.script == null ? '新建脚本' : '编辑脚本'),
        actions: [
          TextButton(
              onPressed: _save,
              child: const Text('保存',
                  style: TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            onChanged: (_) => setState(() {}),
            minLines: 8,
            maxLines: 16,
            decoration: const InputDecoration(
              labelText: '口播文案',
              alignLabelWithHint: true,
              hintText: '粘贴或输入你的口播稿。提词时会按屏幕宽度和字号自动换行,无需手动分行。',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text('$charCount 字',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),

        ],
      ),
    );
  }
}
