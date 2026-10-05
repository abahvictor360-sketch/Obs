import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/ui/feedback.dart';

void main() {
  test('feedback opens the GitHub issue form with the build and system filled in', () {
    final bug = feedbackUrl('bug_report.yml', system: 'Android (14)');
    expect(bug.host, 'github.com');
    expect(bug.path, '/abahvictor360-sketch/Obs/issues/new');
    expect(bug.queryParameters, {'template': 'bug_report.yml', 'build': 'dev', 'system': 'Android (14)'});
    final idea = feedbackUrl('feature_request.yml', system: 'Android (14)');
    expect(idea.queryParameters, {'template': 'feature_request.yml'});
  });
}
