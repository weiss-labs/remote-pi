import 'dart:async';
import 'package:app/data/actions/pane_commands_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/pane_commands.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'paired-key',
  sessionName: 'Mac',
  relayUrl: 'https://example.invalid',
  pairedAt: '2026-01-01',
  roomId: 'room-a',
);

class Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => [];
}

class Channel implements IChannel {
  final incoming = StreamController<ServerMessage>.broadcast(sync: true);
  final sent = <ClientMessage>[];
  @override
  Stream<ServerMessage> get serverMessages => incoming.stream;
  @override
  Future<void> send(ClientMessage message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {}
}

Future<void> flush() => Future<void>.delayed(Duration.zero);
void main() {
  late Channel channel;
  late ConnectionManager conn;
  late PaneCommandsRepository repo;
  setUp(() async {
    channel = Channel();
    conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: Storage(),
    );
    await conn.connectTo(peer);
    repo = PaneCommandsRepository(conn, timeout: const Duration(seconds: 2));
  });
  tearDown(() async {
    repo.dispose();
    conn.dispose();
    await channel.incoming.close();
  });
  void listReply(
    String id, {
    String name = 'compact',
    bool supported = true,
    bool available = true,
  }) {
    channel.incoming.add(
      ServerMessage.fromJson({
        'type': 'commands_list',
        'in_reply_to': id,
        'dispatch_supported': supported,
        'commands': [
          {
            'name': name,
            'description': 'Live pane description',
            'source': 'builtin',
            'available': available,
            'busy_policy': 'idle_only',
            'reason': available ? null : 'Needs Mac approval',
          },
        ],
      }),
    );
  }

  Future<void> load({bool supported = true, bool available = true}) async {
    final future = repo.list();
    await flush();
    listReply(
      (channel.sent.last as ListCommands).id,
      supported: supported,
      available: available,
    );
    await future;
  }

