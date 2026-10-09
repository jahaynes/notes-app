import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Palette of note background colors. Index 0 means "no color".
const noteColors = <Color?>[
  null,
  Color(0xFFFFCDD2),
  Color(0xFFFFE0B2),
  Color(0xFFFFF9C4),
  Color(0xFFC8E6C9),
  Color(0xFFB3E5FC),
  Color(0xFFD1C4E9),
  Color(0xFFF8BBD0),
];

class Note {
  Note({
    required this.id,
    this.title = '',
    this.body = '',
    this.colorIndex = 0,
    this.showFull = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// A blank note with a fresh unique id.
  factory Note.create() => Note(id: _uuid.v4());

  static const _uuid = Uuid();

  final String id;
  String title;
  String body;
  int colorIndex;

  /// Whether the overview card shows the whole note instead of truncating it.
  bool showFull;
  DateTime updatedAt;

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;

  Note copy() => Note(
    id: id,
    title: title,
    body: body,
    colorIndex: colorIndex,
    showFull: showFull,
    updatedAt: updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'colorIndex': colorIndex,
    'showFull': showFull,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    colorIndex: json['colorIndex'] as int? ?? 0,
    showFull: json['showFull'] as bool? ?? false,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
  );
}
