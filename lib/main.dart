import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:ui' as ui;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'IMU Recorder',
      home: SensorRecorderPage(),
    );
  }
}

enum SensorKind { accelerometer, gyroscope, magnetometer }

// 統一三軸顏色：x=紅、y=綠、z=藍
const _xColor = Colors.red;
const _yColor = Colors.green;
const _zColor = Colors.blue;

class Sample {
  final double t; // seconds since start
  final double ax, ay, az, gx, gy, gz, mx, my, mz;
  const Sample({
    required this.t,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.mx,
    required this.my,
    required this.mz,
  });
}

class SensorRecorderPage extends StatefulWidget {
  const SensorRecorderPage({super.key});
  @override
  State<SensorRecorderPage> createState() => _SensorRecorderPageState();
}

enum _ResPreset { hd, fhd, qhd, uhd4k, square2k, custom }

_ResPreset _preset = _ResPreset.fhd; // 預設 1920x1080
final _wCtrl = TextEditingController(text: '1920');
final _hCtrl = TextEditingController(text: '1080');

Size _currentPngSize() {
  if (_preset == _ResPreset.custom) {
    final w = int.tryParse(_wCtrl.text.trim()) ?? 1600;
    final h = int.tryParse(_hCtrl.text.trim()) ?? 900;
    // 避免太小或太大佔記憶體
    final cw = w.clamp(320, 8192);
    final ch = h.clamp(240, 8192);
    return Size(cw.toDouble(), ch.toDouble());
  }
  switch (_preset) {
    case _ResPreset.hd:      return const Size(1280, 720);
    case _ResPreset.fhd:     return const Size(1920, 1080);
    case _ResPreset.qhd:     return const Size(2560, 1440);
    case _ResPreset.uhd4k:   return const Size(3840, 2160);
    case _ResPreset.square2k:return const Size(2048, 2048);
    case _ResPreset.custom:  return const Size(1600, 900);
  }
}

