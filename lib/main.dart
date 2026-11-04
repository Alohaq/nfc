import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'src/epd/hex.dart';
import 'src/epd/nfc_session.dart';
import 'src/epd/protocol.dart';
import 'src/epd/tag_link.dart';
import 'src/epd/writer.dart';
import 'src/image/processor.dart';
import 'src/image/quantizer.dart' show FrameGeometry;
import 'src/ui/probe_page.dart';

void main() => runApp(const EpdApp());

class EpdApp extends StatelessWidget {
  const EpdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ink panel writer',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // --- image state -------------------------------------------------------
  ui.Image? _source;
  PreparedFrame? _frame;
  bool _processing = false;
  ProcessOptions _options = const ProcessOptions();
  String? _sourceName;

  // --- nfc state ---------------------------------------------------------
  NfcSession? _session;
  bool _nfcAvailable = false;
  String? _transportLabel = 'not connected';
  bool _canShortFrames = false;

  // --- write state -------------------------------------------------------
  WriteStage _stage = WriteStage.idle;
  String _stageMessage = '';
  int _sentPackets = 0;
  int _totalPackets = 0;
  int _polls = 0;
  DeviceInfo? _info;
  final CancelToken _cancel = CancelToken();
  bool _busy = false;

  // --- settings ----------------------------------------------------------
  WriteSettings _settings = const WriteSettings();
  final _pinController = TextEditingController(text: '5265699919');
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _refreshAvailability();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _pinController.dispose();
    _session?.link.close();
    super.dispose();
  }

  void _addLog(String line) {
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    setState(() {
      _log.insert(0, '$stamp  $line');
      if (_log.length > 400) _log.removeLast();
    });
  }

  Future<void> _refreshAvailability() async {
    bool available = false;
    try {
      available = await NfcSession.isAvailable();
    } catch (e) {
      _addLog('availability check failed: $e');
    }
    if (mounted) setState(() => _nfcAvailable = available);
  }

  // ------------------------------------------------------------------ image

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final decoded = await codec.getNextFrame();
    setState(() {
      _source?.dispose();
      _source = decoded.image;
      _sourceName = file.name;
      _frame = null;
    });
    await _reprocess();
  }

  Future<void> _reprocess() async {
    final source = _source;
    if (source == null) return;
    setState(() => _processing = true);
    try {
      final frame = await ImageProcessor.process(source, _options);
      if (!mounted) return;
      setState(() {
        _frame?.preview.dispose();
        _frame = frame;
      });
    } catch (e, st) {
      _addLog('processing failed: $e');
      debugPrint('$st');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _updateOptions(ProcessOptions next) {
    setState(() => _options = next);
    _reprocess();
  }

  // -------------------------------------------------------------------- nfc

  Future<bool> _ensureSession({required String alert}) async {
    final existing = _session;
    if (existing != null) return true;
    setState(() => _stage = WriteStage.connecting);
    try {
      final session = await NfcSession.start(
        alertMessage: alert,
        onRejected: (reason) => _addLog('tag rejected: ${reason.message}'),
      );
      _session = session;
      _transportLabel = session.link.name;
      _canShortFrames = session.link.canSendShortFrames;
      _addLog('connected via ${session.link.name}');
      if (mounted) setState(() {});
      return true;
    } on LinkException catch (e) {
      _addLog(e.message);
      _stage = WriteStage.failed;
      _stageMessage = e.message;
      if (mounted) setState(() {});
      return false;
    }
  }

  Future<void> _disconnect() async {
    final session = _session;
    _session = null;
    _transportLabel = 'not connected';
    _canShortFrames = false;
    await session?.link.close(alertMessage: 'Disconnected');
    if (mounted) setState(() {});
  }

  Future<void> _probe() async {
    if (!await _ensureSession(alert: 'Hold the phone against the panel')) return;
    final link = _session!.link;
    setState(() => _busy = true);
    try {
      final outcome = await Writer(
        link: link,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _stage = p.stage;
            _stageMessage = p.message;
          });
        },
        onLog: _addLog,
      ).probe(_settings);
      _info = outcome.deviceInfo;
      _addLog(outcome.summary);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _write() async {
    final plan = _frame?.buildPlan();
    if (plan == null) {
      _addLog('no image ready');
      return;
    }
    if (!await _ensureSession(alert: 'Keep the phone on the panel until done')) {
      return;
    }
    final link = _session!.link;
    setState(() {
      _busy = true;
      _sentPackets = 0;
      _totalPackets = plan.packetCount;
      _polls = 0;
    });
    try {
      final outcome = await Writer(
        link: link,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _stage = p.stage;
            _stageMessage = p.message;
            if (p.completedPackets > 0) _sentPackets = p.completedPackets;
            if (p.totalPackets > 0) _totalPackets = p.totalPackets;
            if (p.polls > 0) _polls = p.polls;
          });
        },
        onLog: _addLog,
      ).write(plan, _settings, cancel: _cancel);
      _info = outcome.deviceInfo ?? _info;
      _addLog(outcome.summary);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(outcome.summary)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyPin(String text) {
    try {
      final bytes = hexParse(text);
      if (bytes.length != 5) {
        _addLog('PIN must be 5 bytes, got ${bytes.length}');
        return;
      }
      setState(() => _settings = _settings.copyWith(pin: bytes));
      _addLog('PIN set to ${bytes.length} bytes');
    } catch (e) {
      _addLog('bad PIN: $e');
    }
  }

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ink panel writer'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Write'), Tab(text: 'Probe')],
        ),
        actions: [
          IconButton(
            tooltip: _nfcAvailable ? 'NFC ready' : 'NFC unavailable',
            icon: Icon(_nfcAvailable ? Icons.nfc : Icons.nfc_outlined,
                color: _nfcAvailable ? null : Theme.of(context).colorScheme.error),
            onPressed: _refreshAvailability,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildWriteTab(),
          ProbePage(
            log: _log,
            transportName: _transportLabel ?? 'not connected',
            canUseShortFrames: _canShortFrames,
            onSendApdu: (hex) async {
              if (!await _ensureSession(alert: 'Hold the phone against the panel')) {
                return null;
              }
              final bytes = hexParse(hex);
              final response = await _session!.link.transceive(bytes);
              _addLog('$hex -> ${response.swHex} ${response.swMeaning}');
              return response;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWriteTab() {
    final theme = Theme.of(context);
    final frame = _frame;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _sourceName ?? 'No image selected',
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Pick'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 552 / 768,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.dividerColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: _processing
                        ? const Center(child: CircularProgressIndicator())
                        : frame == null
                            ? Center(
                                child: Text('Pick an image to preview',
                                    style: theme.textTheme.bodySmall))
                            : RawImage(image: frame.preview, fit: BoxFit.contain),
                  ),
                ),
                if (frame != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${FrameGeometry.width}x${FrameGeometry.height} 路 '
                    '${frame.options.dither.label} 路 '
                    '${frame.paletteSize} colours 路 '
                    '${frame.packed.length} packed bytes',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildAdjustments(),
        const SizedBox(height: 12),
        _buildTransferCard(),
        const SizedBox(height: 12),
        _buildLogCard(),
      ],
    );
  }

  Widget _buildAdjustments() {
    return Card(
      child: ExpansionTile(
        title: const Text('Image adjustments'),
        subtitle: Text(_options.isNeutral ? 'defaults' : 'modified'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Row(
            children: [
              const Text('Dither'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<DitherMode>(
                  isExpanded: true,
                  value: _options.dither,
                  items: [
                    for (final m in DitherMode.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) =>
                      m == null ? null : _updateOptions(_options.copyWith(dither: m)),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Black & white only'),
            value: _options.blackWhite,
            onChanged: (v) => _updateOptions(_options.copyWith(blackWhite: v)),
          ),
          Row(
            children: [
              const Text('Fit'),
              const SizedBox(width: 12),
              DropdownButton<BoxFit>(
                value: _options.fit,
                items: const [
                  DropdownMenuItem(value: BoxFit.contain, child: Text('Contain')),
                  DropdownMenuItem(value: BoxFit.cover, child: Text('Cover')),
                ],
                onChanged: (v) =>
                    v == null ? null : _updateOptions(_options.copyWith(fit: v)),
              ),
              const Spacer(),
              DropdownButton<int>(
                value: _options.rotation,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('0掳')),
                  DropdownMenuItem(value: 90, child: Text('90掳')),
                  DropdownMenuItem(value: 180, child: Text('180掳')),
                  DropdownMenuItem(value: 270, child: Text('270掳')),
                ],
                onChanged: (v) =>
                    v == null ? null : _updateOptions(_options.copyWith(rotation: v)),
              ),
            ],
          ),
          _slider('Brightness', _options.brightness, 0.5, 1.5,
              (v) => _updateOptions(_options.copyWith(brightness: v))),
          _slider('Contrast', _options.contrast, 0.5, 1.5,
              (v) => _updateOptions(_options.copyWith(contrast: v))),
          _slider('Scale', _options.scalePercent.toDouble(), 10, 300,
              (v) => _updateOptions(_options.copyWith(scalePercent: v.round())),
              divisions: 58, suffix: '%'),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged,
      {int? divisions, String suffix = ''}) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text('${value.toStringAsFixed(1)}$suffix',
              textAlign: TextAlign.end,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildTransferCard() {
    final theme = Theme.of(context);
    final total = _totalPackets;
    final progress = total == 0 ? null : _sentPackets / total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.nfc, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_transportLabel ?? 'not connected',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace')),
                ),
                if (_session != null)
                  TextButton(onPressed: _disconnect, child: const Text('Close')),
              ],
            ),
            const Divider(),
            Text('${_stage.label}${_stageMessage.isEmpty ? '' : ' 鈥?$_stageMessage'}'),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text('$_sentPackets / $total packets', style: theme.textTheme.bodySmall),
            ],
            if (_polls > 0)
              Text('$_polls status polls', style: theme.textTheme.bodySmall),
            if (_info != null) ...[
              const SizedBox(height: 8),
              Text('Panel: $_info',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace')),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _probe,
                    icon: const Icon(Icons.search),
                    label: const Text('Probe'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _busy || _frame == null ? null : _write,
                    icon: const Icon(Icons.upload),
                    label: const Text('Upload & refresh'),
                  ),
                ),
              ],
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    const Text('working…'),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        _cancel.cancel();
                        _addLog('cancel requested');
                      },
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Transfer settings'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pinController,
                        style: const TextStyle(fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: 'PIN (10 hex chars)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _applyPin(_pinController.text),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
                _slider('Packet gap', _settings.packetGapMs.toDouble(), 0, 100,
                    (v) => setState(() => _settings =
                        _settings.copyWith(packetGapMs: v.round())),
                    divisions: 20, suffix: 'ms'),
                _slider('Pre-D4 wait', _settings.preRefreshWaitMs.toDouble(), 0, 5000,
                    (v) => setState(() => _settings =
                        _settings.copyWith(preRefreshWaitMs: v.round())),
                    divisions: 50, suffix: 'ms'),
                _slider('Power-on wait', _settings.powerOnDelayMs.toDouble(), 100, 12700,
                    (v) => setState(() => _settings = _settings.copyWith(
                        powerOnDelayMs: (v / 100).round() * 100)),
                    divisions: 126, suffix: 'ms'),
                _slider('Poll interval', _settings.pollIntervalMs.toDouble(), 120, 2000,
                    (v) => setState(() =>
                        _settings = _settings.copyWith(pollIntervalMs: v.round())),
                    divisions: 47, suffix: 'ms'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard() {
    return Card(
      child: ExpansionTile(
        title: const Text('Log'),
        subtitle: Text('${_log.length} lines'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Container(
            height: 240,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, color: Color(0xFFB9F6CA)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(_log.clear),
              child: const Text('Clear'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin alias so the UI reads naturally; parsing rules live in [Hex].
Uint8List hexParse(String text) => Hex.parse(text);
