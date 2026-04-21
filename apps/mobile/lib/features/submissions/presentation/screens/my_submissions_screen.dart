import 'package:flutter/material.dart';

import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';

class MySubmissionsScreen extends StatelessWidget {
  const MySubmissionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SectionHeader(title: 'My Submissions'),
        SizedBox(height: 24),
        AppEmptyState(
          icon: Icons.upload_file_outlined,
          title: 'No submissions yet',
          message:
              'Once drafts are submitted for review, they will appear here.',
        ),
      ],
    );
  }
}
