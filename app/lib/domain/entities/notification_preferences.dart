const notificationCategories = <String, String>{
  'input_needed': 'Input needed',
  'credential_needed': 'Credential or sign-in needed',
  'task_finished': 'Task finished',
  'task_failed': 'Task failed',
  'tests_failed': 'Tests failed',
  'review_ready': 'Review ready',
  'update_available': 'Update available',
  'connection_lost': 'Connection lost',
};

const defaultNotificationCategories = {
  'input_needed',
  'credential_needed',
  'task_finished',
  'task_failed',
};
const highPriorityNotificationCategories = {
  'input_needed',
  'credential_needed',
};

class NotificationPreferences {
  final bool enabled;
  final Set<String> categories;
  final bool showPaneName;
  const NotificationPreferences({
    this.enabled = false,
    this.categories = defaultNotificationCategories,
    this.showPaneName = false,
  });
  NotificationPreferences copyWith({
    bool? enabled,
    Set<String>? categories,
    bool? showPaneName,
  }) => NotificationPreferences(
    enabled: enabled ?? this.enabled,
    categories: Set.unmodifiable(categories ?? this.categories),
    showPaneName: showPaneName ?? this.showPaneName,
  );
  Map<String, dynamic> toJson() => {
    'schema_version': 2,
    'enabled': enabled,
    'categories': categories.toList(),
    'show_pane_name': showPaneName,
  };
  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        enabled: json['enabled'] == true,
        categories: json['categories'] is List
            ? Set.unmodifiable({
                ...(json['categories'] as List).whereType<String>().where(
                  notificationCategories.containsKey,
                ),
                // Add the new default once; later explicit opt-outs survive.
                if (json['schema_version'] != 2) 'credential_needed',
              })
            : defaultNotificationCategories,
        showPaneName: json['show_pane_name'] == true,
      );
}

class NotificationTarget {
  final String peer, room, eventId;
  const NotificationTarget(this.peer, this.room, this.eventId);
  static NotificationTarget? parse(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        !notificationCategories.containsKey(value['kind'])) {
      return null;
    }
    final peer = value['peer'], room = value['room'], event = value['event_id'];
    if (peer is! String ||
        room is! String ||
        event is! String ||
        peer.isEmpty ||
        peer.length > 128 ||
        room.isEmpty ||
        room.length > 256 ||
        event.isEmpty ||
        event.length > 256) {
      return null;
    }
    return NotificationTarget(peer, room, event);
  }
}