  test(
    'exact list/execute wire and real correlated acceptance, never user_message',
    () async {
      final future = repo.list();
      await flush();
      final request = channel.sent.single as ListCommands;
      expect(request.toJson(), {'type': 'list_commands', 'id': request.id});
      listReply(request.id);
      final commands = await future;
      expect(commands.single.description, 'Live pane description');
      expect(commands.single.source, 'builtin');
      expect(commands.single.busyPolicy, 'idle_only');
      var done = false;
      final execute = repo
          .execute('compact', 'preserve decisions')
          .then((_) => done = true);
      await flush();
      expect(done, false);
      final command = channel.sent.last as CommandExecute;
      expect(command.toJson(), {
        'type': 'command_execute',
        'id': command.id,
        'name': 'compact',
        'args': 'preserve decisions',
      });
      channel.incoming.add(
        CommandResult(inReplyTo: 'wrong', name: 'compact', accepted: true),
      );
      channel.incoming.add(
        CommandResult(inReplyTo: command.id, name: 'different', accepted: true),
      );
      await flush();
      expect(done, false);
      channel.incoming.add(
        ServerMessage.fromJson({
          'type': 'command_result',
          'in_reply_to': command.id,
          'name': 'compact',
          'status': 'accepted',
        }),
      );
      await execute;
      expect(done, true);
      expect(channel.sent.whereType<UserMessage>(), isEmpty);
    },
  );
  test('unsupported and unavailable commands are fail-closed', () async {
    await load(supported: false);
    await expectLater(
      repo.execute('compact', ''),
      throwsA(isA<PaneCommandFailure>()),
    );
    expect(channel.sent.whereType<CommandExecute>(), isEmpty);
    await load(available: false);
    await expectLater(
      repo.execute('compact', ''),
      throwsA(
        isA<PaneCommandFailure>().having(
          (e) => e.message,
          'message',
          'Needs Mac approval',
        ),
      ),
    );
    await expectLater(
      repo.execute('not-listed', ''),
      throwsA(isA<PaneCommandFailure>()),
    );
  });
  test(
    'rejected busy result is not acceptance and execution never auto retries',
    () async {
      await load();
      final execution = repo.execute('compact', '');
      final rejected = expectLater(
        execution,
        throwsA(
          isA<PaneCommandFailure>().having(
            (e) => e.message,
            'message',
            'Pane is busy',
          ),
        ),
      );
      await flush();
      final request = channel.sent.last as CommandExecute;
      channel.incoming.add(
        CommandResult(
          inReplyTo: request.id,
          name: 'compact',
          accepted: false,
          code: 'busy',
          message: 'Pane is busy',
        ),
      );
      await rejected;
      expect(channel.sent.whereType<CommandExecute>().length, 1);
    },
  );
  test('room switch invalidates pending result and old catalogue', () async {
    await load();
    final execution = repo.execute('compact', '');
    final failed = expectLater(execution, throwsA(isA<PaneCommandFailure>()));
    await flush();
    final request = channel.sent.last as CommandExecute;
    conn.switchRoom('room-b');
    // Even a synchronous reply before the room stream event must not escape.
    channel.incoming.add(
      CommandResult(inReplyTo: request.id, name: 'compact', accepted: true),
    );
    await failed;
    await expectLater(
      repo.execute('compact', ''),
      throwsA(isA<PaneCommandFailure>()),
    );
    expect(channel.sent.whereType<CommandExecute>().length, 1);
  });
  test('older list response cannot replace refreshed catalogue', () async {
    final older = repo.list();
    final ignored = expectLater(older, throwsA(isA<PaneCommandFailure>()));
    await flush();
    final oldId = (channel.sent.last as ListCommands).id;
    final newer = repo.list();
    await flush();
    final newId = (channel.sent.last as ListCommands).id;
    listReply(newId, name: 'fresh');
    await newer;
    listReply(oldId, name: 'stale');
    await ignored;
    await expectLater(
      repo.execute('stale', ''),
      throwsA(isA<PaneCommandFailure>()),
    );
    final run = repo.execute('fresh', '');
    await flush();
    final request = channel.sent.last as CommandExecute;
    channel.incoming.add(
      CommandResult(inReplyTo: request.id, name: 'fresh', accepted: true),
    );
    await run;
  });
  test(
    'missing reply times out honestly without slash text fallback or retry',
    () async {
      await load();
      await expectLater(
        repo.execute('compact', ''),
        throwsA(
          isA<PaneCommandFailure>().having(
            (e) => e.message,
            'uncertain acceptance',
            contains('may have been accepted'),
          ),
        ),
      );
      expect(channel.sent.whereType<CommandExecute>().length, 1);
      expect(channel.sent.whereType<UserMessage>(), isEmpty);
    },
  );
  test(
    'discovery rejection with empty name is correlated and surfaced',
    () async {
      final list = repo.list();
      final rejected = expectLater(
        list,
        throwsA(
          isA<PaneCommandFailure>().having(
            (e) => e.message,
            'message',
            'Pairing changed',
          ),
        ),
      );
      await flush();
      final id = (channel.sent.last as ListCommands).id;
      channel.incoming.add(
        CommandResult(
          inReplyTo: id,
          name: '',
          accepted: false,
          message: 'Pairing changed',
        ),
      );
      await rejected;
    },
  );
  test('multiline or oversized arguments never leave the app', () async {
    await load();
    await expectLater(
      repo.execute('compact', 'arg\n/other'),
      throwsA(isA<PaneCommandFailure>()),
    );
    await expectLater(
      repo.execute('compact', 'x' * 8193),
      throwsA(isA<PaneCommandFailure>()),
    );
    expect(channel.sent.whereType<CommandExecute>(), isEmpty);
  });
  test(
    'disconnect rejects pending discovery and prevents offline dispatch',
    () async {
      final future = repo.list();
      final failed = expectLater(future, throwsA(isA<PaneCommandFailure>()));
      await conn.disconnect();
      await failed;
      await expectLater(
        repo.execute('compact', ''),
        throwsA(isA<PaneCommandFailure>()),
      );
    },
  );
}
