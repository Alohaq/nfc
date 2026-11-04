import 'dart:typed_data';

import 'hex.dart';

/// FMSC application protocol for the 552x768 four-colour Huawei panels.
///
/// Byte strings below are copied verbatim from the two reference projects:
///   - solar2ain/ink-nfc-fmsc-by-pn532  (src/ink_nfc_fmsc/protocol.py)
///   - kur0neko/huawei-epd-pn532        (epd_protocol.py)
/// so that anything produced here is wire-compatible with them.
class Apdu {
  /// Read the device information TLV set.
  static final Uint8List readInfo = Uint8List.fromList([0x00, 0xD1, 0x00, 0x00, 0x00]);

  /// Access-rights probe. Answers 6985 when a PIN is required.
  static final Uint8List checkAccess = Uint8List.fromList(
      [0xF0, 0xD8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x0E]);

  /// Read BUSY / idle state. `00` idle, `01` busy.
  static final Uint8List readStatus = Uint8List.fromList([0xF0, 0xDE, 0x00, 0x00, 0x01]);

  /// Clear the stored image (DB). Not used by the write flow.
  static final Uint8List clearStored = Uint8List.fromList([0xF0, 0xDB, 0x02, 0x00, 0x00]);

  /// `00 20 00 01 05 || pin`
  static Uint8List verifyPin(List<int> pin) {
    if (pin.length != 5) {
      throw ArgumentError.value(pin.length, 'pin', 'PIN must be exactly 5 bytes');
    }
    return Uint8List.fromList([0x00, 0x20, 0x00, 0x01, 0x05, ...pin]);
  }

  /// `F0 D4 (80|delay/100) 80 00`
  ///
  /// P1 bit 7 skips re-detection, low 7 bits are the panel power-on wait in
  /// 100 ms units. Both reference projects build it this way.
  static Uint8List refresh({int powerOnDelayMs = 2000}) {
    if (powerOnDelayMs < 100 || powerOnDelayMs > 12700 || powerOnDelayMs % 100 != 0) {
      throw ArgumentError.value(
          powerOnDelayMs, 'powerOnDelayMs', 'must be 100..12700 and a multiple of 100');
    }
    return Uint8List.fromList(
        [0xF0, 0xD4, 0x80 | (powerOnDelayMs ~/ 100), 0x80, 0x00]);
  }

  /// One image sub-packet: `F0 D3 slot last len block sub || chunk`.
  ///
  /// [length] is the chunk length plus 2 (the block and sub indices), exactly as
  /// split_compressed()/image_packets() emit it.
  static Uint8List imagePacket({
    required int slot,
    required int block,
    required int sub,
    required bool lastInBlock,
    required Uint8List chunk,
  }) {
    if (slot < 0 || slot > 255) throw ArgumentError.value(slot, 'slot');
    if (block < 0 || block > 255) throw ArgumentError.value(block, 'block');
    if (sub < 0 || sub > 255) throw ArgumentError.value(sub, 'sub');
    if (chunk.isEmpty || chunk.length > 253) {
      throw ArgumentError.value(chunk.length, 'chunk', 'must be 1..253 bytes');
    }
    return Uint8List.fromList([
      0xF0, 0xD3, slot, lastInBlock ? 1 : 0, chunk.length + 2, block, sub,
      ...chunk,
    ]);
  }

  /// `26` (REQA) / `52` (WUPA) / `7A` / `7D` are 7-bit short frames. Phones
  /// cannot emit them, so these are informational only on iOS/Android.
  static const List<int> shortFrameWakeCommands = [0x26, 0x52, 0x7A, 0x7D];
}

/// A response APDU split into payload and status word.
class ApduResponse {
  ApduResponse(this.payload, this.sw);

  final Uint8List payload;
  final int sw;

  bool get isOk => sw == 0x9000;
  String get swHex => sw.toRadixString(16).padLeft(4, '0').toUpperCase();

  String get swMeaning => StatusWords.meaning(sw);

  /// Throws [FmscStatusException] when [sw] is not 9000.
  ApduResponse requireOk(String context) {
    if (!isOk) throw FmscStatusException(context, sw);
    return this;
  }

  @override
  String toString() =>
      'SW=$swHex${payload.isEmpty ? '' : ' data=${Hex.of(payload)}'}';
}

class FmscStatusException implements Exception {
  FmscStatusException(this.context, this.sw);
  final String context;
  final int sw;

  String get swHex => sw.toRadixString(16).padLeft(4, '0').toUpperCase();

  @override
  String toString() {
    final m = StatusWords.meaning(sw);
    return '$context failed: SW=$swHex${m.isEmpty ? '' : ' ($m)'}';
  }
}

