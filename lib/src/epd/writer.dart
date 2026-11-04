import 'dart:async';
import 'dart:typed_data';

import 'protocol.dart';
import 'tag_link.dart';
import 'transfer_plan.dart';

/// Ordered stages, mirroring epd_writer.py's phase names.
enum WriteStage {
  idle,
  connecting,
  activating,
  readingInfo,
  authenticating,
  transferring,
  refreshing,
  polling,
  done,
  failed,
}

extension WriteStageLabel on WriteStage {
  String get label => switch (this) {
        WriteStage.idle => '空闲',
        WriteStage.connecting => '正在连接',
        WriteStage.activating => '正在激活屏幕',
        WriteStage.readingInfo => '正在读取设备信息',
        WriteStage.authenticating => '正在认证',
        WriteStage.transferring => '正在发送图像',
        WriteStage.refreshing => '正在触发刷新',
        WriteStage.polling => '正在等待屏幕刷新',
        WriteStage.done => '已完成',
        WriteStage.failed => '失败',
      };
}

class WriteProgress {
  const WriteProgress({
    required this.stage,
    this.message = '',
    this.completedPackets = 0,
    this.totalPackets = 0,
    this.polls = 0,
  });

  final WriteStage stage;
  final String message;
  final int completedPackets;
  final int totalPackets;
  final int polls;

  double? get packetFraction =>
      totalPackets == 0 ? null : completedPackets / totalPackets;
}

/// Result of a write attempt. Never claims success unless the panel answered
/// the DE poll with an idle status word.
class WriteOutcome {
  const WriteOutcome({
    required this.succeeded,
    required this.stage,
    this.error,
    this.deviceInfo,
    this.completedPackets = 0,
    this.polls = 0,
    this.busyObserved = false,
  });

  final bool succeeded;
  final WriteStage stage;
  final String? error;
  final DeviceInfo? deviceInfo;
  final int completedPackets;
  final int polls;

  /// Whether the BUSY status was ever seen. If DE only ever returned 00, the
  /// refresh may or may not have run; epd_writer logs that as "not confirmed".
  final bool busyObserved;

  String get summary => succeeded
      ? (busyObserved
          ? '刷新已确认（共查询 $polls 次状态）。'
          : '屏幕已回到空闲，但全程未观测到忙状态，刷新结果无法确认。')
      : '在「${stage.label}」阶段停止${error == null ? '' : '：$error'}';
}

/// Tuning knobs surfaced in the UI. Defaults copied from epd_writer.WriteJob.
class WriteSettings {
  const WriteSettings({
    this.pin = const [0x52, 0x65, 0x69, 0x99, 0x19],
    this.packetGapMs = 0,
    this.preRefreshWaitMs = 0,
    this.powerOnDelayMs = 2000,
    this.pollIntervalMs = 500,
    this.refreshBudgetMs = 60000,
    this.skipPin = false,
  });

  /// Default PIN published by both reference projects (5265699919).
  final List<int> pin;
  final int packetGapMs;
  final int preRefreshWaitMs;
  final int powerOnDelayMs;
  final int pollIntervalMs;
  final int refreshBudgetMs;

  /// Probe-only mode: stop after D8 and report the status word.
  final bool skipPin;

  WriteSettings copyWith({
    List<int>? pin,
    int? packetGapMs,
    int? preRefreshWaitMs,
    int? powerOnDelayMs,
    int? pollIntervalMs,
    int? refreshBudgetMs,
    bool? skipPin,
  }) =>
      WriteSettings(
        pin: pin ?? this.pin,
        packetGapMs: packetGapMs ?? this.packetGapMs,
        preRefreshWaitMs: preRefreshWaitMs ?? this.preRefreshWaitMs,
        powerOnDelayMs: powerOnDelayMs ?? this.powerOnDelayMs,
        pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
        refreshBudgetMs: refreshBudgetMs ?? this.refreshBudgetMs,
        skipPin: skipPin ?? this.skipPin,
      );
}

/// Runs the documented application flow against a [TagLink].
///
/// Invariants that follow the reference implementations:
///   * no automatic retry of a failed APDU, and never a replay of D4 or D3
///   * the RF session is never torn down and rebuilt mid-flow
///   * a refresh is only "confirmed" after DE reports idle
class Writer {
  Writer({required this.link, this.onProgress, this.onLog});

  final TagLink link;
  final void Function(WriteProgress progress)? onProgress;
  final void Function(String line)? onLog;

  CancelToken? _cancel;

