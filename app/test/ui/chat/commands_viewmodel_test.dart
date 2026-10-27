import 'dart:async';
import 'package:app/domain/contracts/pane_commands.dart';
import 'package:app/ui/chat/commands/viewmodels/commands_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePaneCommands extends PaneCommands {
  final changes = StreamController<void>.broadcast();
  List<PaneCommand> catalogue = const [
    PaneCommand(
      name: 'compact',
      description: 'Compact this session',
      executable: true,
    ),
    PaneCommand(
      name: 'login',
      description: 'Sign in on Mac',
      executable: false,
      disabledReason: 'Complete sign-in on your Mac.',
    ),
  ];
  final runs = <(String, String)>[];
  Completer<List<PaneCommand>>? pendingList;
  Completer<void>? pendingRun;
  String? failure;
  int listCount = 0;
  @override
  Stream<void> get contextChanges => changes.stream;
  @override
  Future<List<PaneCommand>> list() async {
    listCount++;
    if (failure != null) throw PaneCommandFailure(failure!);
    return pendingList == null ? catalogue : pendingList!.future;
  }

  @override
  Future<void> execute(String name, String arguments) async {
    runs.add((name, arguments));
    if (failure != null) throw PaneCommandFailure(failure!);
    if (pendingRun != null) await pendingRun!.future;
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);
void main() {
  test('slash loads live descriptions; filter/select never executes', () async {
    final source = FakePaneCommands();
    final vm = CommandsViewModel(source);
    vm.queryChanged('ordinary');
    await flush();
    expect(source.listCount, 0);
    vm.queryChanged('/');
    await flush();
    expect(source.listCount, 1);
    expect(vm.matches('/com').single.description, 'Compact this session');
    expect(source.runs, isEmpty);
    expect(await vm.run('/compact preserve decisions'), true);
    expect(source.runs, [('compact', 'preserve decisions')]);
    vm.dispose();
    await source.changes.close();
  });
  test(
    'unlisted/disabled commands never execute; failures retain retry state',
    () async {
      final source = FakePaneCommands();
      final vm = CommandsViewModel(source);
      await vm.refresh();
      expect(await vm.run('/invented'), false);
      expect(await vm.run('/login'), false);
      expect(source.runs, isEmpty);
      expect(
        (vm.state as CommandsReady).error,
        'Complete sign-in on your Mac.',
      );
      source.failure = 'Pane is busy';
      expect(await vm.run('/compact'), false);
      expect((vm.state as CommandsReady).error, 'Pane is busy');
      vm.dispose();
      await source.changes.close();
    },
  );
  test(
    'in-flight execution blocks double run and stale room result is discarded',
    () async {
      final source = FakePaneCommands();
      final vm = CommandsViewModel(source);
      await vm.refresh();
      source.pendingRun = Completer<void>();
      final result = vm.run('/compact');
      expect(vm.state, isA<CommandsRunning>());
      expect(await vm.run('/compact'), false);
      expect(source.runs.length, 1);
      source.changes.add(null);
      await flush();
      source.pendingRun!.complete();
      expect(await result, false);
      expect(vm.state, isA<CommandsIdle>());
      vm.dispose();
      await source.changes.close();
    },
  );
  test(
    'longest live multiword command wins and failed refresh clears catalogue',
    () async {
      final source = FakePaneCommands();
      final vm = CommandsViewModel(source);
      source.catalogue = const [
        PaneCommand(name: 'work', description: 'Base', executable: true),
        PaneCommand(
          name: 'work review',
          description: 'Review',
          executable: true,
        ),
      ];
      await vm.refresh();
      expect(await vm.run('/work review current changes'), true);
      expect(source.runs.single, ('work review', 'current changes'));
      source.failure = 'Offline';
      await vm.refresh();
      expect(vm.matches('/'), isEmpty);
      expect(await vm.run('/work'), false);
      expect(source.runs.length, 1);
      vm.dispose();
      await source.changes.close();
    },
  );
  test('old catalogue cannot overwrite new room catalogue', () async {
    final source = FakePaneCommands();
    final vm = CommandsViewModel(source);
    final old = Completer<List<PaneCommand>>();
    source.pendingList = old;
    vm.queryChanged('/');
    await flush();
    source.pendingList = null;
    source.catalogue = const [
      PaneCommand(name: 'fresh', description: 'Current pane', executable: true),
    ];
    source.changes.add(null);
    await flush();
    await flush();
    old.complete(const [
      PaneCommand(name: 'stale', description: 'Old pane', executable: true),
    ]);
    await flush();
    expect(vm.matches('/').single.name, 'fresh');
    vm.dispose();
    await source.changes.close();
  });
}
