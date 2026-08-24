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
  });

  tearDown(() {
    controller.dispose();
  });

  test('request adds pending export job', () async {
    final success = await controller.requestExport(
      projectId: 'proj-2',
      projectName: 'Mount Lebanon Citrus Survey',
      format: ExportFormat.geojson,
      exportParameters: const <String, dynamic>{'simulate_result': 'completed'},
    );

    expect(success, isTrue);
    final page = await repository.fetchJobsPage(
      requestedByUserId: session.user.id,
      projectId: 'proj-2',
    );
    expect(page.total, 1);
    expect(page.items.first.status, ExportJobStatus.pending);
    expect(notifications.where((m) => m.startsWith('Export queued')).length, 1);
  });

  test('failed export can be retried', () async {
    await controller.requestExport(
      projectId: 'proj-2',
      projectName: 'Mount Lebanon Citrus Survey',
      format: ExportFormat.shapefile,
      exportParameters: const <String, dynamic>{'simulate_result': 'failed'},
    );

    final requestedPage = await repository.fetchJobsPage(
      requestedByUserId: session.user.id,
      projectId: 'proj-2',
    );
    final requested = requestedPage.items.first;

    await repository.processQueueTick(requestedByUserId: session.user.id);
    await repository.processQueueTick(requestedByUserId: session.user.id);

    final failedPage = await repository.fetchJobsPage(
      requestedByUserId: session.user.id,
      projectId: 'proj-2',
    );
    expect(failedPage.items.first.status, ExportJobStatus.failed);

    await controller.retryFailedExport(requested.id);
    final retriedPage = await repository.fetchJobsPage(
      requestedByUserId: session.user.id,
      projectId: 'proj-2',
    );
    expect(retriedPage.items.first.status, ExportJobStatus.pending);
  });

  test('completed export can be marked downloaded', () async {
    await controller.requestExport(
      projectId: 'proj-3',
      projectName: 'South Region Replanting Program',
      format: ExportFormat.geojson,
      exportParameters: const <String, dynamic>{'simulate_result': 'completed'},
    );

    final requestedPage = await repository.fetchJobsPage(
      requestedByUserId: session.user.id,
      projectId: 'proj-3',
    );
    final requested = requestedPage.items.first;

    await repository.processQueueTick(requestedByUserId: session.user.id);
    await repository.processQueueTick(requestedByUserId: session.user.id);

    final downloaded = await controller.downloadExport(requested.id);
    expect(downloaded, isNotNull);
    final completed = downloaded!;
    expect(completed.status, ExportJobStatus.completed);
    expect(completed.canDownload, isTrue);
    expect(completed.downloadedAt, isNotNull);
    expect(completed.localFilePath, isNotNull);
  });
}