class _SensorRecorderPageState extends State<SensorRecorderPage>
    with WidgetsBindingObserver {
  // ===== UI 控制 =====
  final _hzCtrl = TextEditingController(text: '50'); // 取樣率 X Hz
  final _secCtrl = TextEditingController(text: '10'); // 錄製秒數 Y s
  bool _isRecording = false;
  SensorKind _chartKind = SensorKind.accelerometer;
  final _chartKey = GlobalKey();       // 用來抓取圖表區域
  String? _lastPngPath;                // 最近一次存的 PNG

  // ===== 感測器最新值（由 stream 更新；Timer 每 tick 讀一次寫入 buffer）=====
  double _ax = 0, _ay = 0, _az = 0;
  double _gx = 0, _gy = 0, _gz = 0;
  double _mx = 0, _my = 0, _mz = 0;

  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  // ===== 錄製狀態 =====
  Timer? _timer;
  DateTime? _startAt;
  final List<Sample> _buf = [];
  String? _lastCsvPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 訂閱三個 IMU（畫面顯示 + 暫存最新值）
    _accSub = accelerometerEventStream().listen((e) {
      _ax = e.x; _ay = e.y; _az = e.z;
      if (mounted && !_isRecording) setState(() {});
    });
    _gyroSub = gyroscopeEventStream().listen((g) {
      _gx = g.x; _gy = g.y; _gz = g.z;
      if (mounted && !_isRecording) setState(() {});
    });
    _magSub = magnetometerEventStream().listen((m) {
      _mx = m.x; _my = m.y; _mz = m.z;
      if (mounted && !_isRecording) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _accSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    _hzCtrl.dispose();
    _secCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 省電：背景時暫停，回前景恢復
    if (state == AppLifecycleState.paused) {
      _accSub?.pause(); _gyroSub?.pause(); _magSub?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _accSub?.resume(); _gyroSub?.resume(); _magSub?.resume();
    }
  }

  // ===== 錄製控制 =====
  void _start() {
    final hz = int.tryParse(_hzCtrl.text.trim());
    final sec = double.tryParse(_secCtrl.text.trim());
    if (hz == null || hz <= 0 || sec == null || sec <= 0) {
      _snack('請輸入有效的 X(Hz) / Y(秒)');
      return;
    }
    _buf.clear();
    _startAt = DateTime.now();
    final intervalMs = (1000 / hz).round().clamp(1, 1000);
    setState(() { _isRecording = true; _lastCsvPath = null; });

    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (t) async {
      final elapsed =
          DateTime.now().difference(_startAt!).inMilliseconds / 1000.0;
      _buf.add(Sample(
        t: elapsed,
        ax: _ax, ay: _ay, az: _az,
        gx: _gx, gy: _gy, gz: _gz,
        mx: _mx, my: _my, mz: _mz,
      ));
      if (elapsed >= sec) {
        _stop(save: true);
      } else {
        if (mounted) setState(() {}); // 讓圖持續更新
      }
    });
  }

  Future<void> _stop({bool save = false}) async {
    _timer?.cancel();
    _timer = null;
    setState(() { _isRecording = false; });
    if (save && _buf.isNotEmpty) {
      await _saveCsv();
    }
  }

  // 圖像存檔功能
  // 放在檔案最上方已經有：import 'dart:ui' as ui;
  // 進行重繪
  Future<void> _saveChartPngOffscreen() async {
    try {
      // 1) 準備要畫的資料（三條：x/y/z，依你選的 _chartKind）
      List<Offset> _toSeries(List<Sample> buf, double Function(Sample) pick) =>
          buf.map((s) => Offset(s.t, pick(s))).toList();

      late final List<Offset> sx, sy, sz;
      if (_buf.isEmpty) {
        _snack('沒有資料可輸出');
        return;
      }
      switch (_chartKind) {
        case SensorKind.accelerometer:
          sx = _toSeries(_buf, (s) => s.ax);
          sy = _toSeries(_buf, (s) => s.ay);
          sz = _toSeries(_buf, (s) => s.az);
          break;
        case SensorKind.gyroscope:
          sx = _toSeries(_buf, (s) => s.gx);
          sy = _toSeries(_buf, (s) => s.gy);
          sz = _toSeries(_buf, (s) => s.gz);
          break;
        case SensorKind.magnetometer:
          sx = _toSeries(_buf, (s) => s.mx);
          sy = _toSeries(_buf, (s) => s.my);
          sz = _toSeries(_buf, (s) => s.mz);
          break;
      }

      // 2) 畫到離屏畫布（可調整輸出尺寸）
      final ui.Image img = await _renderLinesToImage(
        series: [sx, sy, sz],
        colors: const [_xColor, _yColor, _zColor],
        size: _currentPngSize(),                 // ← 用使用者選的解析度
        bgColor: Theme.of(context).colorScheme.surface,
        xLabel: 't (sec)',
        yLabel: _chartKind == SensorKind.accelerometer
            ? 'acc (m/s²)'
            : _chartKind == SensorKind.gyroscope
                ? 'gyro (rad/s)'
                : 'mag (µT)',
      );

      // 3) 存檔
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      final dir = await getApplicationDocumentsDirectory();
      final fname =
          'imu_plot_offscreen_${DateTime.now().toIso8601String().replaceAll(":", "-")}.png';
      final file = File('${dir.path}/$fname');
      await file.writeAsBytes(bytes);
      setState(() => _lastPngPath = file.path);

      _snack('已儲存圖檔：$fname');
    } catch (e) {
      _snack('存圖失敗：$e');
    }
  }

  Future<ui.Image> _renderLinesToImage({
    required List<List<Offset>> series,   // 每條線是 (t, value)
    required List<Color> colors,
    required Size size,
    required Color bgColor,
    String? xLabel,
    String? yLabel,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paintBg = Paint()..color = bgColor;
    canvas.drawRect(Offset.zero & size, paintBg);

    // 內距：給座標軸/標籤空間
    const double leftPad = 80, rightPad = 24, topPad = 24, bottomPad = 60;
    final chartRect = Rect.fromLTWH(
      leftPad, topPad, size.width - leftPad - rightPad, size.height - topPad - bottomPad,
    );

    // 計算數值範圍（x 為時間、y 依各 series）
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    for (final s in series) {
      for (final p in s) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    if (minX == maxX) { minX -= 0.5; maxX += 0.5; } // 避免除以零
    if (minY == maxY) { minY -= 0.5; maxY += 0.5; }

    // 給 5% padding，看起來不會貼邊
    final xPad = (maxX - minX) * 0.05;
    final yPad = (maxY - minY) * 0.1;
    minX -= xPad; maxX += xPad;
    minY -= yPad; maxY += yPad;

    double mapX(double x) => chartRect.left +
        (x - minX) / (maxX - minX) * chartRect.width;
    double mapY(double y) => chartRect.bottom -
        (y - minY) / (maxY - minY) * chartRect.height;

    // 畫網格與座標軸
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.35)
      ..strokeWidth = 1;
    const int xTicks = 6, yTicks = 5;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // 垂直網格 + x tick
    for (int i = 0; i <= xTicks; i++) {
      final t = minX + (maxX - minX) * (i / xTicks);
      final x = mapX(t);
      canvas.drawLine(Offset(x, chartRect.top), Offset(x, chartRect.bottom), gridPaint);
      final label = t.toStringAsFixed(2);
      textPainter.text = TextSpan(style: const TextStyle(fontSize: 12, color: Colors.grey), text: label);
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, chartRect.bottom + 6),
      );
    }

    // 水平網格 + y tick
    for (int i = 0; i <= yTicks; i++) {
      final v = minY + (maxY - minY) * (i / yTicks);
      final y = mapY(v);
      canvas.drawLine(Offset(chartRect.left, y), Offset(chartRect.right, y), gridPaint);
      final label = v.toStringAsFixed(2);
      textPainter.text = const TextSpan(style: TextStyle(fontSize: 12, color: Colors.grey));
      textPainter.text = TextSpan(style: const TextStyle(fontSize: 12, color: Colors.grey), text: label);
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(chartRect.left - textPainter.width - 8, y - textPainter.height / 2),
      );
    }

    // 外框
    final borderPaint = Paint()
      ..color = Colors.grey.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(chartRect, borderPaint);

    // 畫三條線
    for (int k = 0; k < series.length; k++) {
      final s = series[k];
      if (s.isEmpty) continue;
      final path = Path();
      for (int i = 0; i < s.length; i++) {
        final dx = mapX(s[i].dx);
        final dy = mapY(s[i].dy);
        if (i == 0) {
          path.moveTo(dx, dy);
        } else {
          path.lineTo(dx, dy);
        }
      }
      final p = Paint()
        ..color = colors[k]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = true;
      canvas.drawPath(path, p);
    }

    // 標籤（x/y）
    if (xLabel != null) {
      textPainter.text = TextSpan(style: const TextStyle(fontSize: 13, color: Colors.grey), text: xLabel);
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(chartRect.center.dx - textPainter.width / 2, size.height - textPainter.height - 6),
      );
    }
    if (yLabel != null) {
      textPainter.text = TextSpan(style: const TextStyle(fontSize: 13, color: Colors.grey), text: yLabel);
      textPainter.layout();
      canvas.save();
      canvas.translate(12, chartRect.center.dy + textPainter.width / 2);
      canvas.rotate(-3.14159 / 2);
      textPainter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    final picture = recorder.endRecording();
    return picture.toImage(size.width.toInt(), size.height.toInt());
  }

  
  // 分享圖像
  void _shareImage() {
    final p = _lastPngPath;
    if (p == null) { _snack('尚未有圖檔'); return; }
    Share.shareXFiles(
      [XFile(p, mimeType: 'image/png', name: p.split('/').last)],
      subject: 'IMU Plot',
      text: 'IMU plot captured from Flutter',
    );
  }

  Future<void> _saveCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final fname =
        'imu_${DateTime.now().toIso8601String().replaceAll(":", "-")}.csv';
    final file = File('${dir.path}/$fname');

    final sb = StringBuffer();
    sb.writeln('t_sec,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,mag_x,mag_y,mag_z');
    for (final s in _buf) {
      sb.writeln(
          '${s.t.toStringAsFixed(3)},'
          '${s.ax.toStringAsFixed(6)},${s.ay.toStringAsFixed(6)},${s.az.toStringAsFixed(6)},'
          '${s.gx.toStringAsFixed(6)},${s.gy.toStringAsFixed(6)},${s.gz.toStringAsFixed(6)},'
          '${s.mx.toStringAsFixed(6)},${s.my.toStringAsFixed(6)},${s.mz.toStringAsFixed(6)}');
    }
    await file.writeAsString(sb.toString());
    setState(() { _lastCsvPath = file.path; });
    _snack('CSV 已儲存：$fname');
  }

  void _share() {
    final p = _lastCsvPath;
    if (p == null) { _snack('尚未有錄製檔'); return; }
    Share.shareXFiles([XFile(p)], text: 'IMU CSV from Flutter');
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ===== 繪圖資料轉換 =====
  List<LineChartBarData> _buildSeries() {

    List<FlSpot> sx = [], sy = [], sz = [];
    for (final s in _buf) {
      switch (_chartKind) {
        case SensorKind.accelerometer:
          sx.add(FlSpot(s.t, s.ax)); sy.add(FlSpot(s.t, s.ay)); sz.add(FlSpot(s.t, s.az)); break;
        case SensorKind.gyroscope:
          sx.add(FlSpot(s.t, s.gx)); sy.add(FlSpot(s.t, s.gy)); sz.add(FlSpot(s.t, s.gz)); break;
        case SensorKind.magnetometer:
          sx.add(FlSpot(s.t, s.mx)); sy.add(FlSpot(s.t, s.my)); sz.add(FlSpot(s.t, s.mz)); break;
      }
    }
    LineChartBarData _l(List<FlSpot> pts, Color c) => LineChartBarData(
      spots: pts,
      isCurved: false,
      dotData: const FlDotData(show: false),
      barWidth: 2,
      color: c,
    );
    return [_l(sx, _xColor), _l(sy, _yColor), _l(sz, _zColor)];
  }

  @override
  Widget build(BuildContext context) {
    final latest = [
      ('ACC (m/s²)', _ax, _ay, _az),
      ('GYRO (rad/s)', _gx, _gy, _gz),
      ('MAG (µT)', _mx, _my, _mz),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('IMU Recorder')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // ===== 控制列：X Hz / Y 秒 + Start/Stop + Share CSV + Save =====
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _NumBox(controller: _hzCtrl, label: 'X (Hz)'),
                _NumBox(controller: _secCtrl, label: 'Y (秒)'),
                ElevatedButton.icon(
                  onPressed: _isRecording ? null : _start,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Start'),
                ),
                OutlinedButton.icon(
                  onPressed: _isRecording ? () => _stop(save: true) : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                // Share 改成有文字，螢幕窄會自動換到下一行；若尚未有檔案則停用
                ElevatedButton.icon(
                  onPressed: _lastCsvPath == null ? null : _share,
                  icon: const Icon(Icons.share),
                  label: const Text('Share CSV'),
                ),
                // 圖像儲存與分享按鈕
                OutlinedButton.icon(
                  onPressed: _saveChartPngOffscreen,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Save PNG'),
                ),
                ElevatedButton.icon(
                  onPressed: _lastPngPath == null ? null : _shareImage,
                  icon: const Icon(Icons.share),
                  label: const Text('Share PNG'),
                ),
                // ===== 輸出圖像解析度調整功能 =====
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('解析度:'),
                    const SizedBox(width: 8),
                    DropdownButton<_ResPreset>(
                      value: _preset,
                      items: const [
                        DropdownMenuItem(value: _ResPreset.hd,      child: Text('1280×720')),
                        DropdownMenuItem(value: _ResPreset.fhd,     child: Text('1920×1080')),
                        DropdownMenuItem(value: _ResPreset.qhd,     child: Text('2560×1440')),
                        DropdownMenuItem(value: _ResPreset.uhd4k,   child: Text('3840×2160')),
                        DropdownMenuItem(value: _ResPreset.square2k,child: Text('2048×2048')),
                        DropdownMenuItem(value: _ResPreset.custom,  child: Text('自訂')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _preset = v;
                          // 切到預設時，同步輸入框文字（只為了顯示一致）
                          if (v != _ResPreset.custom) {
                            final s = _currentPngSize();
                            _wCtrl.text = s.width.toInt().toString();
                            _hCtrl.text = s.height.toInt().toString();
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    if (_preset == _ResPreset.custom) ...[
                      _NumBox(controller: _wCtrl, label: 'Width'),
                      const SizedBox(width: 8),
                      _NumBox(controller: _hCtrl, label: 'Height'),
                    ],
                  ],
                ),
              ],
            ),
            
            // ===== 即時數值（以彩色點標示 x/y/z）=====
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: latest.map((e) {
                final title = e.$1;
                final v = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LegendDot(color: _xColor, label: 'x:${e.$2.toStringAsFixed(2)}  '),
                    _LegendDot(color: _yColor, label: 'y:${e.$3.toStringAsFixed(2)}  '),
                    _LegendDot(color: _zColor, label: 'z:${e.$4.toStringAsFixed(2)}'),
                  ],
                );
                return Chip(label: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('$title  '), v,
                ]));
              }).toList(),
            ),
            const SizedBox(height: 8),

            // ===== 繪圖選擇器 + 圖例 =====
            Row(
              children: [
                const Text('Plot:'),
                const SizedBox(width: 8),
                DropdownButton<SensorKind>(
                  value: _chartKind,
                  items: const [
                    DropdownMenuItem(
                      value: SensorKind.accelerometer, child: Text('Accelerometer')),
                    DropdownMenuItem(
                      value: SensorKind.gyroscope, child: Text('Gyroscope')),
                    DropdownMenuItem(
                      value: SensorKind.magnetometer, child: Text('Magnetometer')),
                  ],
                  onChanged: (v) => setState(() => _chartKind = v!),
                ),
                const Spacer(),
                Row(children: const [
                  _Legend(color: _xColor, text: 'x'),
                  SizedBox(width: 8),
                  _Legend(color: _yColor, text: 'y'),
                  SizedBox(width: 8),
                  _Legend(color: _zColor, text: 'z'),
                ]),
                const Spacer(),
                Text('樣本數：${_buf.length}'),
              ],
            ),

            const SizedBox(height: 8),
            // ===== 折線圖 =====  
            Expanded(
              child: RepaintBoundary( // 將該ChartWidget包裝並綁到GlobalKey以供圖像存儲功能存取
                key: _chartKey,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: LineChart(
                      LineChartData(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        minX: 0,
                        maxX: _buf.isEmpty ? 1 : _buf.last.t,
                        clipData: FlClipData.none(),
                        titlesData: const FlTitlesData(
                          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        ),
                        gridData: const FlGridData(drawVerticalLine: true),
                        borderData: FlBorderData(show: true),
                        lineBarsData: _buildSeries(),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (_lastCsvPath != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text('已儲存：$_lastCsvPath',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 8),

            // ===== 動作提示卡（Demo 錄影超好用）=====
            _HintCard(),
          ],
        ),
      ),
    );
  }
}