/// Status word meanings, copied from ink_nfc_fmsc/protocol.py STATUS.
class StatusWords {
  static const Map<int, String> _map = {
    0x9000: 'OK',
    0x6401: 'execution error / card failure',
    0x6449: 'EEPROM configuration error',
    0x6450: 'panel init data error',
    0x6451: 'panel init packet has a bad TAG',
    0x6452: 'panel init content error',
    0x6453: 'panel init sequence incomplete',
    0x6454: 'panel refresh failed',
    0x6455: 'panel re-position failed',
    0x646A: 'TLV count over limit',
    0x6501: 'NVM write interrupted',
    0x6502: 'low power, NVM write stopped (not a PIN error)',
    0x6503: 'NVM address invalid',
    0x6506: 'NVM permission error',
    0x6508: 'NVM length error',
    0x6509: 'bad command parameter',
    0x650A: 'execution aborted',
    0x650F: 'no execution permission',
    0x6700: 'wrong Lc/Le',
    0x6781: 'bad total packet length',
    0x68C6: 'panel reposition failed / panel missing',
    0x68CA: 'LOW VOLTAGE WARNING',
    0x68CB: 'refresh timeout warning',
    0x6982: 'security status not satisfied',
    0x6985: 'conditions not satisfied (PIN required)',
    0x6986: 'reposition failed / panel absent',
    0x698A: 'low voltage warning',
    0x6991: 'compression algorithm not initialised',
    0x6992: 'decompression failed',
    0x6993: 'bad decompressed length',
    0x6994: 'bad compressed length',
    0x6995: 'image packet sequence mismatch',
    0x6A80: 'bad data parameter',
    0x6A86: 'bad P1/P2',
    0x6A96: 'bad image format code',
  };

  static String meaning(int sw) => _map[sw] ?? '';
}

/// TLV info returned by `00 D1 00 00 00`.
class DeviceInfo {
  DeviceInfo({
    required this.uid,
    required this.width,
    required this.height,
    required this.colors,
    required this.supportsCompression,
    required this.firmware,
    required this.fields,
  });

  final Uint8List uid;
  final int width;
  final int height;
  final int colors;
  final bool supportsCompression;
  final int firmware;
  final Map<int, Uint8List> fields;

  /// Parses a successful `00 D1` response.
  ///
  /// Mirrors parse_device_info()/board_info(): tags A0(7) B1(1) B2(1) C0(4)
  /// C1(4) are mandatory. Width/height come from A0 as big-endian words at
  /// offsets [3:5] (height) and [5:7] (width).
  static DeviceInfo parse(ApduResponse r) {
    final data = r.requireOk('read device info').payload;
    final fields = <int, Uint8List>{};
    var i = 0;
    while (i < data.length) {
      if (i + 2 > data.length) {
        throw const FormatException('truncated D1 TLV header');
      }
      final tag = data[i];
      final n = data[i + 1];
      i += 2;
      if (fields.containsKey(tag) || i + n > data.length) {
        throw const FormatException('duplicate or truncated D1 TLV');
      }
      fields[tag] = Uint8List.sublistView(data, i, i + n);
      i += n;
    }
    for (final entry in const {0xA0: 7, 0xB1: 1, 0xB2: 1, 0xC0: 4, 0xC1: 4}.entries) {
      if ((fields[entry.key]?.length ?? 0) != entry.value) {
        throw FormatException(
            'D1 field ${entry.key.toRadixString(16).toUpperCase()} missing or wrong length');
      }
    }
    final a0 = fields[0xA0]!;
    var height = (a0[3] << 8) | a0[4];
    var width = (a0[5] << 8) | a0[6];
    var colors = fields[0xB1]![0];
    // Observed firmware quirk, scoped to this exact geometry (see
    // epd_protocol.parse_device_info).
    if (width == 552 && height == 1536 && colors == 2) {
      height = 768;
      colors = 4;
    }
    return DeviceInfo(
      uid: fields[0xC1]!,
      width: width,
      height: height,
      colors: colors,
      supportsCompression: fields[0xC0]![3] != 0,
      firmware: fields[0xB2]![0],
      fields: fields,
    );
  }

  /// Whether this looks like the 552x768 four-colour panel the pipeline targets.
  bool get isTargetPanel =>
      width == 552 && height == 768 && colors == 4 && supportsCompression;

  String get uidHex => Hex.of(uid);

  @override
  String toString() => '$width x $height, $colors colours, '
      'compression=$supportsCompression, fw=$firmware, uid=$uidHex';
}
