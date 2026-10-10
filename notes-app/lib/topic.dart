import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// A named group of notes.
@immutable
class Topic {
  const Topic({required this.id, required this.name});

  /// A topic with [name] and a fresh unique id.
  factory Topic.create(String name) => Topic(id: _uuid.v4(), name: name);

  /// The default topic. It always exists and can't be deleted.
  static const uncategorised = Topic(
    id: 'uncategorised',
    name: 'Uncategorised',
  );

  static const _uuid = Uuid();

  final String id;
  final String name;

  bool get isDefault => id == uncategorised.id;

  @override
  bool operator ==(Object other) =>
      other is Topic && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Topic.fromJson(Map<String, dynamic> json) =>
      Topic(id: json['id'] as String, name: json['name'] as String? ?? '');
}
