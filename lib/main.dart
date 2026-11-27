import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const apiKey = String.fromEnvironment('GEMINI_API_KEY');
// Agar model band ho jaye to yahan naya Live model naam daal do
const model = 'gemini-2.5-flash-native-audio-preview-12-2025';
const voiceName = 'Aoede'; // female. Dusri female: Kore, Leda, Zephyr
const systemPrompt =
    'Tum Ayesha ho, user ki ek pyari, samajhdar dost. Bilkul insaan ki tarah baat karo: '
    'natural, halki si hansi, kabhi kabhi "hmm", "achha", "arre wah" jaisa bolo. '
    'User jis zaban mein bole (Hindi/Urdu/Hinglish/English) usi mein jawab do. '
    'Jawab chhote rakho, jaise phone par dost se baat hoti hai. Lecture mat do.';

void main() => runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final rec = AudioRecorder();
  WebSocketChannel? ch;
  StreamSubscription? micSub;
  final q = <int>[];
  bool starved = true;
  bool ready = false;
  bool speaking = false;
  bool reconnecting = false;
  String status = 'Shuru ho rahi hoon...';
  String text = '';

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    await WakelockPlus.enable();
    await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(4800);
    FlutterPcmSound.setFeedCallback(onFeed);
    if (!await rec.hasPermission()) {
      setState(() => status = 'Mic permission do, phir app dobara kholo');
      return;
    }
    await connect();
  }

  void send(Map<String, dynamic> m) {
    try {
      ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<void> connect() async {
    if (!mounted) return;
    setState(() => status = 'Jud rahi hoon...');
    try {
      ch = WebSocketChannel.connect(Uri.parse(
          'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey'));
      await ch!.ready;
      ch!.stream.listen(onMsg, onDone: lost, onError: (_) => lost());
      send({
        'setup': {
          'model': 'models/$model',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'speechConfig': {
              'voiceConfig': {
                'prebuiltVoiceConfig': {'voiceName': voiceName}
              }
            }
          },
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt}
            ]
          },
          'contextWindowCompression': {'slidingWindow': {}},
          'outputAudioTranscription': {},
        }
      });
    } catch (_) {
      lost();
    }
  }

  void lost() {
    ready = false;
    speaking = false;
    q.clear();
    if (!mounted || reconnecting) return;
    reconnecting = true;
    setState(() => status = 'Dobara jud rahi hoon...');
    Future.delayed(const Duration(seconds: 2), () {
      reconnecting = false;
      connect();
    });
  }

  Future<void> startMic() async {
    if (micSub != null) return;
    final s = await rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication),
    ));
    micSub = s.listen((d) {
      if (!ready) return;
      send({
        'realtimeInput': {
          'audio': {
            'data': base64Encode(d),
            'mimeType': 'audio/pcm;rate=16000'
          }
        }
      });
    });
  }

  void onMsg(dynamic raw) {
    final s = raw is String ? raw : utf8.decode(raw as List<int>);
    final m = jsonDecode(s) as Map<String, dynamic>;
    if (m['setupComplete'] != null) {
      ready = true;
      setState(() => status = 'Sun rahi hoon...');
      startMic();
      send({
        'clientContent': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Dost ki tarah chhota sa hello bolo aur apna naam batao.'}
              ]
            }
          ],
          'turnComplete': true
        }
      });
      return;
    }
    final sc = m['serverContent'];
    if (sc == null) return;
    if (sc['interrupted'] == true) {
      q.clear();
      setState(() {
        speaking = false;
        status = 'Sun rahi hoon...';
      });
    }
    final parts = sc['modelTurn']?['parts'];
    if (parts != null) {
      for (final p in parts) {
        final inline = p['inlineData'];
        if (inline != null) enqueue(base64Decode(inline['data']));
      }
    }
    final t = sc['outputTranscription']?['text'];
    if (t != null) setState(() => text += t);
    if (sc['turnComplete'] == true) {
      setState(() {
        speaking = false;
        status = 'Sun rahi hoon...';
      });
    }
  }

  void enqueue(Uint8List bytes) {
    if (!speaking) {
      setState(() {
        speaking = true;
        status = 'Bol rahi hoon...';
        text = '';
      });
    }
    q.addAll(bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2));
    if (starved) {
      starved = false;
      onFeed(0);
      FlutterPcmSound.start();
    }
  }

  void onFeed(int remaining) {
    if (q.isEmpty) {
      starved = true;
      return;
    }
    final n = min(q.length, 2400);
    FlutterPcmSound.feed(PcmArrayInt16.fromList(q.sublist(0, n)));
    q.removeRange(0, n);
  }

  @override
  void dispose() {
    micSub?.cancel();
    rec.dispose();
    ch?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orb = speaking ? Colors.pinkAccent : (ready ? Colors.greenAccent : Colors.amber);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: speaking ? 170 : 140,
                height: speaking ? 170 : 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: orb.withOpacity(0.25),
                  border: Border.all(color: orb, width: 4),
                  boxShadow: [BoxShadow(color: orb.withOpacity(0.5), blurRadius: 40)],
                ),
              ),
              const SizedBox(height: 32),
              Text(status, style: const TextStyle(color: Colors.white70, fontSize: 18)),
              const SizedBox(height: 16),
              Text(text,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }
}
