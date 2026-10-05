import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'about.dart';
import 'theme.dart';

const kIssuesUrl = 'https://github.com/abahvictor360-sketch/Obs/issues/new';

/// The GitHub issue form for [template] ('bug_report.yml' or
/// 'feature_request.yml'), with the build and system filled in.
Uri feedbackUrl(String template, {String? system}) => Uri.parse(kIssuesUrl).replace(queryParameters: {
      'template': template,
      if (template == 'bug_report.yml') 'build': kAppBuild == 'dev' ? 'dev' : 'build-$kAppBuild',
      if (system != null && template == 'bug_report.yml') 'system': system,
    });

String? _system() {
  if (kIsWeb) return null;
  try {
    final os = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iPadOS',
      _ => Platform.operatingSystem,
    };
    return '$os (${Platform.operatingSystemVersion})';
  } catch (_) {
    return null;
  }
}

/// Help › Send Feedback: report a problem or suggest a feature on GitHub.
Future<void> showFeedback(BuildContext context) async {
  final template = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      key: const ValueKey('feedback-dialog'),
      title: const Text('Send Feedback'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'OBSpad is in testing. Tell us what doesn\'t work and what\'s missing: it opens a short form on GitHub '
            '(free account needed). Screenshots and screen recordings help a lot.',
            style: TextStyle(color: ObsColors.textDim),
          ),
        ),
        SimpleDialogOption(
          key: const ValueKey('feedback-bug'),
          onPressed: () => Navigator.pop(context, 'bug_report.yml'),
          child: const ListTile(
            leading: Icon(Icons.bug_report_outlined),
            title: Text('Something isn\'t working'),
            subtitle: Text('A crash, a freeze, missing sound or video…'),
          ),
        ),
        SimpleDialogOption(
          key: const ValueKey('feedback-idea'),
          onPressed: () => Navigator.pop(context, 'feature_request.yml'),
          child: const ListTile(
            leading: Icon(Icons.lightbulb_outline),
            title: Text('Something is missing'),
            subtitle: Text('A feature you need, or something OBS Studio does'),
          ),
        ),
      ],
    ),
  );
  if (template == null) return;
  try {
    await launchUrl(feedbackUrl(template, system: _system()), mode: LaunchMode.externalApplication);
  } catch (_) {}
}
