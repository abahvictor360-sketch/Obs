import 'dart:math';

/// A guest's phone camera through a link, with no app to install: the guest
/// opens the push link (or scans its QR code) and allows the camera; OBSpad
/// shows them in a Browser source. Uses VDO.Ninja (free, open source,
/// peer-to-peer WebRTC), like OBS users do.
class GuestCamera {
  static const host = 'https://vdo.ninja/';

  /// A new random stream id.
  static String newRoom([Random? rnd]) {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final r = rnd ?? Random.secure();
    return 'obspad${List.generate(10, (_) => chars[r.nextInt(chars.length)]).join()}';
  }

  /// What the guest opens on their phone.
  static String pushUrl(String room) => '$host?push=$room&webcam&quality=1&label=OBSpad%20guest';

  /// What the Browser source shows: just the guest's video. Their sound
  /// can't be taken from a web page, so it's left off (no echo on the tablet).
  static String viewUrl(String room) => '$host?view=$room&cleanoutput&noaudio';

  /// Settings for the Browser source that shows guest [room].
  static Map<String, dynamic> sourceSettings(String room) => {
        'url': viewUrl(room),
        'width': 1280.0,
        'height': 720.0,
        'fps': 30,
        'css': 'body { background-color: rgba(0, 0, 0, 0); margin: 0px auto; overflow: hidden; }',
        'shutdown': false, // keep the guest connected when the source is hidden
        'guestRoom': room,
      };
}
