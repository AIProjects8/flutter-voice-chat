import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http_parser/http_parser.dart';
import 'dart:typed_data';

// Set up logging
final _log = Logger('VoiceRecorderScreen');

Future<void> main() async {
  // Basic logging setup
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Use print directly for the logger's output to avoid stream conflicts
    print(
        '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
  });

  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();
  // Load environment variables from .env file
  await dotenv.load(fileName: ".env");
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Voice Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const VoiceRecorderScreen(),
    );
  }
}

class VoiceRecorderScreen extends StatefulWidget {
  const VoiceRecorderScreen({super.key});

  @override
  State<VoiceRecorderScreen> createState() => _VoiceRecorderScreenState();
}

class _VoiceRecorderScreenState extends State<VoiceRecorderScreen> {
  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _transcribedText = '';

  @override
  void initState() {
    super.initState();
    _initializeAudio();
    _checkPermission();
  }

  Future<void> _initializeAudio() async {
    try {
      _log.info('Initializing audio recorder...');
      // Dispose existing instance
      await _audioRecorder.dispose();
      await Future.delayed(
          const Duration(milliseconds: 100)); // Brief delay for cleanup
      // Check if recording is supported on this device
      final isSupported = await _audioRecorder.hasPermission();
      _log.info('Audio recording supported: $isSupported');
      if (!isSupported) {
        throw Exception('Audio recording is not supported on this device');
      }
    } catch (e) {
      _log.severe('Error initializing audio recorder: $e');
    }
  }

  Future<bool> _arePermissionsGranted() async {
    if (kIsWeb) {
      // On web, we only need to check if recording is supported
      return await _audioRecorder.hasPermission();
    }

    // On mobile platforms, check both permissions
    final micStatus = await Permission.microphone.status;
    final speechStatus = await Permission.speech.status;
    return micStatus.isGranted && speechStatus.isGranted;
  }

  Future<void> _checkPermission() async {
    _log.info('Checking permissions...');

    if (kIsWeb) {
      final hasPermission = await _audioRecorder.hasPermission();
      _log.info('Web audio permission status: $hasPermission');

      if (!hasPermission) {
        setState(() {
          _transcribedText = 'Microphone permission is required for recording.';
        });
      }
      return;
    }

    // For mobile platforms, continue with the existing permission check
    if (await _arePermissionsGranted()) {
      _log.info('All required permissions already granted');
      return;
    }

    // Request both microphone and speech recognition permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      Permission.speech,
    ].request();

