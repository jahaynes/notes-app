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

/// An immutable note. Use [copyWith] to derive a changed version.
@immutable
class Note {
  Note({
    required this.id,
    this.title = '',
    this.body = '',
    this.colorIndex = 0,
    this.showFull = false,
    required this.topicId,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// A blank note in [topicId] with a fresh unique id.
  factory Note.create({required String topicId}) =>
      Note(id: _uuid.v4(), topicId: topicId);

  static const _uuid = Uuid();

  final String id;
  final String title;
  final String body;
  final int colorIndex;

  /// Whether the overview card shows the whole note instead of truncating it.
  final bool showFull;

  /// The id of the [Topic] this note belongs to.
  final String topicId;
  final DateTime updatedAt;

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;

  Note copyWith({
    String? title,
    String? body,
    int? colorIndex,
    bool? showFull,
    String? topicId,
    DateTime? updatedAt,
  }) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    colorIndex: colorIndex ?? this.colorIndex,
    showFull: showFull ?? this.showFull,
    topicId: topicId ?? this.topicId,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.colorIndex == colorIndex &&
      other.showFull == showFull &&
      other.topicId == topicId &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(id, title, body, colorIndex, showFull, topicId, updatedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'colorIndex': colorIndex,
    'showFull': showFull,
    'topicId': topicId,
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// Decodes a note, putting it in [defaultTopicId] if it was saved before
  /// notes had topics.
  factory Note.fromJson(
    Map<String, dynamic> json, {
    required String defaultTopicId,
  }) => Note(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    colorIndex: json['colorIndex'] as int? ?? 0,
    showFull: json['showFull'] as bool? ?? false,
    topicId: json['topicId'] as String? ?? defaultTopicId,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
  );
}
