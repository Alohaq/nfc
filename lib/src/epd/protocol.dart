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
    0x9000: '成功',
    0x6401: '执行未完成 / 卡片未就绪',
    0x6449: 'EEPROM 配置错误',
    0x6450: '屏幕初始化数据错误',
    0x6451: '屏幕初始化包含错误 TAG',
    0x6452: '屏幕初始化内容错误',
    0x6453: '屏幕初始化序列不完整',
    0x6454: '屏幕刷新失败',
    0x6455: '屏幕复位失败',
    0x646A: 'TLV 数量超限',
    0x6501: '写入 NVM 被中断',
    0x6502: '电量过低，NVM 写入中止（非 PIN 错误）',
    0x6503: 'NVM 地址无效',
    0x6506: 'NVM 权限错误',
    0x6508: 'NVM 长度错误',
    0x6509: '命令参数错误',
    0x650A: '执行已中止',
    0x650F: '无执行权限',
    0x6700: 'Lc/Le 长度错误',
    0x6781: '数据包总长度错误',
    0x68C6: '屏幕复位失败 / 屏幕不存在',
    0x68CA: '低电压告警',
    0x68CB: '刷新超时告警',
    0x6982: '安全状态不满足',
    0x6985: '使用条件不满足（需要 PIN）',
    0x6986: '复位失败 / 屏幕未就位',
    0x698A: '低电压告警',
    0x6991: '压缩算法未初始化',
    0x6992: '解压失败',
    0x6993: '解压后长度不正确',
    0x6994: '压缩长度错误',
    0x6995: '图像分包序号不匹配',
    0x6A80: '数据参数错误',
    0x6A86: 'P1/P2 参数错误',
    0x6A96: '图像格式码错误',
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

  /// 中文摘要，用于界面与日志。
  String toChinese() => '$width×$height，$colors 色，'
      '压缩=${supportsCompression ? '支持' : '不支持'}，固件 $firmware，UID $uidHex';

  @override
  String toString() => '$width x $height, $colors colours, '
      'compression=$supportsCompression, fw=$firmware, uid=$uidHex';
}