    if (statuses[Permission.microphone] != PermissionStatus.granted ||
        statuses[Permission.speech] != PermissionStatus.granted) {
      _log.severe('Required permissions not granted. Statuses: $statuses');

      List<String> deniedPermissions = [];
      if (statuses[Permission.microphone] != PermissionStatus.granted) {
        deniedPermissions.add('Microphone');
      }
      if (statuses[Permission.speech] != PermissionStatus.granted) {
        deniedPermissions.add('Speech Recognition');
      }

      String errorMessage =
          '${deniedPermissions.join(" and ")} permission${deniedPermissions.length > 1 ? "s are" : " is"} required.';

      bool isPermanentlyDenied =
          statuses[Permission.microphone]?.isPermanentlyDenied == true ||
              statuses[Permission.speech]?.isPermanentlyDenied == true;

      if (isPermanentlyDenied) {
        errorMessage +=
            '\n\nThese permissions have been permanently denied. Please enable them in Settings.';
        await openAppSettings();
      }

      setState(() {
        _transcribedText = errorMessage.trim();
      });
    } else {
      _log.info('All required permissions granted');
    }
  }

  Future<void> _startRecording() async {
    try {
      final hasPermission = kIsWeb
          ? await _audioRecorder.hasPermission()
          : await _arePermissionsGranted();

      if (!hasPermission) {
        _log.warning('Permissions not granted, requesting permissions...');
        await _checkPermission();
        if (!(kIsWeb
            ? await _audioRecorder.hasPermission()
            : await _arePermissionsGranted())) {
          return; // Don't proceed if permissions weren't granted
        }
      }

      _log.info('Starting recording...');

      // Configure recording with web-compatible settings
      final config = RecordConfig(
        encoder: AudioEncoder.wav, // WAV works better for web
        bitRate: 128000,
        sampleRate: 44100,
        numChannels: 1,
      );

      if (kIsWeb) {
        await _audioRecorder.start(config,
            path: 'recording.wav'); // Provide a dummy path for web
      } else {
        final tempDir = await getTemporaryDirectory();
        final filePath =
            '${tempDir.path}/recording.wav'; // Use WAV for consistency
        await _audioRecorder.start(config, path: filePath);
      }

      setState(() {
        _isRecording = true;
        _transcribedText = 'Recording...';
      });
    } catch (e, stackTrace) {
      _log.severe('Error starting recording', e, stackTrace);
      setState(() {
        _transcribedText =
            'Failed to start recording: ${e is Exception ? e.toString() : "Unknown error occurred"}';
      });
    }
  }

  Future<void> _stopRecordingAndTranscribe() async {
    try {
      _log.info('Stopping recording...');

      if (!_isRecording) {
        _log.warning('Attempted to stop recording when not recording');
        return;
      }

      setState(() {
        _isRecording = false;
        _transcribedText = 'Processing...';
      });

      if (kIsWeb) {
        // For web, we'll handle the audio data directly in _transcribeAudio
        await _transcribeAudio(null);
      } else {
        final path = await _audioRecorder.stop();
        _log.info('Recording stopped. Path: $path');

        if (path != null) {
          await _transcribeAudio(path);
        } else {
          throw Exception('Recording failed: no audio data available');
        }
      }
    } catch (e, stackTrace) {
      _log.severe('Error stopping recording: $e', e, stackTrace);
      setState(() {
        _transcribedText = 'Error stopping recording: ${e.toString()}';
      });
    }
  }

  Future<void> _transcribeAudio(String? path) async {
    try {
      final apiKey = dotenv.env['OPENAI_API_KEY'];
      if (apiKey == null) {
        setState(() {
          _transcribedText = 'Error: OPENAI_API_KEY not set in .env file.';
        });
        return;
      }

      var url = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
      var request = http.MultipartRequest('POST', url);
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.fields['model'] = 'whisper-1';

      if (kIsWeb) {
        _log.info('Processing web audio data...');

        // For web, get the recorded data
        final dynamic result = await _audioRecorder.stop();
        if (result == null) {
          throw Exception('No audio data available');
        }

        // Convert the audio data to bytes
        late final List<int> audioBytes;
        if (result is List<int>) {
          audioBytes = result;
        } else if (result is Uint8List) {
          audioBytes = result.toList();
        } else if (result is String) {
          if (result.startsWith('blob:')) {
            // Handle blob URL
            try {
              final response = await http.get(Uri.parse(result));
              if (response.statusCode == 200) {
                audioBytes = response.bodyBytes;
              } else {
                throw Exception(
                    'Failed to fetch audio data from blob URL: ${response.statusCode}');
              }
            } catch (e) {
              throw Exception('Failed to process blob URL: $e');
            }
          } else if (result.isNotEmpty) {
            try {
              // Try base64 decoding only for non-blob strings
              audioBytes = base64.decode(result);
            } catch (e) {
              _log.warning(
                  'Failed direct base64 decode, trying with padding: $e');
              // If that fails, try adding padding
              final padded = result.padRight((result.length + 3) & ~3, '=');
              try {
                audioBytes = base64.decode(padded);
              } catch (e) {
                throw Exception(
                    'Failed to decode audio data after padding: $e');
              }
            }
          } else {
            throw Exception('Empty audio data string received');
          }
        } else {
          throw Exception('Unexpected audio format: ${result.runtimeType}');
        }

        _log.info('Audio data size: ${audioBytes.length} bytes');

        // Add the audio file to the request
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            audioBytes,
            filename: 'audio.wav',
            contentType: MediaType('audio', 'wav'),
          ),
        );
      } else {
        _log.info('Processing mobile audio file...');
        final audioFile = File(path!);
        final audioStream = await audioFile.readAsBytes();
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            audioStream,
            filename: 'audio.wav', // Use WAV for consistency
            contentType: MediaType('audio', 'wav'),
          ),
        );
      }

      _log.info('Sending transcription request to OpenAI...');
      var response = await request.send();
      var responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        var decodedResponse = jsonDecode(responseBody);
        setState(() {
          _transcribedText = decodedResponse['text'];
        });
      } else {
        _log.severe('Error from OpenAI: ${response.statusCode}');
        _log.severe('Response body: $responseBody');
        setState(() {
          _transcribedText = 'Error transcribing audio: ${response.statusCode}';
        });
      }
    } catch (e, stackTrace) {
      _log.severe('Error sending request: $e', e, stackTrace);
      setState(() {
        _transcribedText = 'Error: Could not connect to OpenAI API.';
      });
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Transcription'),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _transcribedText.isEmpty
                    ? 'Press and hold the button to record'
                    : _transcribedText,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18.0),
              ),
            ),
            const SizedBox(height: 30),
            GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressEnd: (_) => _stopRecordingAndTranscribe(),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _isRecording ? Colors.red : Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isRecording ? Icons.stop : Icons.mic,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
