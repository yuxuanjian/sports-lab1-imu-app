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

enum SensorKind {
  accelerometer,   // 原始加速度
  gyroscope,       // 原始角速度
  magnetometer,    // 原始磁力
  velocity,        // 由加速度積分 -> 速度
  displacement,    // 由加速度兩次積分 -> 位移
  orientation,     // 由角速度積分 -> 角度(rad)
}

// 統一三軸顏色：x=紅、y=綠、z=藍
const _xColor = Colors.red;
const _yColor = Colors.green;
const _zColor = Colors.blue;

/// 感測資料樣本（原始九軸）
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

// -------- PNG 解析度選單 --------
enum _ResPreset { hd, fhd, qhd, uhd4k, square2k, custom }

_ResPreset _preset = _ResPreset.fhd; // 預設 1920x1080
final _wCtrl = TextEditingController(text: '1920');
final _hCtrl = TextEditingController(text: '1080');

Size _currentPngSize() {
  if (_preset == _ResPreset.custom) {
    final w = int.tryParse(_wCtrl.text.trim()) ?? 1600;
    final h = int.tryParse(_hCtrl.text.trim()) ?? 900;
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

class SensorRecorderPage extends StatefulWidget {
  const SensorRecorderPage({super.key});
  @override
  State<SensorRecorderPage> createState() => _SensorRecorderPageState();
}

class _SensorRecorderPageState extends State<SensorRecorderPage>
    with WidgetsBindingObserver {
  // ===== UI 控制 =====
  final _hzCtrl = TextEditingController(text: '60'); // 取樣率 X Hz
  final _secCtrl = TextEditingController(text: '6'); // 錄製秒數 Y s
  final ScrollController _verticalScrollCtrl = ScrollController();
  bool _isRecording = false;

  SensorKind _chartKind = SensorKind.accelerometer;

  final _chartKey = GlobalKey();       // 用來抓取圖表區域（離屏畫圖不需它，但保留）
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
    _verticalScrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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

  // ======== 數值積分（raw，不扣 bias/不去重力） ========

  // 一次積分：a→v 或 ω→θ（梯形法 + 起始段 t0 校正）
  List<Offset> _integrateOnce(List<Sample> buf, double Function(Sample) pick) {
    final result = <Offset>[];
    if (buf.isEmpty) return result;

    final t0 = buf.first.t;
    final a0 = pick(buf.first);
    final v0 = a0 * t0; // 用第一筆外推回 t=0 的起始段
    double prevVal = a0;
    double prevT = buf.first.t;
    double integ = v0;

    result.add(Offset(buf.first.t, integ));
    for (int i = 1; i < buf.length; i++) {
      final v = pick(buf[i]);
      final t = buf[i].t;
      final dt = (t - prevT);
      // 梯形積分
      integ += 0.5 * (v + prevVal) * dt;
      result.add(Offset(t, integ));
      prevVal = v;
      prevT = t;
    }
    return result;
  }

  // 兩次積分：a→v→x（再做一次梯形法；含起始段近似）
  List<Offset> _integrateTwice(List<Sample> buf, double Function(Sample) pick) {
    if (buf.isEmpty) return <Offset>[];
    final vel = _integrateOnce(buf, pick); // 第一次：a→v

    final result = <Offset>[];
    final t0 = buf.first.t;
    final v0 = vel.first.dy;
    final x0 = 0.5 * v0 * t0; // 起始段近似
    double prevV = vel.first.dy;
    double prevT = vel.first.dx;
    double integ = x0;

    result.add(Offset(vel.first.dx, integ));
    for (int i = 1; i < vel.length; i++) {
      final v = vel[i].dy;
      final t = vel[i].dx;
      final dt = (t - prevT);
      integ += 0.5 * (v + prevV) * dt;
      result.add(Offset(t, integ));
      prevV = v;
      prevT = t;
    }
    return result;
  }

  // ====== 圖像存檔（離屏） ======
  Future<void> _saveChartPngOffscreen() async {
    try {
      if (_buf.isEmpty) { _snack('沒有資料可輸出'); return; }

      final build = _buildOffsetSeriesForKind(_chartKind);
      final ui.Image img = await _renderLinesToImage(
        series: [build.$1, build.$2, build.$3],
        colors: const [_xColor, _yColor, _zColor],
        size: _currentPngSize(),
        bgColor: Theme.of(context).colorScheme.surface,
        xLabel: 't (sec)',
        yLabel: build.$4,
      );

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

    const double leftPad = 80, rightPad = 24, topPad = 24, bottomPad = 60;
    final chartRect = Rect.fromLTWH(
      leftPad, topPad, size.width - leftPad - rightPad, size.height - topPad - bottomPad,
    );

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
    if (minX == maxX) { minX -= 0.5; maxX += 0.5; }
    if (minY == maxY) { minY -= 0.5; maxY += 0.5; }

    final xPad = (maxX - minX) * 0.05;
    final yPad = (maxY - minY) * 0.1;
    minX -= xPad; maxX += xPad;
    minY -= yPad; maxY += yPad;

    double mapX(double x) => chartRect.left +
        (x - minX) / (maxX - minX) * chartRect.width;
    double mapY(double y) => chartRect.bottom -
        (y - minY) / (maxY - minY) * chartRect.height;

    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    const int xTicks = 6, yTicks = 5;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

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

    for (int i = 0; i <= yTicks; i++) {
      final v = minY + (maxY - minY) * (i / yTicks);
      final y = mapY(v);
      canvas.drawLine(Offset(chartRect.left, y), Offset(chartRect.right, y), gridPaint);
      final label = v.toStringAsFixed(2);
      textPainter.text = TextSpan(style: const TextStyle(fontSize: 12, color: Colors.grey), text: label);
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(chartRect.left - textPainter.width - 8, y - textPainter.height / 2),
      );
    }

    final borderPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(chartRect, borderPaint);

    for (int k = 0; k < series.length; k++) {
      final s = series[k];
      if (s.isEmpty) continue;
      final path = Path();
      for (int i = 0; i < s.length; i++) {
        final dx = mapX(s[i].dx);
        final dy = mapY(s[i].dy);
        if (i == 0) path.moveTo(dx, dy);
        else path.lineTo(dx, dy);
      }
      final p = Paint()
        ..color = colors[k]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = true;
      canvas.drawPath(path, p);
    }

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
    SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(p, mimeType: 'image/png', name: p.split('/').last),
        ],
        subject: 'IMU Plot',
        text: 'IMU plot captured from Flutter',
      ),
    );
  }

  // ======== 圖表資料建構 ========
  // 取得 Offset series（給離屏與 on-screen 共用）
  // 回傳：(sx, sy, sz, yLabel)
  (List<Offset>, List<Offset>, List<Offset>, String) _buildOffsetSeriesForKind(
      SensorKind kind) {
    List<Offset> sx = [], sy = [], sz = [];
    String yLabel = '';

    switch (kind) {
      case SensorKind.accelerometer:
        for (final s in _buf) {
          sx.add(Offset(s.t, s.ax));
          sy.add(Offset(s.t, s.ay));
          sz.add(Offset(s.t, s.az));
        }
        yLabel = 'acc (m/s²)';
        break;

      case SensorKind.gyroscope:
        for (final s in _buf) {
          sx.add(Offset(s.t, s.gx));
          sy.add(Offset(s.t, s.gy));
          sz.add(Offset(s.t, s.gz));
        }
        yLabel = 'gyro (rad/s)';
        break;

      case SensorKind.magnetometer:
        for (final s in _buf) {
          sx.add(Offset(s.t, s.mx));
          sy.add(Offset(s.t, s.my));
          sz.add(Offset(s.t, s.mz));
        }
        yLabel = 'mag (µT)';
        break;

      case SensorKind.velocity: {
        // acc → vel（raw，不扣 bias）
        sx = _integrateOnce(_buf, (s) => s.ax);
        sy = _integrateOnce(_buf, (s) => s.ay);
        sz = _integrateOnce(_buf, (s) => s.az);
        yLabel = 'velocity (m/s)';
      } break;

      case SensorKind.displacement: {
        // acc → vel → pos（raw，不扣 bias）
        sx = _integrateTwice(_buf, (s) => s.ax);
        sy = _integrateTwice(_buf, (s) => s.ay);
        sz = _integrateTwice(_buf, (s) => s.az);
        yLabel = 'displacement (m)';
      } break;

      case SensorKind.orientation: {
        // gyro → angle (rad)（raw，不扣 bias）
        sx = _integrateOnce(_buf, (s) => s.gx);
        sy = _integrateOnce(_buf, (s) => s.gy);
        sz = _integrateOnce(_buf, (s) => s.gz);
        yLabel = 'angle (rad)';
      } break;
    }
    return (sx, sy, sz, yLabel);
  }

  // 把三條 Offset series 轉成 fl_chart 的資料
  List<LineChartBarData> _barsFromOffsets(
    List<Offset> sx, List<Offset> sy, List<Offset> sz,
  ) {
    LineChartBarData _l(List<Offset> pts, Color c) => LineChartBarData(
          spots: pts.map((p) => FlSpot(p.dx, p.dy)).toList(),
          isCurved: false,
          dotData: const FlDotData(show: false),
          barWidth: 2,
          color: c,
        );
    return [_l(sx, _xColor), _l(sy, _yColor), _l(sz, _zColor)];
  }

  // ======== 匯出 CSV（含 v-t、x-t、rad） ========
  Future<void> _saveCsv() async {
    if (_buf.isEmpty) {
      _snack('沒有資料可儲存');
      return;
    }

    // 先把三組積分算好（全部 raw，不扣 bias）
    final vX = _integrateOnce(_buf, (s) => s.ax); // m/s
    final vY = _integrateOnce(_buf, (s) => s.ay);
    final vZ = _integrateOnce(_buf, (s) => s.az);

    final pX = _integrateTwice(_buf, (s) => s.ax); // m
    final pY = _integrateTwice(_buf, (s) => s.ay);
    final pZ = _integrateTwice(_buf, (s) => s.az);

    final rX = _integrateOnce(_buf, (s) => s.gx); // rad
    final rY = _integrateOnce(_buf, (s) => s.gy);
    final rZ = _integrateOnce(_buf, (s) => s.gz);

    final dir = await getApplicationDocumentsDirectory();
    final fname = 'imu_${DateTime.now().toIso8601String().replaceAll(":", "-")}.csv';
    final file = File('${dir.path}/$fname');

    final sb = StringBuffer();
    // 標頭：時間 + 原始九軸 + 速度三軸 + 位移三軸 + 角度三軸
    sb.writeln([
      't_sec',
      'acc_x','acc_y','acc_z',
      'gyro_x','gyro_y','gyro_z',
      'mag_x','mag_y','mag_z',
      'vel_x','vel_y','vel_z',      // v-t
      'disp_x','disp_y','disp_z',   // x-t
      'rad_x','rad_y','rad_z',      // angle(rad)
    ].join(','));

    final n = _buf.length;
    for (int i = 0; i < n; i++) {
      final s = _buf[i];

      final vx = vX[i].dy, vy = vY[i].dy, vz = vZ[i].dy;
      final px = pX[i].dy, py = pY[i].dy, pz = pZ[i].dy;
      final rx = rX[i].dy, ry = rY[i].dy, rz = rZ[i].dy;

      sb.writeln([
        s.t.toStringAsFixed(3),
        s.ax.toStringAsFixed(6), s.ay.toStringAsFixed(6), s.az.toStringAsFixed(6),
        s.gx.toStringAsFixed(6), s.gy.toStringAsFixed(6), s.gz.toStringAsFixed(6),
        s.mx.toStringAsFixed(6), s.my.toStringAsFixed(6), s.mz.toStringAsFixed(6),
        vx.toStringAsFixed(6), vy.toStringAsFixed(6), vz.toStringAsFixed(6),
        px.toStringAsFixed(6), py.toStringAsFixed(6), pz.toStringAsFixed(6),
        rx.toStringAsFixed(6), ry.toStringAsFixed(6), rz.toStringAsFixed(6),
      ].join(','));
    }

    await file.writeAsString(sb.toString());
    setState(() { _lastCsvPath = file.path; });
    _snack('CSV 已儲存：$fname');
  }

  void _share() {
    final p = _lastCsvPath;
    if (p == null) { _snack('尚未有錄製檔'); return; }
    SharePlus.instance.share(
      ShareParams(
        files: [XFile(p)],
        text: 'IMU CSV from Flutter',
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final latest = [
      ('ACC (m/s²)', _ax, _ay, _az),
      ('GYRO (rad/s)', _gx, _gy, _gz),
      ('MAG (µT)', _mx, _my, _mz),
    ];

    final built = _buildOffsetSeriesForKind(_chartKind); // for chart & labels

    return Scaffold(
      appBar: AppBar(title: const Text('IMU Recorder')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = constraints.maxWidth;
          return Scrollbar(
            controller: _verticalScrollCtrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _verticalScrollCtrl,
              padding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: viewportWidth,
                  maxWidth: viewportWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ===== 1. 控制列 =====
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
                        ElevatedButton.icon(
                          onPressed: _lastCsvPath == null ? null : _share,
                          icon: const Icon(Icons.share),
                          label: const Text('Share CSV'),
                        ),
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
                      ],
                    ),

                    const SizedBox(height: 8),

                    // ===== 2. 即時數值 =====
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
                        return Chip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [Text('$title  '), v],
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 8),

                    // ===== 3. 圖表選擇器 + 圖例 =====
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('t:'),
                          DropdownButton<SensorKind>(
                            value: _chartKind,
                            items: const [
                              DropdownMenuItem(value: SensorKind.accelerometer, child: Text('Accelerometer (a)')),
                              DropdownMenuItem(value: SensorKind.velocity, child: Text('Velocity (m/s)(∫a dt)')),
                              DropdownMenuItem(value: SensorKind.displacement, child: Text('Displacement(m)(∫∫a dt²)')),
                              DropdownMenuItem(value: SensorKind.gyroscope, child: Text('Gyroscope (ω)')),
                              DropdownMenuItem(value: SensorKind.orientation, child: Text('Angle (rad)(∫ω dt)')),
                              DropdownMenuItem(value: SensorKind.magnetometer, child: Text('Magnetometer (B)')),
                            ],
                            onChanged: (v) => setState(() => _chartKind = v!),
                          ),
                          const _Legend(color: _xColor, text: 'x'),
                          const _Legend(color: _yColor, text: 'y'),
                          const _Legend(color: _zColor, text: 'z'),
                          Text('樣本數：${_buf.length}'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // ===== 4. 折線圖（y 軸動態單位） =====
                    SizedBox(
                      width: viewportWidth,
                      height: 350,
                      child: RepaintBoundary(
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
                                titlesData: FlTitlesData(
                                  rightTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  topTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  bottomTitles: const AxisTitles(
                                    axisNameWidget: const Text('t (sec)'),
                                    axisNameSize: 22,           // ← 軸名區加大
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 44, 
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    axisNameWidget: Text(built.$4), // 動態單位
                                    axisNameSize: 20,
                                    sideTitles: const SideTitles(
                                      showTitles: true,
                                      reservedSize: 44,
                                    ),
                                  ),
                                ),
                                gridData: const FlGridData(drawVerticalLine: true),
                                borderData: FlBorderData(show: true),
                                lineBarsData:
                                    _barsFromOffsets(built.$1, built.$2, built.$3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    if (_lastCsvPath != null) ...[
                      const SizedBox(height: 6),
                      // 讓路徑在可視範圍內橫向捲動，避免 RenderFlex overflow
                      Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text(
                                '已儲存：$_lastCsvPath',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
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

                    // ===== 5. 動作提示卡 =====
                    const _HintCard(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ========= 小元件 =========
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

class _HintCard extends StatelessWidget {
  const _HintCard();
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
            Text('‧ 模擬器：More(…)> Virtual sensors > Move，拖曳 X/Y 滑桿畫出順時針方形路徑。', style: style),
            Text('‧ 實機：手機平放於桌面，沿桌面畫一個順時針方形移動。', style: style),
            const SizedBox(height: 8),
            Text('② 沿 Y 軸逆時針翻轉', style: style?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('‧ 模擬器：More(…)> Device Pose/Rotate，調整對應 Y 軸的旋轉控制，做逆時針翻轉。', style: style),
            Text('‧ 實機：手持手機，沿左右邊緣連線的軸做逆時針旋轉。', style: style),
          ],
        ),
      ),
    );
  }
}
