import 'dart:io';

import 'package:flutter/services.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';

/// Test-only system font loading. These bytes never enter the app bundle.
Future<void> loadSystemMono() async {
  final file = File('/System/Library/Fonts/Menlo.ttc');
  if (!await file.exists()) {
    return; // Flutter's deterministic test font elsewhere.
  }
  final loader = FontLoader(kMonoFamily);
  loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  await loader.load();
}

/// Test-only stand-in for the platform sans used by draft cards.
Future<void> loadSystemSans() async {
  final file = File('/System/Library/Fonts/Helvetica.ttc');
  if (!await file.exists()) return;
  final loader = FontLoader(kCardSansFamily);
  loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  await loader.load();
}
