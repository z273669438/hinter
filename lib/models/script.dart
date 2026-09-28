/// 口播脚本。
class Script {
  Script({
    required this.id,
    required this.title,
    required this.text,
    DateTime? updatedAt,
    this.followThreshold = 0.9,
  }) : updatedAt = updatedAt ?? DateTime.now();

  String id;
  String title;
  String text;
  DateTime updatedAt;

  /// 语音跟随灵敏度:当前片段被念到的比例超过该值即前进 (0.5 ~ 1.0)
  double followThreshold;

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'text': text,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'followThreshold': followThreshold,
      };

  factory Script.fromJson(Map<String, dynamic> j) => Script(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '未命名脚本',
        text: (j['text'] as String?) ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
        followThreshold: (j['followThreshold'] as num?)?.toDouble() ?? 0.9,
      );
}
