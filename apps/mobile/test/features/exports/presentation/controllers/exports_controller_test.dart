import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/exports/data/mock_exports_repository.dart';
import 'package:lebanese_gis_mobile/features/exports/domain/export_job.dart';
import 'package:lebanese_gis_mobile/features/exports/presentation/controllers/exports_controller.dart';

void main() {
  late MockExportsRepository repository;
  late List<String> notifications;
  late ExportsController controller;

  final session = AuthSession(
    accessToken: 'access',
    refreshToken: 'refresh',
    user: const AppUser(
      id: 'user-1',
      fullName: 'Admin One',
      email: 'admin@gov.lb',
      role: UserRole.admin,
    ),
  );

  setUp(() async {
    repository = MockExportsRepository();
    notifications = <String>[];
    controller = ExportsController(
      repository: repository,
      session: session,
      emitNotification: ({required String title, required String message}) {
        notifications.add('$title|$message');
      },
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
  });

  test('request adds pending export job', () async {
    final initialTotal = controller.state.jobs.length;
    await controller.requestExport(
      projectId: 'proj-2',
      projectName: 'Mount Lebanon Citrus Survey',
      format: ExportFormat.geojson,
      exportParameters: const <String, dynamic>{'simulate_result': 'completed'},
    );

    expect(controller.state.jobs.length, initialTotal + 1);
    expect(
      controller.state.jobs.firstWhere((j) => j.projectId == 'proj-2').status,
      ExportJobStatus.pending,
    );
  });

  test('queue transitions pending -> processing -> failed', () async {
    await controller.requestExport(
      projectId: 'proj-2',
      projectName: 'Mount Lebanon Citrus Survey',
      format: ExportFormat.shapefile,
      exportParameters: const <String, dynamic>{'simulate_result': 'failed'},
    );

    final requested = controller.state.jobs.firstWhere(
      (j) => j.projectId == 'proj-2',
    );

    await controller.runQueueTick();
    final processing = controller.state.jobs.firstWhere(
      (j) => j.id == requested.id,
    );
    expect(processing.status, ExportJobStatus.processing);

    await controller.runQueueTick();
    final failed = controller.state.jobs.firstWhere(
      (j) => j.id == requested.id,
    );
    expect(failed.status, ExportJobStatus.failed);
    expect(
      notifications.where((m) => m.startsWith('Export failed')).isNotEmpty,
      isTrue,
    );
  });

  test('completed export can be marked downloaded', () async {
    await controller.requestExport(
      projectId: 'proj-3',
      projectName: 'South Region Replanting Program',
      format: ExportFormat.geojson,
      exportParameters: const <String, dynamic>{'simulate_result': 'completed'},
    );

    final requested = controller.state.jobs.firstWhere(
      (j) => j.projectId == 'proj-3',
    );

    await controller.runQueueTick();
    await controller.runQueueTick();

    final completed = controller.state.jobs.firstWhere(
      (j) => j.id == requested.id,
    );
    expect(completed.status, ExportJobStatus.completed);
    expect(completed.canDownload, isTrue);

    await controller.downloadExport(completed.id);
    final downloaded = controller.state.jobs.firstWhere(
      (j) => j.id == completed.id,
    );
    expect(downloaded.downloadedAt, isNotNull);
  });
}
