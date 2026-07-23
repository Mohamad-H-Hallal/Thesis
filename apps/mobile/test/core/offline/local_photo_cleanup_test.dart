import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_photo_cleanup.dart';
import 'package:path/path.dart' as p;

void main() {
  test('cleanup schema keeps durable work project and owner scoped', () async {
    final executedSql = <String>[];

    await createPendingLocalPhotoDeletionSchema((sql) async {
      executedSql.add(sql);
    });

    expect(executedSql, hasLength(2));
    expect(executedSql.first, contains('pending_local_file_deletions'));
    expect(executedSql.first, contains('owner_user_id TEXT NOT NULL'));
    expect(executedSql.first, contains('project_id TEXT NOT NULL'));
    expect(executedSql.first, contains('draft_id TEXT NOT NULL'));
    expect(
      executedSql.first,
      contains('UNIQUE (owner_user_id, project_id, draft_id, file_path)'),
    );
    expect(executedSql.last, contains('owner_user_id, project_id, draft_id'));
  });

  test('local photo cleanup deletes files and is safe to repeat', () async {
    final directory = await Directory.systemTemp.createTemp(
      'offline-photo-cleanup-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final photo = File('${directory.path}${Platform.pathSeparator}photo.jpg');
    await photo.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);

    await deleteLocalPhotoFiles(<String>[photo.path, photo.path]);
    await deleteLocalPhotoFiles(<String>[photo.path, '', '   ']);

    expect(await photo.exists(), isFalse);
  });

  test('photo scope segments are deterministic and traversal safe', () {
    final dot = safeOfflinePhotoScopeSegment('.');
    final dotDot = safeOfflinePhotoScopeSegment('..');
    final traversal = safeOfflinePhotoScopeSegment('../other/project');

    expect(dot, safeOfflinePhotoScopeSegment('.'));
    expect(dot, isNot(dotDot));
    expect(dotDot, isNot(traversal));
    for (final segment in <String>[dot, dotDot, traversal]) {
      expect(segment, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(segment, isNot(contains('/')));
      expect(segment, isNot(contains(r'\')));
      expect(segment, isNot('.'));
      expect(segment, isNot('..'));
    }
    expect(() => safeOfflinePhotoScopeSegment('  '), throwsArgumentError);
  });

  test('scoped photo paths cannot escape their exact draft directory', () {
    final root = p.join(Directory.systemTemp.path, 'offline-photo-root');
    final draftDirectory = offlineDraftPhotoDirectoryPath(
      rootDirectory: root,
      ownerUserId: '..',
      projectId: '../project-b',
      draftId: r'..\draft-b',
    );
    final validPhoto = p.join(draftDirectory, 'photo.jpg');
    final siblingPhoto = p.join(
      p.dirname(draftDirectory),
      safeOfflinePhotoScopeSegment('different-draft'),
      'photo.jpg',
    );
    final traversalPhoto = p.normalize(
      p.join(draftDirectory, '..', 'outside.jpg'),
    );

    expect(isPathWithinDirectory(draftDirectory, root), isTrue);
    expect(
      areOfflineDraftPhotoPathsScoped(
        rootDirectory: root,
        ownerUserId: '..',
        projectId: '../project-b',
        draftId: r'..\draft-b',
        filePaths: <String>[validPhoto],
      ),
      isTrue,
    );
    for (final unsafePath in <String>[siblingPhoto, traversalPhoto, root]) {
      expect(
        areOfflineDraftPhotoPathsScoped(
          rootDirectory: root,
          ownerUserId: '..',
          projectId: '../project-b',
          draftId: r'..\draft-b',
          filePaths: <String>[unsafePath],
        ),
        isFalse,
      );
    }
  });

  test('failed durable cleanup remains available for a later retry', () async {
    const deletion = PendingLocalPhotoDeletion(
      id: 'cleanup-1',
      ownerUserId: 'owner-a',
      projectId: 'project-a',
      draftId: 'draft-a',
      filePath: 'unavailable-photo.jpg',
      attemptCount: 0,
    );
    final durableTasks = <String, PendingLocalPhotoDeletion>{
      deletion.id: deletion,
    };
    final failed = <PendingLocalPhotoDeletion>[];

    await processPendingLocalPhotoDeletions(
      durableTasks.values.toList(growable: false),
      deleteFile: (_) async => false,
      acknowledge: (task) async => durableTasks.remove(task.id),
      recordFailure: (task) async => failed.add(task),
    );

    expect(durableTasks, contains(deletion.id));
    expect(failed, <PendingLocalPhotoDeletion>[deletion]);

    await processPendingLocalPhotoDeletions(
      durableTasks.values.toList(growable: false),
      deleteFile: (_) async => true,
      acknowledge: (task) async => durableTasks.remove(task.id),
      recordFailure: (_) async => fail('The retry should succeed.'),
    );

    expect(durableTasks, isEmpty);
  });

  test(
    'shared photo path is deferred until no draft still references it',
    () async {
      const deletion = PendingLocalPhotoDeletion(
        id: 'cleanup-shared',
        ownerUserId: 'owner-a',
        projectId: 'project-a',
        draftId: 'draft-a',
        filePath: 'shared-photo.jpg',
        attemptCount: 0,
      );
      final durableTasks = <String, PendingLocalPhotoDeletion>{
        deletion.id: deletion,
      };
      var referencedByAnotherDraft = true;
      var deleteAttempts = 0;

      Future<void> drain() => processPendingLocalPhotoDeletions(
        durableTasks.values.toList(growable: false),
        decide: (_) async => referencedByAnotherDraft
            ? LocalPhotoDeletionDecision.defer
            : LocalPhotoDeletionDecision.delete,
        deleteFile: (_) async {
          deleteAttempts += 1;
          return true;
        },
        acknowledge: (task) async => durableTasks.remove(task.id),
        recordFailure: (_) async {},
      );

      await drain();
      expect(deleteAttempts, 0);
      expect(durableTasks, contains(deletion.id));

      referencedByAnotherDraft = false;
      await drain();
      expect(deleteAttempts, 1);
      expect(durableTasks, isEmpty);
    },
  );

  test('canonical scope check rejects traversal and sibling project paths', () {
    final separator = Platform.pathSeparator;
    final root = '${separator}app${separator}offline_photos';
    final projectA = '$root${separator}owner${separator}project-a';

    expect(
      isPathWithinDirectory(
        '$projectA${separator}draft${separator}photo.jpg',
        projectA,
      ),
      isTrue,
    );
    expect(
      isPathWithinDirectory(
        '$projectA$separator..${separator}project-b${separator}photo.jpg',
        projectA,
      ),
      isFalse,
    );
    expect(
      isPathWithinDirectory(
        '$root${separator}owner${separator}project-b${separator}photo.jpg',
        projectA,
      ),
      isFalse,
    );
  });

  test(
    'a crash after file deletion leaves the task safe to acknowledge on restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-photo-cleanup-restart-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final photo = File('${directory.path}${Platform.pathSeparator}photo.jpg');
      await photo.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);
      final deletion = PendingLocalPhotoDeletion(
        id: 'cleanup-restart',
        ownerUserId: 'owner-a',
        projectId: 'project-a',
        draftId: 'draft-a',
        filePath: photo.path,
        attemptCount: 0,
      );
      final durableTasks = <String, PendingLocalPhotoDeletion>{
        deletion.id: deletion,
      };

      await processPendingLocalPhotoDeletions(
        durableTasks.values.toList(growable: false),
        acknowledge: (_) async => throw StateError('simulated crash'),
        recordFailure: (_) async => fail('The file deletion should succeed.'),
      );

      expect(await photo.exists(), isFalse);
      expect(durableTasks, contains(deletion.id));

      await processPendingLocalPhotoDeletions(
        durableTasks.values.toList(growable: false),
        acknowledge: (task) async {
          expect(task.ownerUserId, 'owner-a');
          expect(task.projectId, 'project-a');
          expect(task.draftId, 'draft-a');
          durableTasks.remove(task.id);
        },
        recordFailure: (_) async => fail('A missing file is already clean.'),
      );

      expect(durableTasks, isEmpty);
    },
  );
}
