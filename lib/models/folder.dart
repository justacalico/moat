class Folder {
  Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.clock,
    this.colorIndex = -1,
    this.deleted = false,
  });

  final String id;
  String name;
  int colorIndex;
  bool deleted;
  DateTime createdAt;
  Map<String, int> clock;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorIndex': colorIndex,
        'deleted': deleted,
        'createdAt': createdAt.toIso8601String(),
        'clock': clock,
      };

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['colorIndex'] as int? ?? -1,
        deleted: json['deleted'] as bool? ?? false,
        createdAt: DateTime.parse(json['createdAt'] as String),
        clock: (json['clock'] as Map? ?? {}).cast<String, int>(),
      );
}
