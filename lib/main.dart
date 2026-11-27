import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';

const apiKey = String.fromEnvironment('GEMINI_API_KEY');
const model = 'gemini-2.5-flash';
const systemPrompt =
    'Tum ek ladki ho, naam "Ayesha". Tum user ki dost ki tarah insaan jaisi baat karti ho. '
    'User jis zaban mein bole (Hindi/Urdu/Hinglish/English) usi mein jawab do. '
    'Jawab chhota rakho (1-3 chhote vaakya), natural bolo, bilkul real insaan ki tarah. '
    'Koi markdown, star, emoji ya list mat use karo kyunki jawab awaaz mein bola jayega.';

void main() => runApp(const MaterialApp(
    debugShowCheckedModeBanner: false, home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final stt = SpeechToText();
  final tts = FlutterTts();
  final history = <Map<String, dynamic>>[];
  String status = 'Shuru ho rahi hoon...';
  String text = '';
  bool busy = false;
  Color orb = Colors.blueGrey;

  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    await tts.setLanguage('hi-IN');
    await tts.setSpeechRate(0.5);
    await tts.setPitch(1.1);
    try {
      final voices = await tts.getVoices as List;
      final f = voices.firstWhere(
          (v) => v['locale'].toString().toLowerCase().startsWith('hi') &&
              v['name'].toString().toLowerCase().contains('female'),
          orElse: () => null);
      if (f != null) {
        await tts.setVoice({'name': f['name'], 'locale': f['locale']});
      }
    } catch (_) {}
    tts.setCompletionHandler(() {
      busy = false;
      listen();
    });
    final ok = await stt.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && !busy) {
          Future.delayed(const Duration(milliseconds: 400), listen);
        }
      },
      onError: (e) {
        if (!busy) Future.delayed(const Duration(seconds: 1), listen);
      },
    );
    if (!ok) {
      setState(() => status = 'Mic permission do aur app dobara kholo');
      return;
    }
    await speak('Hello! Main Ayesha hoon. Boliye, main sun rahi hoon.');
  }

  Future<void> listen() async {
    if (busy || !mounted || stt.isListening) return;
    setState(() {
      status = 'Sun rahi hoon...';
      orb = Colors.greenAccent;
    });
    await stt.listen(
      localeId: 'hi_IN',
      listenFor: const Duration(minutes: 1),
      pauseFor: const Duration(seconds: 2),
      onResult: (r) {
        setState(() => text = r.recognizedWords);
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          reply(r.recognizedWords);
        }
      },
    );
  }

  Future<void> reply(String said) async {
    if (busy) return;
    busy = true;
    await stt.stop();
    setState(() {
      status = 'Soch rahi hoon...';
      orb = Colors.amber;
    });
    history.add({'role': 'user', 'parts': [{'text': said}]});
    if (history.length > 20) history.removeRange(0, history.length - 20);
    String ans;
    try {
      final res = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'systemInstruction': {'parts': [{'text': systemPrompt}]},
          'contents': history,
        }),
      );
      ans = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'];
      history.add({'role': 'model', 'parts': [{'text': ans}]});
    } catch (e) {
      history.removeLast();
      ans = 'Maaf karna, abhi net ya API mein dikkat hai. Dobara bolo.';
    }
    await speak(ans);
  }

  Future<void> speak(String t) async {
    busy = true;
    setState(() {
      status = 'Bol rahi hoon...';
      text = t;
      orb = Colors.pinkAccent;
    });
    await tts.speak(t);
  }

  @override
  Widget build(BuildContext context) {
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
                width: 140,
                height: 140,
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
                  style: const TextStyle(color: Colors.white, fontSize: 20)),
            ],
          ),
        ),
      ),
    );
  }
}
