import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: SensorPage(),
    );
  }
}

class SensorPage extends StatefulWidget {
  const SensorPage({super.key});

  @override
  State<SensorPage> createState() => _SensorPageState();
}

class _SensorPageState extends State<SensorPage> {
  String _accelerometerValues = '';
  String _gyroscopeValues = '';
  String _magnetometerValues = '';

  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  @override
  void initState() {
    super.initState();

    // Accelerometer
    _accSub = SensorsPlatform.instance.accelerometerEventStream().listen((e) {
      if (!mounted) return;
      setState(() {
        _accelerometerValues =
            'ACC  x: ${e.x.toStringAsFixed(2)}, y: ${e.y.toStringAsFixed(2)}, z: ${e.z.toStringAsFixed(2)}  (m/s²)';
      });
    });

    // Gyroscope
    _gyroSub = SensorsPlatform.instance.gyroscopeEventStream().listen((g) {
      if (!mounted) return;
      setState(() {
        _gyroscopeValues =
            'GYRO x: ${g.x.toStringAsFixed(2)}, y: ${g.y.toStringAsFixed(2)}, z: ${g.z.toStringAsFixed(2)}  (rad/s)';
      });
    });

    // Magnetometer
    _magSub = SensorsPlatform.instance.magnetometerEventStream().listen((m) {
      if (!mounted) return;
      setState(() {
        _magnetometerValues =
            'MAG  x: ${m.x.toStringAsFixed(2)}, y: ${m.y.toStringAsFixed(2)}, z: ${m.z.toStringAsFixed(2)}  (µT)';
      });
    });
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 22, color: Colors.white),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_accelerometerValues.isEmpty ? 'ACC ...' : _accelerometerValues),
              const SizedBox(height: 16),
              Text(_gyroscopeValues.isEmpty ? 'GYRO ...' : _gyroscopeValues),
              const SizedBox(height: 16),
              Text(_magnetometerValues.isEmpty ? 'MAG ...' : _magnetometerValues),
            ],
          ),
        ),
      ),
    );
  }
}