  void _stage(WriteStage stage, [String message = '']) {
    onProgress?.call(WriteProgress(stage: stage, message: message));
    onLog?.call('[${stage.label}] ${message.isEmpty ? '...' : message}');
  }

  /// Read-only probe: D1 + D8. Sends nothing that changes the panel.
  Future<WriteOutcome> probe(WriteSettings settings) async {
    DeviceInfo? info;
    try {
      _stage(WriteStage.readingInfo);
      final d1 = await link.transceive(Apdu.readInfo);
      info = DeviceInfo.parse(d1);
      onLog?.call('D1 返回：${info.toChinese()}');

      _stage(WriteStage.authenticating, '正在检查访问权限');
      final d8 = await link.transceive(Apdu.checkAccess);
      onLog?.call('D8 返回：SW=${d8.swHex} ${d8.swMeaning}');
      if (d8.sw == 0x6985) {
        onLog?.call('该屏幕需要 5 字节 PIN 才能写入。');
      } else if (!d8.isOk) {
        onLog?.call('状态字异常，该屏幕可能需要厂商专有流程。');
      }
      _stage(WriteStage.done);
      return WriteOutcome(
        succeeded: true,
        stage: WriteStage.done,
        deviceInfo: info,
      );
    } on LinkException catch (e) {
      _stage(WriteStage.failed, e.message);
      return WriteOutcome(
          succeeded: false, stage: WriteStage.failed, error: e.message, deviceInfo: info);
    } on FmscStatusException catch (e) {
      _stage(WriteStage.failed, e.toString());
      return WriteOutcome(
          succeeded: false, stage: WriteStage.failed, error: e.toString(), deviceInfo: info);
    } catch (e) {
      _stage(WriteStage.failed, '$e');
      return WriteOutcome(
          succeeded: false, stage: WriteStage.failed, error: '$e', deviceInfo: info);
    }
  }

