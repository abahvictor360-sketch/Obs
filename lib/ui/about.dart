import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

/// Version shown in About. CI passes the run number with
/// `--dart-define=OBSPAD_BUILD=<n>`, the same number as the APK's versionCode.
const kAppVersion = '1.0.0';
const kAppBuild = String.fromEnvironment('OBSPAD_BUILD', defaultValue: 'dev');

const kDeveloperName = 'Victor Abah';
const kDeveloperSite = 'www.victorabah.com';
const kDownloadSite = 'obspad.vercel.app';

Future<void> openWebsite(String host) async {
  try {
    await launchUrl(Uri.parse('https://$host'), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Help › About OBSpad.
Future<void> showObsAbout(BuildContext context) {
  Widget feature(IconData icon, String title, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: ObsColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: text, style: const TextStyle(color: ObsColors.textDim)),
            ])),
          ),
        ]),
      );

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('about-dialog'),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Image.asset('assets/logo.png', width: 56, height: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('OBSpad', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  Text('Version $kAppVersion (build $kAppBuild)',
                      style: const TextStyle(color: ObsColors.textDim, fontSize: 13)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            const Text(
              'A live production studio for Android tablets and iPad, modeled on OBS Studio. '
              'Build scenes from cameras, screen capture, capture cards, images, videos and web pages, '
              'preview them in Studio Mode, and stream or record without a computer.',
            ),
            const SizedBox(height: 16),
            feature(Icons.view_column_outlined, 'Studio Mode',
                'Preview and Program, Quick Transitions, a T-bar, and Multiview on a second screen.'),
            feature(Icons.auto_awesome_outlined, 'Filters',
                'Chroma Key, Color Correction, Sharpen, Blur, Scroll, masks and Gain.'),
            feature(Icons.podcasts, 'Streaming',
                'Facebook Live, YouTube, Twitch and Kick with just a stream key, or any RTMP/RTMPS server.'),
            feature(Icons.usb, 'Hardware',
                'Capture cards, webcams, USB sound cards, Ethernet and monitors, directly or through a dock.'),
            feature(Icons.extension_outlined, 'Plugins', 'Install from a GitHub link; NDI® output built in.'),
            const Divider(height: 28),
            const Text('Developed by', style: TextStyle(color: ObsColors.textDim, fontSize: 12)),
            const SizedBox(height: 2),
            const Text(kDeveloperName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            TextButton.icon(
              key: const ValueKey('developer-site'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.language, size: 18),
              label: const Text(kDeveloperSite),
              onPressed: () => openWebsite(kDeveloperSite),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Updates: $kDownloadSite'),
              onPressed: () => openWebsite(kDownloadSite),
            ),
            const SizedBox(height: 8),
            const Text(
              'Inspired by OBS Studio; not affiliated with the OBS Project. '
              'NDI® is a registered trademark of Vizrt NDI AB.',
              style: TextStyle(color: ObsColors.textDim, fontSize: 12),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'OBSpad',
            applicationVersion: '$kAppVersion ($kAppBuild)',
            applicationLegalese: '© $kDeveloperName',
          ),
          child: const Text('Licenses'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}
