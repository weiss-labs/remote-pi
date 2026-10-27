import 'dart:convert';
import 'package:app/data/notifications/notification_grant.dart';
import 'package:app/domain/entities/notification_preferences.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  NotifyRegister message(bool? preview) => NotifyRegister(
    id: 'id',
    deviceId: 'device',
    token: 'token',
    environment: 'sandbox',
    categories: ['input_needed'],
    showPaneName: true,
    showQuestionPreview: preview,
    expiresAt: 123,
    signature: 'sig',
  );
  test(
    'absent preview is unchanged v1; explicit false and true sign ordered v2',
    () {
      expect(
        utf8.decode(notificationGrantBytes('peer', 'phone', message(null))),
        'remote-pi-notify-device-v1\n["peer","phone","device","token","sandbox",["input_needed"],true,123]',
      );
      expect(
        message(null).toJson().containsKey('show_question_preview'),
        false,
      );
      for (final preview in [false, true]) {
        expect(
          utf8.decode(
            notificationGrantBytes('peer', 'phone', message(preview)),
          ),
          'remote-pi-notify-device-v2\n["peer","phone","device","token","sandbox",["input_needed"],true,$preview,123]',
        );
        expect(message(preview).toJson()['show_question_preview'], preview);
      }
    },
  );
  test(
    'legacy choices preserved; question preview defaults off and needs names',
    () {
      final old = NotificationPreferences.fromJson({
        'schema_version': 2,
        'enabled': true,
        'show_pane_name': true,
        'categories': ['task_finished'],
      });
      expect(old.categories, {'task_finished'});
      expect(old.showQuestionPreview, false);
      final opted = old.copyWith(showQuestionPreview: true);
      expect(opted.showQuestionPreview, true);
      expect(opted.copyWith(showPaneName: false).showQuestionPreview, false);
      expect(
        NotificationPreferences.fromJson({
          'show_question_preview': true,
        }).showQuestionPreview,
        false,
      );
      expect(
        NotificationPreferences.fromJson(opted.toJson()).showQuestionPreview,
        true,
      );
    },
  );
}
