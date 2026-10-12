import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'topic.dart';

/// The person whose notes these are.
@immutable
class User {
  const User({required this.id, required this.defaultTopic});

  /// A new user with a fresh unique id and their own default topic. The ids
  /// are generated here, so a backend can be told about the user later
  /// without renaming anything.
  factory User.create() =>
      User(id: _uuid.v4(), defaultTopic: Topic.create('Uncategorised'));

  static const _uuid = Uuid();

  final String id;

  /// The topic notes go to when they have no other. It always exists and
  /// can't be deleted.
  final Topic defaultTopic;

  @override
  bool operator ==(Object other) =>
      other is User && other.id == id && other.defaultTopic == defaultTopic;

  @override
  int get hashCode => Object.hash(id, defaultTopic);

  Map<String, dynamic> toJson() => {
    'id': id,
    'defaultTopic': defaultTopic.toJson(),
  };

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as String,
    defaultTopic: Topic.fromJson(json['defaultTopic'] as Map<String, dynamic>),
  );
}