  /// Full upload + refresh.
  Future<WriteOutcome> write(
    TransferPlan plan,
    WriteSettings settings, {
    CancelToken? cancel,
  }) async {
    _cancel = cancel;
    DeviceInfo? info;
    var sent = 0;
    var polls = 0;
    var sawBusy = false;
    final stopwatch = Stopwatch()..start();

    Future<ApduResponse> send(Uint8List apdu, String context) async {
      _checkCancelled();
      final r = await link.transceive(apdu);
      return r.requireOk(context);
    }

    try {
      _stage(WriteStage.connecting, link.name);

      _stage(WriteStage.readingInfo);
      info = DeviceInfo.parse(await link.transceive(Apdu.readInfo));
      onLog?.call('D1 返回：${info.toChinese()}');
      if (!info.isTargetPanel) {
        onLog?.call('警告：屏幕不是 552×768 四色且支持压缩的型号，像素排布可能不对。');
      }

      _stage(WriteStage.authenticating);
      var d8 = await link.transceive(Apdu.checkAccess);
      onLog?.call('D8 返回：SW=${d8.swHex}');
      if (d8.sw == 0x6985) {
        if (settings.pin.length != 5) {
          throw StateError('PIN 必须正好 5 字节');
        }
        final pinApdu = Apdu.verifyPin(settings.pin);
        final pinResult = await link.transceive(pinApdu);
        onLog?.call('PIN 返回：SW=${pinResult.swHex}');
        pinResult.requireOk('PIN 认证');
        d8 = await link.transceive(Apdu.checkAccess);
        onLog?.call('PIN 后再次 D8：SW=${d8.swHex}');
        d8.requireOk('PIN 后的访问权限检查');
      } else if (!d8.isOk) {
        d8.requireOk('access rights');
      }

      _stage(WriteStage.transferring,
          '${plan.packetCount} 个数据包，${plan.blockCount} 个块');
      for (var i = 0; i < plan.packets.length; i++) {
        _checkCancelled();
        final p = plan.packets[i];
        final r = await link.transceive(p.apdu);
        if (!r.isOk) {
          throw FmscStatusException('图像传输 块${p.block}/包${p.sub}', r.sw);
        }
        sent++;
        onProgress?.call(WriteProgress(
          stage: WriteStage.transferring,
          completedPackets: sent,
          totalPackets: plan.packetCount,
          message: '块 ${p.block} / ${plan.blockCount}',
        ));
        if (settings.packetGapMs > 0 && i + 1 < plan.packets.length) {
          await Future<void>.delayed(Duration(milliseconds: settings.packetGapMs));
        }
      }
      onLog?.call('图像发送完成：$sent/${plan.packetCount} 包');

      if (settings.preRefreshWaitMs > 0) {
        _stage(WriteStage.refreshing,
            '刷新前保持射频场 ${settings.preRefreshWaitMs} 毫秒');
        await Future<void>.delayed(Duration(milliseconds: settings.preRefreshWaitMs));
        _checkCancelled();
      }

      _stage(WriteStage.refreshing);
      final refresh = Apdu.refresh(powerOnDelayMs: settings.powerOnDelayMs);
      final d4 = await send(refresh, '触发刷新');
      onLog?.call('D4 返回：SW=${d4.swHex}');
      if (d4.payload.isNotEmpty &&
          !(d4.payload.length == 1 && (d4.payload[0] == 0 || d4.payload[0] == 1))) {
        throw StateError('D4 返回了意外的数据：${d4.payload}');
      }

      _stage(WriteStage.polling);
      final deadline = stopwatch.elapsedMilliseconds + settings.refreshBudgetMs;
      while (true) {
        _checkCancelled();
        if (stopwatch.elapsedMilliseconds >= deadline) {
          throw TimeoutException(
              '刷新等待超过 ${settings.refreshBudgetMs} 毫秒预算');
        }
        final r = await send(Apdu.readStatus, '查询刷新状态');
        polls++;
        if (r.payload.isEmpty) {
          throw StateError('DE 未返回状态字节');
        }
        final busy = r.payload[0];
        if (busy != 0 && busy != 1) {
          throw StateError('DE 返回未知状态 ${busy.toRadixString(16)}');
        }
        if (busy == 1) sawBusy = true;
        onProgress?.call(WriteProgress(
          stage: WriteStage.polling,
          polls: polls,
          message: busy == 1 ? '屏幕正在刷新' : '屏幕空闲',
        ));

        if (busy == 0) {
          // epd_writer requires three consecutive idle samples once BUSY was
          // seen, and reports "unconfirmed" when BUSY never appeared.
          if (sawBusy) {
            for (var k = 0; k < 2; k++) {
              await Future<void>.delayed(
                  Duration(milliseconds: settings.pollIntervalMs));
              _checkCancelled();
              final again = await send(Apdu.readStatus, '查询刷新状态');
              polls++;
              if (again.payload.isEmpty || again.payload[0] != 0) {
                sawBusy = true; // still working
                break;
              }
            }
            if (sawBusy) {
              await Future<void>.delayed(
                  Duration(milliseconds: settings.pollIntervalMs));
              continue;
            }
            _stage(WriteStage.done, '刷新已确认');
            return WriteOutcome(
              succeeded: true,
              stage: WriteStage.done,
              deviceInfo: info,
              completedPackets: sent,
              polls: polls,
              busyObserved: true,
            );
          }
          _stage(WriteStage.done,
              '屏幕报告空闲，但全程未观测到忙状态，刷新未确认');
          return WriteOutcome(
            succeeded: true,
            stage: WriteStage.done,
            deviceInfo: info,
            completedPackets: sent,
            polls: polls,
            busyObserved: false,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: settings.pollIntervalMs));
      }
    } on _CancelledException catch (e) {
      _stage(WriteStage.failed, e.message);
      return WriteOutcome(
          succeeded: false,
          stage: WriteStage.failed,
          error: e.message,
          deviceInfo: info,
          completedPackets: sent,
          polls: polls,
          busyObserved: sawBusy);
    } on LinkException catch (e) {
      _stage(WriteStage.failed, e.message);
      return WriteOutcome(
          succeeded: false,
          stage: WriteStage.failed,
          error: e.message,
          deviceInfo: info,
          completedPackets: sent,
          polls: polls,
          busyObserved: sawBusy);
    } on FmscStatusException catch (e) {
      _stage(WriteStage.failed, e.toString());
      return WriteOutcome(
          succeeded: false,
          stage: WriteStage.failed,
          error: e.toString(),
          deviceInfo: info,
          completedPackets: sent,
          polls: polls,
          busyObserved: sawBusy);
    } catch (e) {
      _stage(WriteStage.failed, '$e');
      return WriteOutcome(
          succeeded: false,
          stage: WriteStage.failed,
          error: '$e',
          deviceInfo: info,
          completedPackets: sent,
          polls: polls,
          busyObserved: sawBusy);
    }
  }

  void _checkCancelled() {
    if (_cancel?.isCancelled ?? false) {
      throw const _CancelledException('cancelled; panel state unknown');
    }
  }
}

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _CancelledException implements Exception {
  const _CancelledException(this.message);
  final String message;
  @override
  String toString() => message;
}