// 簡易數字輸入框
class _NumBox extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  const _NumBox({required this.controller, required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

// 彩色圖例點
class _Legend extends StatelessWidget {
  final Color color;
  final String text;
  const _Legend({required this.color, required this.text});
  
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(text),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }
}

// 動作提示卡（方形路徑／翻轉）
class _HintCard extends StatelessWidget {
  const _HintCard();
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: const [
              Icon(Icons.tips_and_updates_outlined, size: 18),
              SizedBox(width: 6),
              Text('動作提示'),
            ]),
            const SizedBox(height: 6),
            Text('① 方形路徑（順時針）', style: style?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('‧ 模擬器：More(…)> Virtual sensors > Move，拖曳 X/Y 滑桿畫出順時針方形路徑。',
                style: style),
            Text('‧ 實機：手機平放於桌面，沿桌面畫一個順時針方形移動。', style: style),
            const SizedBox(height: 8),
            Text('② 沿 Y 軸逆時針翻轉', style: style?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('‧ 模擬器：More(…)> Virtual sensors > Device Pose/Rotate，調整對應 Y 軸的旋轉控制，做逆時針翻轉。',
                style: style),
            Text('‧ 實機：手持手機，沿左右邊緣連線的軸做逆時針旋轉。', style: style),
          ],
        ),
      ),
    );
  }
}
