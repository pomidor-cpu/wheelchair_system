import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

const String GOOGLE_API_KEY = "AIzaSyDW72D4cyrl7xYDCyrmuh5sYbM6RWD";

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HC-05 + Map + Compass',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  //Bluetooth
  final FlutterBluetoothSerial _bt = FlutterBluetoothSerial.instance;
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isConnecting = false;
  StreamSubscription<BluetoothState>? _btStateSub;
  final String targetAddress = "00:24:06:31:60:6A";

  //Map and GPS
  final Completer<GoogleMapController> _mapController = Completer();
  Position? _currentPosition;
  LatLng? _destination;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  List<LatLng> currentRoutePoints = [];

  //Compass
  double? _heading;
  final double _arrowLength = 0.00015;
  StreamSubscription<CompassEvent>? _compassSub;

  // speect to text
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  bool _isListeningAddress = false;
  String _lastHeardAddress = "";
  String _currentLocaleId = ""; // ID russian language

  //Misc
  final List<String> logs = [];
  int _selectedIndex = 0;
  Timer? _reconnectTimer;
  int _retryCount = 0;

  // index of first point in route
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
    _determinePosition();
    _startCompassStream();
    _initSpeechToText(); // voice input initialization
  }

  @override
  void dispose() {
    _btStateSub?.cancel();
    _connection?.dispose();
    _reconnectTimer?.cancel();
    _compassSub?.cancel();
    _speech.cancel(); // stop STT
    super.dispose();
  }

  // COMPASS
  void _startCompassStream() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((event) {
      if (event.heading != null) {
        setState(() {
          _heading = event.heading;
        });
        _updateCompassLine();
      }
    });
  }

  void _updateCompassLine() {
    if (_currentPosition == null || _heading == null) return;
    double bearingRad = (_heading! * pi) / 180.0;
    double lat = _currentPosition!.latitude;
    double lng = _currentPosition!.longitude;
    double newLat = lat + _arrowLength * cos(bearingRad);
    double newLng = lng + _arrowLength * sin(bearingRad);
    _polylines.removeWhere((p) => p.polylineId.value == 'heading');
    _polylines.add(Polyline(
      polylineId: const PolylineId('heading'),
      color: Colors.red,
      width: 3,
      points: [LatLng(lat, lng), LatLng(newLat, newLng)],
    ));
  }

  // Bluetooth
  Future<void> _initBluetooth() async {
    await _requestPermissions();
    _btStateSub = _bt.onStateChanged().listen((state) {
      if (state == BluetoothState.STATE_ON) {
        _autoConnect();
      } else {
        _disconnect();
      }
    });
    BluetoothState state = await _bt.state;
    if (state == BluetoothState.STATE_ON) {
      _autoConnect();
    } else {
      try {
        await _bt.requestEnable();
      } catch (e) {
        _addLog("System: Bluetooth enable failed: $e");
      }
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
      Permission.location,
      Permission.microphone, // for voice input
    ].request();
  }

  Future<void> _autoConnect() async {
    if (_isConnected || _isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      List<BluetoothDevice> bonded = await _bt.getBondedDevices();
      BluetoothDevice? target =
          bonded.firstWhereOrNull((d) => d.address == targetAddress);
      if (target != null) {
        await _connectTo(target);
      } else {
        _addLog("System: HC-05 not found. Pair it first.");
      }
    } catch (e) {
      _addLog("AutoConnect error: $e");
      _scheduleReconnect();
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    try {
      _addLog("System: Connecting to ${device.address} ...");
      BluetoothConnection conn =
          await BluetoothConnection.toAddress(device.address);
      _connection = conn;
      setState(() => _isConnected = true);
      _retryCount = 0;
      _addLog("System: Connected to ${device.name ?? device.address}");
      conn.input?.listen((Uint8List data) {
        String msg = ascii.decode(data);

        // split incoming data into strings
        List<String> lines = msg.split('\n');
        for (String line in lines) {
          line = line.trim();
          if (line.isNotEmpty) {
            _addLog("In parsed: $line");
            _onBluetoothData(line);
          }
        }
      }).onDone(() {
        _addLog("System: Disconnected");
        _handleDisconnect();
      });
    } catch (e) {
      _addLog("Connection failed: $e");
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _connection?.dispose();
    _connection = null;
    setState(() => _isConnected = false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _retryCount++;
    int delay = (_retryCount * 3).clamp(3, 30);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), _autoConnect);
    _addLog("System: Reconnecting in $delay s...");
  }

  void _disconnect() {
    _connection?.close();
    setState(() => _isConnected = false);
    _addLog("System: Connection closed");
  }

  Future<void> _send(String data) async {
    _addLog("Out: $data");
    if (_connection == null || !_isConnected) {
      _addLog("System: Not connected");
      return;
    }
    try {
      _connection!.output.add(ascii.encode(data + "\r\n"));
      await _connection!.output.allSent;
    } catch (e) {
      _addLog("Send error: $e");
    }
  }

  void _addLog(String s) {
    debugPrint("APP_LOG: $s");
    if (logs.length > 300) logs.removeAt(0);
    logs.add("${DateTime.now().toIso8601String().substring(11, 19)} $s");
    if (mounted) setState(() {});
  }

  //GPS and Map
  static const CameraPosition _kKaraganda =
      CameraPosition(target: LatLng(49.80, 73.10), zoom: 12);

  Future<void> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _currentPosition = position;
      _markers.removeWhere((m) => m.markerId.value == 'currentPosition');
      _markers.add(Marker(
          markerId: const MarkerId('currentPosition'),
          position: LatLng(position.latitude, position.longitude),
          infoWindow: const InfoWindow(title: 'My location')));
      _updateCompassLine();
      _goToCurrentLocation();
    } catch (_) {}
  }

  Future<void> _goToCurrentLocation() async {
    if (_currentPosition != null) {
      final GoogleMapController controller = await _mapController.future;
      await controller.animateCamera(CameraUpdate.newCameraPosition(
          CameraPosition(
              target: LatLng(
                  _currentPosition!.latitude, _currentPosition!.longitude),
              zoom: 15)));
    }
  }

  void _onMapTapped(LatLng pos) {
    if (_currentPosition == null) return;
    setState(() {
      _destination = pos;
      _markers.removeWhere((m) => m.markerId.value == 'destination');
      _markers.add(Marker(
          markerId: const MarkerId('destination'),
          position: pos,
          infoWindow: const InfoWindow(title: 'Назначение')));
    });
    _getRoute();
  }

  //Route 
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      poly.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return poly;
  }

  Future<void> _getRoute() async {
    if (_currentPosition == null || _destination == null) return;
    final String url =
        'https://routes.googleapis.com/directions/v2:computeRoutes';
    final requestBody = jsonEncode({
      "origin": {
        "location": {
          "latLng": {
            "latitude": _currentPosition!.latitude,
            "longitude": _currentPosition!.longitude
          }
        }
      },
      "destination": {
        "location": {
          "latLng": {
            "latitude": _destination!.latitude,
            "longitude": _destination!.longitude
          }
        }
      },
      "travelMode": "DRIVE",
    });
    try {
      final response = await http.post(Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': GOOGLE_API_KEY,
            'X-Goog-FieldMask': 'routes.polyline.encodedPolyline',
          },
          body: requestBody);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final encodedPolyline =
            data['routes'][0]['polyline']['encodedPolyline'];
        List<LatLng> polyPoints = _decodePolyline(encodedPolyline);
        if (polyPoints.isNotEmpty) {
          setState(() {
            currentRoutePoints = polyPoints;
            _currentIndex = 0;
            _polylines.removeWhere((p) => p.polylineId.value == 'route');
            _polylines.add(Polyline(
                polylineId: const PolylineId('route'),
                color: Colors.blue,
                points: polyPoints,
                width: 5));
          });

          _startRoute();
        }
      }
    } catch (_) {}
  }

  Future<void> sendRouteAllPoints() async {
    if (!_isConnected || currentRoutePoints.isEmpty) return;
    for (int i = 0; i < currentRoutePoints.length; i++) {
      LatLng p = currentRoutePoints[i];
      String msg = "WP;$i;${p.latitude};${p.longitude}";
      await _send(msg);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  //Main route iteration 

  void _startRoute() {
    if (currentRoutePoints.isEmpty) return;

    if (_currentPosition == null) {
      _addLog("ERR: current position unknown for start");
      return;
    }

    _currentIndex = 0;
    final LatLng targetP = currentRoutePoints[_currentIndex];
    _addLog(
        "🚀 Маршрут запущен. Точка 0: ${targetP.latitude}, ${targetP.longitude}");

    final LatLng startP =
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    _sendMovementCommands(
      startP.latitude,
      startP.longitude,
      targetP.latitude,
      targetP.longitude,
    );
  }

  void _goToNextWaypoint() {
    if (currentRoutePoints.isEmpty) return;

    if (_currentIndex >= currentRoutePoints.length - 1) {
      _addLog("🏁 Маршрут завершён");
      return;
    }

    final LatLng startP = currentRoutePoints[_currentIndex];

    _currentIndex++;

    final LatLng targetP = currentRoutePoints[_currentIndex];

    _addLog(
        "➡ Moving to point №$_currentIndex (${targetP.latitude}, ${targetP.longitude})");

    _sendMovementCommands(
      startP.latitude,
      startP.longitude,
      targetP.latitude,
      targetP.longitude,
    );
  }

  void _sendMovementCommands(
    double startLat,
    double startLon,
    double targetLat,
    double targetLon,
  ) {
    if (_currentPosition == null) {
      _addLog("ERR: current position unknown");
      return;
    }

    final double currentLat = _currentPosition!.latitude;
    final double currentLon = _currentPosition!.longitude;

    final double targetBearing =
        _calculateBearing(currentLat, currentLon, targetLat, targetLon);

    final double distance =
        _calculateDistance(startLat, startLon, targetLat, targetLon) / 60.0;

    double heading = _heading ?? 0.0;
    double diff = targetBearing - heading;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;

    _addLog("OUT -> BEARING:${targetBearing.toStringAsFixed(2)}");
    _addLog("OUT -> DIFF:${diff.toStringAsFixed(2)}");
    _addLog("OUT -> DIST:${distance.toStringAsFixed(3)}");

    _send("BEARING:${targetBearing.toStringAsFixed(2)}");
    _send("DIFF:${diff.toStringAsFixed(2)}");
    Future.delayed(const Duration(milliseconds: 200), () {
      _send("DIST:${distance.toStringAsFixed(3)}");
    });
  }

  //Calculation formulas
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371000.0;
    final double phi1 = lat1 * pi / 180.0;
    final double phi2 = lat2 * pi / 180.0;
    final double dPhi = (lat2 - lat1) * pi / 180.0;
    final double dLambda = (lon2 - lon1) * pi / 180.0;

    final double a = pow(sin(dPhi / 2), 2) +
        cos(phi1) * cos(phi2) * pow(sin(dLambda / 2), 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final double phi1 = lat1 * pi / 180.0;
    final double phi2 = lat2 * pi / 180.0;
    final double dLambda = (lon2 - lon1) * pi / 180.0;

    final double y = sin(dLambda) * cos(phi2);
    final double x =
        cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda);

    double theta = atan2(y, x) * 180.0 / pi;
    if (theta < 0) theta += 360.0;
    return theta;
  }

  // Processing incoming Bluetooth commands
  void _onBluetoothData(String data) {
    data = data.trim();

    if (data == "N") {
      _addLog("In: NEXT received");

      Future.delayed(const Duration(seconds: 4), () {
        _goToNextWaypoint();
      });
    }
  }

  //SPEECH TO TEXT init and listen
  
  Future<void> _initSpeechToText() async {
    try {
      bool available = await _speech.initialize(
        onStatus: (status) => _addLog('STT Status: $status'),
        onError: (errorNotification) => _addLog('STT Error: $errorNotification'),
      );

      if (available) {
        // searching for russian locale
        var locales = await _speech.locales();
        var ruLocale = locales.firstWhereOrNull((l) => l.localeId.toLowerCase().startsWith('ru'));

        if (ruLocale != null) {
          _currentLocaleId = ruLocale.localeId;
          _addLog("STT: language local is found $_currentLocaleId");
        } else {
          _addLog("STT: Русский язык не найден, будет использован язык по умолчанию");
        }

        setState(() {
          _speechEnabled = true;
        });
      } else {
        _addLog("STT: Голосовой ввод недоступен");
        setState(() {
          _speechEnabled = false;
        });
      }
    } catch (e) {
      _addLog("STT Init Exception: $e");
    }
  }

  void _startListeningAddress() async {
    if (!_speechEnabled) {
      _addLog("STT не готов");
      return;
    }
    
    setState(() {
      _lastHeardAddress = "";
      _isListeningAddress = true;
    });

    await _speech.listen(
      localeId: _currentLocaleId.isNotEmpty ? _currentLocaleId : 'ru_RU',
      onResult: _onSpeechResult,
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
    );
  }

  void _stopListeningAddress() async {
    await _speech.stop();
    setState(() => _isListeningAddress = false);
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _lastHeardAddress = result.recognizedWords;
    });

    if (result.finalResult) {
      _addLog("STT Final: $_lastHeardAddress");
      _stopListeningAddress();
      _onVoiceAddressRecognized(_lastHeardAddress);
    }
  }

  // Voice into Geocode
  Future<void> _onVoiceAddressRecognized(String address) async {
    address = address.trim();
    if (address.isEmpty) {
      _addLog("Voice: пустой адрес");
      return;
    }

    _addLog("Voice: распознан адрес '$address'");

    final LatLng? dest = await _geocodeAddress(address);
    if (dest == null) {
      _addLog("Voice: не удалось найти координаты");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Адрес не найден на карте")),
        );
      }
      return;
    }

    setState(() {
      _destination = dest;
      _markers.removeWhere((m) => m.markerId.value == 'destination');
      _markers.add(Marker(
        markerId: const MarkerId('destination'),
        position: dest,
        infoWindow: InfoWindow(title: address),
      ));
    });

    await _getRoute();

    try {
      final controller = await _mapController.future;
      await controller.animateCamera(CameraUpdate.newLatLng(dest));
    } catch (_) {}
  }

  Future<LatLng?> _geocodeAddress(String address) async {
    final encodedAddress = Uri.encodeComponent(address);
    final url =
        "https://maps.googleapis.com/maps/api/geocode/json?address=$encodedAddress&key=$GOOGLE_API_KEY&language=ru";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        _addLog("Geocode HTTP error: ${response.statusCode}");
        return null;
      }

      final Map<String, dynamic> data = jsonDecode(response.body);
      final status = data['status'] as String? ?? 'UNKNOWN';

      if (status != 'OK') {
        _addLog("Geocode status: $status, error: ${data['error_message'] ?? ''}");
        return null;
      }

      final results = data['results'] as List<dynamic>;
      if (results.isEmpty) {
        _addLog("Geocode: нет результатов");
        return null;
      }

      final first = results[0] as Map<String, dynamic>;
      final geometry = first['geometry'] as Map<String, dynamic>;
      final location = geometry['location'] as Map<String, dynamic>;

      final double lat = (location['lat'] as num).toDouble();
      final double lng = (location['lng'] as num).toDouble();

      return LatLng(lat, lng);
    } catch (e) {
      _addLog("Geocode exception: $e");
      return null;
    }
  }

  // Motor control
  Widget buildControlTab() {
    Widget holdButton(
        String label, IconData icon, String command, Color color) {
      return GestureDetector(
        onTapDown: (_) {
          if (_isConnected) _send(command);
        },
        onTapUp: (_) {
          if (_isConnected) _send("STOP");
        },
        onTapCancel: () {
          if (_isConnected) _send("STOP");
        },
        child: Container(
          height: 70,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: _isConnected ? color : Colors.grey,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 6,
                offset: const Offset(2, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isConnected ? "✅ Connected HC-05" : "❌ Not connected",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              color: _isConnected ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 40),
          holdButton("Left wheel forward", Icons.arrow_upward,
              "LEFT_FORWARD", Colors.blue),
          holdButton("Right wheel forward", Icons.arrow_upward,
              "RIGHT_FORWARD", Colors.indigo),
          holdButton("Both wheels forward", Icons.double_arrow, "BOTH_FORWARD",
              Colors.teal),
          const SizedBox(height: 60),
          const Text(
            "Hold the button to move.\nRelease the button to stop.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  // UI
  void _onNavTapped(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildBluetoothTab(),
      _buildMapTab(),
      buildControlTab(),
      const AiScreen(),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text("HC-05 + Map + Compass")),
      body: pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onNavTapped,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.bluetooth), label: "Bluetooth"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings_remote), label: "Control"),
          BottomNavigationBarItem(
              icon: Icon(Icons.camera_alt), label: "Camera"),
        ],
      ),
    );
  }

  Widget _buildBluetoothTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        ListTile(
          title: Text(_isConnected
              ? "Status: connected"
              : _isConnecting
                  ? "Status: connecting..."
                  : "Status: not connected"),
          subtitle: Text("MAC: $targetAddress"),
          trailing: Icon(
            _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _isConnected ? Colors.blue : Colors.grey,
          ),
        ),
        Wrap(spacing: 10, children: [
          ElevatedButton(
              onPressed: _autoConnect,
              child: const Text("Reconnect")),
          ElevatedButton(
              onPressed: currentRoutePoints.isNotEmpty
                  ? () async {
                      await sendRouteAllPoints();
                      _startRoute();
                    }
                  : null,
              child: const Text("Send Route")),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Current compass heading: ${_heading?.toStringAsFixed(1) ?? "--"}°",
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Transform.rotate(
                angle: ((_heading ?? 0) * (pi / 180)),
                child: const Icon(Icons.navigation,
                    color: Colors.blue, size: 30),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
            child: ListView.builder(
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (_, idx) {
                final i = logs.length - 1 - idx;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  child: Text(logs[i],
                      style: const TextStyle(fontSize: 12)),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildMapTab() {
    return Stack(children: [
      Positioned.fill(
        child: GoogleMap(
          mapType: MapType.normal,
          initialCameraPosition: _kKaraganda,
          onMapCreated: (controller) {
            if (!_mapController.isCompleted) {
              _mapController.complete(controller);
            }
          },
          markers: _markers,
          polylines: _polylines,
          onTap: _onMapTapped,
        ),
      ),
      Positioned(
        bottom: 16,
        left: 12,
        right: 12,
        child: Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _goToCurrentLocation,
              icon: const Icon(Icons.my_location),
              label: const Text("My location"),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed:
                currentRoutePoints.isNotEmpty ? sendRouteAllPoints : null,
            child: const Text("Send Route"),
          ),
        ]),
      ),
      Positioned(
        bottom: 90,
        right: 16,
        child: FloatingActionButton(
          backgroundColor: _isListeningAddress ? Colors.red : Colors.blue,
          onPressed: _isListeningAddress
              ? _stopListeningAddress
              : _startListeningAddress,
          child: Icon(
            _isListeningAddress ? Icons.mic_off : Icons.mic,
          ),
          tooltip: _speechEnabled
              ? "Голосовой ввод адреса"
              : "STT ещё не готов",
        ),
      ),
      if (_lastHeardAddress.isNotEmpty)
        Positioned(
          top: 16,
          left: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              "Голос: $_lastHeardAddress",
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
    ]);
  }
}

// camera screen AI
class AiScreen extends StatefulWidget {
  const AiScreen({super.key});

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final FlutterTts tts = FlutterTts();
  Timer? timer;
  String lastText = "";
  String statusMessage = "Подключение...";
  bool isSpeaking = false;

  final String espUrl = "http://10.61.222.212/last";

  @override
  void initState() {
    super.initState();
    initTts();
      timer = Timer.periodic(const Duration(seconds: 5), (_) {
      fetchDescription();
    });
    fetchDescription();
  }

  @override
  void dispose() {
    timer?.cancel();
    tts.stop();
    super.dispose();
  }

  Future<void> initTts() async {
    await tts.setLanguage("ru-RU");
    await tts.setSpeechRate(0.5);
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);

    tts.setCompletionHandler(() {
      setState(() {
        isSpeaking = false;
      });
    });
  }

  Future<void> fetchDescription() async {
    if (isSpeaking) {
      debugPrint("TTS все еще говорит, пропуск запроса...");
      return;
    }

    try {
      setState(() {
        statusMessage = "Запрос данных...";
      });

      final response =
          await http.get(Uri.parse(espUrl)).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final String text = utf8.decode(response.bodyBytes).trim();

        debugPrint("HTTP OK: Получен текст: '$text'");

        if (text == "NO_DATA_YET") {
          setState(() {
            statusMessage = "Ожидание ответа от AI...";
          });
          return;
        }

        if (text.isNotEmpty && text != lastText) {
          debugPrint("Новое сообщение! Озвучиваю...");
          setState(() {
            lastText = text;
            statusMessage = "Получен новый ответ!";
            isSpeaking = true;
          });

          await tts.speak(text);
        } else if (text == lastText) {
          setState(() {
            statusMessage = "No data yet...";
          });
        }
      } else {
        debugPrint("Error HTTP: Status ${response.statusCode}");
        setState(() {
          statusMessage = "Server error: ${response.statusCode}";
        });
      }
    } catch (e) {
      debugPrint("Ошибка HTTP: $e");
      setState(() {
        statusMessage = "Connecting error (проверь IP)";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF121212),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey[800],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Status: $statusMessage",
                style: const TextStyle(fontSize: 16, color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "Last message from AI:",
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F1F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    lastText.isEmpty ? "Ожидание данных..." : lastText,
                    style: const TextStyle(
                        fontSize: 18, height: 1.5, color: Colors.white),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                if (lastText.isNotEmpty) {
                  tts.speak(lastText);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey[700],
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text(
                "Repeat the voice message",
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}