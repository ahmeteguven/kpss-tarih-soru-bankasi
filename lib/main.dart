import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
// YENİ EKLENEN BAĞLANTI KONTROL KISMI
import 'package:connectivity_plus/connectivity_plus.dart';

// --------------------------------------------------------
// TEMA YÖNETİCİSİ (TAM SİYAH ARKA PLAN GÜNCELLEMESİ)
// --------------------------------------------------------

enum AppThemeColor { orange, teal, darkBlue, darkGreen, black }

class ThemeManager extends ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._internal();
  factory ThemeManager() => _instance;
  ThemeManager._internal();

  static SharedPreferences? _prefs;

  AppThemeColor _selectedColor = AppThemeColor.teal;
  bool _isDarkMode = false;

  AppThemeColor get selectedColor => _selectedColor;
  bool get isDarkMode => _isDarkMode;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    int? colorIndex = _prefs?.getInt('theme_color');
    bool? darkMode = _prefs?.getBool('is_dark_mode');
    if (colorIndex != null) _selectedColor = AppThemeColor.values[colorIndex];
    if (darkMode != null) _isDarkMode = darkMode;
    notifyListeners();
  }

  void changeColor(AppThemeColor color) {
    _selectedColor = color;
    _prefs?.setInt('theme_color', color.index);
    notifyListeners();
  }

  void toggleDarkMode(bool value) {
    _isDarkMode = value;
    _prefs?.setBool('is_dark_mode', value);
    notifyListeners();
  }

  MaterialColor get _primarySwatch {
    switch (_selectedColor) {
      case AppThemeColor.orange:
        return Colors.orange;
      case AppThemeColor.teal:
        return Colors.teal;
      case AppThemeColor.darkBlue:
        return Colors.indigo;
      case AppThemeColor.darkGreen:
        return Colors.green;
      case AppThemeColor.black:
        return Colors.grey;
      default:
        return Colors.teal;
    }
  }

  // --- RENK PALETİ ---

  MaterialColor get primaryColor => _isDarkMode ? Colors.grey : _primarySwatch;

  Color get appBarColor =>
      _isDarkMode ? const Color(0xFF1F1F1F) : _primarySwatch.shade600;

  Color get appBarForeground => Colors.white;

  Color get scaffoldBackgroundColor => _isDarkMode
      ? Colors.black
      : (_selectedColor == AppThemeColor.black
            ? Colors.grey.shade200
            : _primarySwatch.shade100);

  // Kart Rengi (Butonlar):
  Color get cardBackgroundColor =>
      _isDarkMode ? const Color(0xFFBDBDBD) : Colors.white;

  Color get textColor => _isDarkMode ? Colors.black : Colors.black87;
  Color get iconColor => _isDarkMode ? Colors.black87 : _primarySwatch;
}

// Global Erişim
final themeManager = ThemeManager();

// --------------------------------------------------------
// GLOBAL AYARLAR
// --------------------------------------------------------

/// Soru-metni ve şıkların global yazı boyutu katsayısı.
double globalQuestionTextScale = 1.0;

/// Hangi konularda "Bilgilendirme" popup'ı tekrar gösterilmesin seçildi
final Set<String> _dismissedTopicInfo = {};

// --------------------------------------------------------
// İSTATİSTİK SİSTEMİ
// --------------------------------------------------------

class TestResult {
  int totalQuestions;
  int solvedQuestions;
  int correctCount;
  int wrongCount;
  int emptyCount;
  int timeSpentSeconds;

  Map<int, String> selectedOptions;
  Set<int> favoriteQuestions;

  TestResult({
    this.totalQuestions = 0,
    this.solvedQuestions = 0,
    this.correctCount = 0,
    this.wrongCount = 0,
    this.emptyCount = 0,
    this.timeSpentSeconds = 0,
    Map<int, String>? selectedOptions,
    Set<int>? favoriteQuestions,
  }) : selectedOptions = selectedOptions ?? {},
       favoriteQuestions = favoriteQuestions ?? {};

  double get successRate {
    if (totalQuestions == 0) return 0.0;
    return (correctCount / totalQuestions) * 100;
  }

  bool get isFullySolved =>
      solvedQuestions == totalQuestions && totalQuestions > 0;

  void reset() {
    solvedQuestions = 0;
    correctCount = 0;
    wrongCount = 0;
    emptyCount = 0;
    timeSpentSeconds = 0;
    selectedOptions.clear();
    favoriteQuestions.clear();
  }

  // JSON Dönüşümleri (Kaydetme için)
  Map<String, dynamic> toJson() {
    return {
      'total': totalQuestions,
      'solved': solvedQuestions,
      'correct': correctCount,
      'wrong': wrongCount,
      'empty': emptyCount,
      'time': timeSpentSeconds,
      'selected': selectedOptions.map((k, v) => MapEntry(k.toString(), v)),
      'favorites': favoriteQuestions.toList(),
    };
  }

  factory TestResult.fromJson(Map<String, dynamic> json) {
    final selMap = <int, String>{};
    if (json['selected'] != null) {
      (json['selected'] as Map<String, dynamic>).forEach((k, v) {
        selMap[int.parse(k)] = v.toString();
      });
    }

    final favSet = <int>{};
    if (json['favorites'] != null) {
      favSet.addAll((json['favorites'] as List).map((e) => e as int));
    }

    return TestResult(
      totalQuestions: json['total'] ?? 0,
      solvedQuestions: json['solved'] ?? 0,
      correctCount: json['correct'] ?? 0,
      wrongCount: json['wrong'] ?? 0,
      emptyCount: json['empty'] ?? 0,
      timeSpentSeconds: json['time'] ?? 0,
      selectedOptions: selMap,
      favoriteQuestions: favSet,
    );
  }
}

class GlobalStatistics {
  // Konu Testleri verileri: TopicID -> TestName -> Result
  final Map<String, Map<String, TestResult>> topicResults = {};

  // Deneme verileri: ExamID -> Result
  final Map<String, TestResult> examResults = {};

  static SharedPreferences? _prefs;

  /// Uygulama açılışında verileri yükle
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final dismissedList = _prefs?.getStringList('dismissed_info');
    if (dismissedList != null) {
      _dismissedTopicInfo.addAll(dismissedList);
    }
  }

  /// Kayıtlı veriyi yükler
  void loadTestResultIfSaved(String parentId, String testId, bool isTopic) {
    if (_prefs == null) return;
    final key = isTopic ? 'topic_${parentId}_$testId' : 'exam_$testId';
    final jsonString = _prefs!.getString(key);

    if (jsonString != null) {
      try {
        final jsonMap = jsonDecode(jsonString);
        final loadedResult = TestResult.fromJson(jsonMap);

        if (isTopic) {
          if (!topicResults.containsKey(parentId)) topicResults[parentId] = {};
          topicResults[parentId]![testId] = loadedResult;
        } else {
          examResults[testId] = loadedResult;
        }
      } catch (e) {
        debugPrint('Hata: $key yüklenemedi.');
      }
    }
  }

  /// Veriyi kaydeder
  Future<void> saveTestResult(
    String parentId,
    String testId,
    TestResult result,
    bool isTopic,
  ) async {
    if (_prefs == null) return;
    final key = isTopic ? 'topic_${parentId}_$testId' : 'exam_$testId';
    final jsonString = jsonEncode(result.toJson());
    await _prefs!.setString(key, jsonString);
  }

  Future<void> saveDismissedInfo() async {
    if (_prefs == null) return;
    await _prefs!.setStringList('dismissed_info', _dismissedTopicInfo.toList());
  }

  TestResult getOverallTopicStats() {
    final overall = TestResult();
    topicResults.forEach((topicId, tests) {
      tests.forEach((testName, result) {
        overall.totalQuestions += result.totalQuestions;
        overall.correctCount += result.correctCount;
        overall.wrongCount += result.wrongCount;
        overall.emptyCount += result.emptyCount;
        overall.timeSpentSeconds += result.timeSpentSeconds;
        overall.solvedQuestions += result.solvedQuestions;
      });
    });
    return overall;
  }

  TestResult getTopicStats(String topicId) {
    final topicOverall = TestResult();
    final tests = topicResults[topicId] ?? {};

    tests.forEach((_, result) {
      topicOverall.totalQuestions += result.totalQuestions;
      topicOverall.correctCount += result.correctCount;
      topicOverall.wrongCount += result.wrongCount;
      topicOverall.emptyCount += result.emptyCount;
      topicOverall.timeSpentSeconds += result.timeSpentSeconds;
      topicOverall.solvedQuestions += result.solvedQuestions;
    });

    return topicOverall;
  }

  TestResult getOverallExamStats() {
    final overall = TestResult();
    examResults.forEach((examId, result) {
      overall.totalQuestions += result.totalQuestions;
      overall.correctCount += result.correctCount;
      overall.wrongCount += result.wrongCount;
      overall.emptyCount += result.emptyCount;
      overall.timeSpentSeconds += result.timeSpentSeconds;
      overall.solvedQuestions += result.solvedQuestions;
    });
    return overall;
  }
}

final GlobalStatistics globalStats = GlobalStatistics();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Firebase Başlatma
  await Firebase.initializeApp();

  // 2. Global İstatistikleri Başlat
  await globalStats.init();

  // 3. Tema Yöneticisini Başlat
  await themeManager.init();

  // 4. Bildirim Servisini Başlat
  await NotificationService().init();

  runApp(const KpssTarihApp());
}

// --------------------------------------------------------
// YENİ: BAĞLANTI KONTROL WIDGET'I
// --------------------------------------------------------

class ConnectivityChecker extends StatefulWidget {
  final Widget child;
  const ConnectivityChecker({super.key, required this.child});

  @override
  State<ConnectivityChecker> createState() => _ConnectivityCheckerState();
}

class _ConnectivityCheckerState extends State<ConnectivityChecker> {
  // Tipi List<ConnectivityResult> olarak güncelledik
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _isConnected = true;

  @override
  void initState() {
    super.initState();
    // 1. Başlangıçta mevcut durumu kontrol et
    _checkInitialConnection();
    // 2. Değişiklikleri dinlemeye başla
    // Dinleyiciyi List<ConnectivityResult> tipine göre güncelledik
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _updateConnectionStatus,
    );
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    super.dispose();
  }

  // İlk bağlantı kontrolü
  Future<void> _checkInitialConnection() async {
    // Sonuç tipini List<ConnectivityResult> olarak aldık
    final results = await Connectivity().checkConnectivity();
    _updateConnectionStatus(results);
  }

  // Bağlantı durumunu güncelleyen ana fonksiyon
  // Parametre tipini List<ConnectivityResult> olarak güncelledik
  void _updateConnectionStatus(List<ConnectivityResult> results) {
    // none elemanını içermiyorsa bağlı kabul et
    bool isConnected = !results.contains(ConnectivityResult.none);

    // YENİ: Bağlantı kesikken internet gelirse bildirim gösterilebilir
    if (_isConnected == false && isConnected == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ İnternet bağlantısı yeniden sağlandı.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    }

    if (_isConnected != isConnected) {
      setState(() {
        _isConnected = isConnected;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. Uygulamanın normal içeriği
        widget.child,

        // 2. İnternet kesikse gösterilecek Overlay
        if (!_isConnected)
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.95),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.signal_cellular_off_outlined,
                        color: Colors.redAccent,
                        size: 80,
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        'İNTERNET BAĞLANTISI GEREKLİ',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Uygulamada reklamları ve bazı Firebase servislerini kullanmak için lütfen internet bağlantınızı kontrol edin. Bağlantı sağlandığında otomatik olarak devam edecektir.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      const SizedBox(height: 40),
                      SizedBox(
                        width: 200,
                        child: ElevatedButton.icon(
                          onPressed: _checkInitialConnection,
                          icon: const Icon(Icons.refresh, color: Colors.white),
                          label: const Text(
                            'TEKRAR KONTROL ET',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class KpssTarihApp extends StatelessWidget {
  const KpssTarihApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Tema değişikliğini dinlemek için AnimatedBuilder kullanıyoruz
    return AnimatedBuilder(
      animation: themeManager,
      builder: (context, child) {
        return MaterialApp(
          title: 'KPSS Tarih Soru Bankası 2026',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            primaryColor: themeManager.primaryColor,
            colorScheme: ColorScheme.fromSeed(
              seedColor: themeManager.primaryColor,
              primary: themeManager.primaryColor,
              brightness: themeManager.isDarkMode
                  ? Brightness.dark
                  : Brightness.light,
            ),
            scaffoldBackgroundColor: themeManager.scaffoldBackgroundColor,
            useMaterial3: true,
            appBarTheme: AppBarTheme(
              backgroundColor: themeManager.appBarColor,
              foregroundColor: themeManager.appBarForeground,
              centerTitle: true,
              elevation: 0,
            ),
          ),
          // ANA SAYFAYI BAĞLANTI KONTROL WIDGET'I İLE SAR
          home: const ConnectivityChecker(child: SplashToHome()),
        );
      },
    );
  }
}

// --------------------------------------------------------
// SPLASH TO HOME - YÖNLENDİRME HATASI GİDERİLDİ
// --------------------------------------------------------

class SplashToHome extends StatefulWidget {
  const SplashToHome({super.key});

  @override
  State<SplashToHome> createState() => _SplashToHomeState();
}

class _SplashToHomeState extends State<SplashToHome> {
  // Veri yüklendiğinde AppData'yı tutar
  AppData? _appData;
  // İlk yükleme bitti mi?
  bool _isDataLoaded = false;
  // Onboarding daha önce tamamlandı mı? (SharedPreferences'tan okunan ilk durum)
  bool _onboardingDoneInPrefs = false;
  // Onboarding bu oturumda mı tamamlandı?
  bool _onboardingCompletedInSession = false;

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    // 1. SharedPreferences'ı başlat
    await globalStats.init();

    // 2. Uygulama verilerini yükle (En ağır işlem)
    final data = await AppData.load();
    _initializeStats(data);

    // 3. Onboarding durumunu kontrol et
    final prefs = await SharedPreferences.getInstance();
    final initialOnboardingDone =
        prefs.getBool('onboarding_tamamlandi') ?? false;

    if (mounted) {
      setState(() {
        _appData = data;
        _onboardingDoneInPrefs = initialOnboardingDone;
        _isDataLoaded = true;
      });
    }
  }

  // OnboardingScreen'dan gelen callback fonksiyonu (Başla/Atla tuşuna basıldığında)
  void _onOnboardingComplete() async {
    // SharedPreferences kaydetme işlemi OnboardingScreen içinde yapılıyor.
    // Biz sadece state'i güncelleyerek anında Ana Sayfaya geçişi sağlıyoruz.
    if (mounted) {
      setState(() {
        _onboardingCompletedInSession = true;
        // Onboarding'in bittiğini SharedPreferences'a da kaydedildiğini varsayıyoruz.
        // Bu yüzden artık ana ekrana geçebiliriz.
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDataLoaded) {
      // Yükleniyor Ekranı
      return Scaffold(
        backgroundColor: themeManager.scaffoldBackgroundColor,
        body: Center(
          child: CircularProgressIndicator(
            color: themeManager.isDarkMode
                ? Colors.white
                : themeManager.primaryColor,
          ),
        ),
      );
    }

    final data = _appData!;

    // Yönlendirme Kararı:
    // 1. Eğer SharedPreferences'ta daha önce tamamlandıysa (önceki oturum), VEYA
    // 2. Eğer bu oturumda (_onOnboardingComplete ile) tamamlandıysa,
    // Ana Sayfayı göster.
    if (_onboardingDoneInPrefs || _onboardingCompletedInSession) {
      return HomeScreen(appData: data);
    } else {
      // Aksi takdirde Onboarding ekranını göster.
      return OnboardingScreen(onOnboardingComplete: _onOnboardingComplete);
    }
  }

  void _initializeStats(AppData data) {
    // Konu Testleri İçin
    for (final topic in data.topics) {
      if (!globalStats.topicResults.containsKey(topic.id)) {
        globalStats.topicResults[topic.id] = {};
      }
      for (final test in topic.testSets) {
        // Kayıtlı veriyi yükle
        globalStats.loadTestResultIfSaved(topic.id, test.testName, true);

        // Kayıt yoksa boş oluştur
        if (!globalStats.topicResults[topic.id]!.containsKey(test.testName)) {
          globalStats.topicResults[topic.id]![test.testName] = TestResult(
            totalQuestions: test.questions.length,
          );
        } else {
          // Soru sayısını güncelle
          globalStats.topicResults[topic.id]![test.testName]!.totalQuestions =
              test.questions.length;
        }
      }
    }
    // Denemeler İçin
    for (final exam in data.exams) {
      globalStats.loadTestResultIfSaved("", exam.id, false);
      if (!globalStats.examResults.containsKey(exam.id)) {
        globalStats.examResults[exam.id] = TestResult(
          totalQuestions: exam.questions.length,
        );
      } else {
        globalStats.examResults[exam.id]!.totalQuestions =
            exam.questions.length;
      }
    }
  }
}

// ---------------------- DATA MODELLERİ (AYNEN KALDI) ----------------------

class Question {
  final String text;
  final List<String> options;
  final String correctOption;
  final String solution;

  Question({
    required this.text,
    required this.options,
    required this.correctOption,
    required this.solution,
  });

  factory Question.fromJson(Map<String, dynamic> json) {
    return Question(
      text: json['text'] as String,
      options: (json['options'] as List).cast<String>(),
      correctOption: json['correctOption'] as String,
      solution: (json['solution'] ?? '') as String,
    );
  }
}

class TestSet {
  final String testName;
  final String preTestNote;
  final List<Question> questions;

  TestSet({
    required this.testName,
    required this.preTestNote,
    required this.questions,
  });

  factory TestSet.fromJson(Map<String, dynamic> json) {
    return TestSet(
      testName: json['testName'] as String,
      preTestNote: (json['preTestNote'] ?? '') as String,
      questions: (json['questions'] as List)
          .map((q) => Question.fromJson(q as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Topic {
  final String id;
  final String topicName;
  final List<TestSet> testSets;

  Topic({required this.id, required this.topicName, required this.testSets});

  factory Topic.fromJson(String id, Map<String, dynamic> json) {
    return Topic(
      id: id,
      topicName: json['topicName'] as String,
      testSets: (json['testSets'] as List)
          .map((t) => TestSet.fromJson(t as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ExamTest implements TestSet {
  final String id;
  @override
  final String testName;
  final String preExamNote;
  @override
  final List<Question> questions;

  @override
  String get preTestNote => preExamNote;

  ExamTest({
    required this.id,
    required this.testName,
    required this.preExamNote,
    required this.questions,
  });

  factory ExamTest.fromJson(String id, Map<String, dynamic> json) {
    return ExamTest(
      id: id,
      testName: json['examName'] ?? id,
      preExamNote: (json['preExamNote'] ?? '') as String,
      questions: (json['questions'] as List)
          .map((q) => Question.fromJson(q as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// HAP BİLGİLER İÇİN YENİ MODELLER
class Fact {
  final int id;
  final String question;
  final String answer;

  Fact({required this.id, required this.question, required this.answer});

  factory Fact.fromJson(Map<String, dynamic> json) {
    return Fact(
      id: json['id'] as int,
      question: json['question'] as String,
      answer: json['answer'] as String,
    );
  }
}

class FactCategory {
  final String categoryName;
  final List<Fact> facts;

  FactCategory({required this.categoryName, required this.facts});

  factory FactCategory.fromJson(Map<String, dynamic> json) {
    return FactCategory(
      categoryName: json['categoryName'] as String,
      facts: (json['facts'] as List)
          .map((f) => Fact.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// SÖZLÜK VERİ MODELİ
class DictionaryTerm {
  final String word;
  final String definition;

  DictionaryTerm({required this.word, required this.definition});

  factory DictionaryTerm.fromJson(Map<String, dynamic> json) {
    return DictionaryTerm(
      word: json['word'] ?? '',
      definition: json['definition'] ?? '',
    );
  }
}

class AppData {
  final List<Topic> topics;
  final List<ExamTest> exams;
  final List<String> quotes;
  final List<FactCategory> factCategories;
  final List<DictionaryTerm> dictionary;

  AppData({
    required this.topics,
    required this.exams,
    required this.quotes,
    required this.factCategories,
    required this.dictionary,
  });

  static Future<AppData> load() async {
    const topicFilesInOrder = [
      'assets/topics/islamiyet_oncesi.json',
      'assets/topics/ilk_turk_islam.json',
      'assets/topics/osmanli_tarihi.json',
      'assets/topics/xx_yy_osmanli.json',
      'assets/topics/kurtulus_savasi_hazirlik.json',
      'assets/topics/kurtulus_savasi_muharebeler.json',
      'assets/topics/ataturk_donemi_inkilap.json',
      'assets/topics/ataturk_donemi_ic_dis_politika.json',
      'assets/topics/cagdas_turk_dunya_tarihi.json',
    ];

    final topics = <Topic>[];
    for (final path in topicFilesInOrder) {
      try {
        final raw = await rootBundle.loadString(path);
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        final id = path.split('/').last.split('.').first;
        final index = topics.length + 1;
        final topicName =
            '${index.toString().padLeft(2, '0')}- ${jsonMap['topicName'] as String}';
        jsonMap['topicName'] = topicName;
        topics.add(Topic.fromJson(id, jsonMap));
      } catch (e) {
        debugPrint('Topic Load Error: $e');
      }
    }

    final exams = <ExamTest>[];
    for (int i = 1; i <= 50; i++) {
      final indexStr = i.toString().padLeft(2, '0');
      final path = 'assets/denemeler/deneme_$indexStr.json';
      try {
        final raw = await rootBundle.loadString(path);
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        exams.add(ExamTest.fromJson('deneme_$indexStr', jsonMap));
      } catch (_) {}
    }

    final factCategories = <FactCategory>[];
    const factFiles = [
      '01_ilk_turk_devletleri.json',
      '02_ilk_turk_islam_devletleri.json',
      '03_osmanli_siyasi.json',
      '04_osmanli_kultur_uygarlik.json',
      '05_19yy_osmanli_dagilma.json',
      '06_20yy_osmanli.json',
      '07_milli_mucadele_hazirlik.json',
      '08_kurtulus_savasi_cepheler.json',
      '09_cumhuriyet_donemi_inkilaplar.json',
      '10_ataturk_ilkeleri.json',
      '11_ataturk_donemi_dis_politika.json',
      '12_cagdas_turk_ve_dunya_tarihi.json',
    ];

    for (final fileName in factFiles) {
      final path = 'assets/hap_bilgiler/$fileName';
      try {
        final raw = await rootBundle.loadString(path);
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        final indexStr = fileName.substring(0, 2);
        final originalName = jsonMap['categoryName'] as String;
        jsonMap['categoryName'] = '$indexStr- $originalName';
        factCategories.add(FactCategory.fromJson(jsonMap));
      } catch (e) {
        debugPrint('Fact file not found or error: $path');
      }
    }

    final dictionary = <DictionaryTerm>[];
    try {
      final rawDict = await rootBundle.loadString('assets/dictionary.json');
      final jsonDict = jsonDecode(rawDict) as List;
      for (var item in jsonDict) {
        dictionary.add(DictionaryTerm.fromJson(item));
      }
    } catch (e) {
      debugPrint('Dictionary load error: $e');
    }

    final quotesRaw = await rootBundle.loadString('assets/quotes/quotes.json');
    final quotesJson = jsonDecode(quotesRaw) as Map<String, dynamic>;
    final quotes = (quotesJson['quotes'] as List)
        .map((e) => e.toString())
        .toList();

    return AppData(
      topics: topics,
      exams: exams,
      quotes: quotes,
      factCategories: factCategories,
      dictionary: dictionary,
    );
  }

  String getQuoteOfTheDay() {
    if (quotes.isEmpty) return 'Motivasyon sözü bulunamadı.';
    final now = DateTime.now();
    final base = DateTime(2024, 1, 1);
    final diff = now.difference(base).inDays;
    final index = diff.abs() % quotes.length;
    return quotes[index];
  }
}

String _formatDuration(int seconds) {
  final d = Duration(seconds: seconds);
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  return '${twoDigits(d.inMinutes)}:${twoDigits(d.inSeconds.remainder(60))}';
}

/// Soru İnceleme Ekranında Gösterilecek Veri Modeli
class ReviewData {
  final Question question;
  final String? givenAnswer;
  final String sourceTestName;

  ReviewData(this.question, this.givenAnswer, this.sourceTestName);
}

// ---------------------- ORTAK WIDGETLAR (GÜNCELLENDİ) ----------------------

class _WhiteCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry? padding;

  const _WhiteCard({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        // Rengi buradan alıyor (Karanlıkta Açık Gri, Aydınlıkta Beyaz)
        color: themeManager.cardBackgroundColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          // Hafif bir gölge ekleyerek 'kaybolma' hissini yok ediyoruz
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: padding ?? const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _StatsHeader extends StatelessWidget {
  final String title;
  final TestResult stats;

  const _StatsHeader({required this.title, required this.stats});

  @override
  Widget build(BuildContext context) {
    final rateText =
        '%${stats.successRate.toStringAsFixed(1).replaceAll('.', ',')}';
    return _WhiteCard(
      child: Column(
        children: [
          Text(
            '$title\n$rateText',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: themeManager.textColor,
            ),
          ),
          const SizedBox(height: 12),
          _statRow(
            'Toplam Çözülen Soru Sayısı',
            stats.solvedQuestions.toString(),
          ),
          _statRow('Toplam Boş Sayısı', stats.emptyCount.toString()),
          _statRow('Toplam Doğru Sayısı', stats.correctCount.toString()),
          _statRow('Toplam Yanlış Sayısı', stats.wrongCount.toString()),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: themeManager.textColor)),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: themeManager.textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniTopButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MiniTopButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: themeManager.cardBackgroundColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: themeManager.iconColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: themeManager.textColor,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------- ANA SAYFA ----------------------

class HomeScreen extends StatefulWidget {
  final AppData appData;
  const HomeScreen({super.key, required this.appData});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late String _currentQuote;

  @override
  void initState() {
    super.initState();
    _currentQuote = widget.appData.getQuoteOfTheDay();
  }

  void _refreshQuote() {
    setState(() {
      if (widget.appData.quotes.isNotEmpty) {
        _currentQuote = widget
            .appData
            .quotes[Random().nextInt(widget.appData.quotes.length)];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Başlık
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: themeManager.cardBackgroundColor,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Center(
                  child: Text(
                    'Kpss Tarih Soru Bankası 2026',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: themeManager.textColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Sayaç Kartı
              _WhiteCard(
                child: Column(
                  children: [
                    Text(
                      'Sınava Kalan Gün',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: themeManager.textColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Icon(
                      Icons.remove_red_eye_outlined,
                      color: themeManager.iconColor,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.spaceEvenly,
                      spacing: 12,
                      runSpacing: 12,
                      children: _buildCountdowns(),
                    ),
                  ],
                ),
              ),

              // Günün Sözü
              _WhiteCard(
                child: Column(
                  children: [
                    Text(
                      'Günün Sözü',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: themeManager.textColor,
                      ),
                    ),

                    IconButton(
                      icon: Icon(Icons.refresh, color: themeManager.iconColor),
                      onPressed: _refreshQuote,
                    ),

                    const SizedBox(height: 8),
                    Text(
                      _currentQuote,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: themeManager.textColor,
                      ),
                    ),
                  ],
                ),
              ),

              // Menü Butonları
              _MenuButton(
                icon: Icons.menu_book_outlined,
                label: 'KONU TESTLERİ',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TopicsScreen(appData: widget.appData),
                    ),
                  );
                },
              ),
              _MenuButton(
                icon: Icons.fact_check_outlined,
                label: 'DENEMELER',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExamsScreen(appData: widget.appData),
                    ),
                  );
                },
              ),
              _MenuButton(
                icon: Icons.bolt_outlined,
                label: 'HAP BİLGİLER (SORU - CEVAP)',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          HapBilgilerScreen(appData: widget.appData),
                    ),
                  );
                },
              ),
              _MenuButton(
                icon: Icons.menu_book_rounded,
                label: 'SÖZLÜK – TERİMLER',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DictionaryScreen(appData: widget.appData),
                    ),
                  );
                },
              ),
              _MenuButton(
                icon: Icons.notes_outlined,
                label: 'KONU ÖZETİ',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const KonuOzetleriListScreen(),
                    ),
                  );
                },
              ),
              _MenuButton(
                icon: Icons.star_rate_rounded,
                label: 'PUAN VER',
                onTap: () => _showSoon(context),
              ),
              _MenuButton(
                icon: Icons.workspace_premium_outlined,
                label: 'REKLAMLARDAN KURTUL (PREMIUM)',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PremiumMembershipPage(),
                    ),
                  );
                },
              ),
              // --- YENİ TEMA AYARLARI BUTONU ---
              _MenuButton(
                icon: Icons.color_lens_outlined,
                label: 'TEMA VE GÖRÜNÜM AYARLARI',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ThemeSettingsPage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _showSoon(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Yakında eklenecek.')));
  }

  List<Widget> _buildCountdowns() {
    final now = DateTime.now();
    final dates = {
      'Lisans': DateTime(2026, 9, 6),
      'Ön Lisans': DateTime(2026, 10, 4),
      'Orta Öğretim': DateTime(2026, 10, 25),
      'AGS Lisans': DateTime(2026, 7, 12),
    };
    return dates.entries.map((e) {
      final days = e.value
          .difference(DateTime(now.year, now.month, now.day))
          .inDays;
      return Column(
        children: [
          Text(
            e.key,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: themeManager.textColor,
            ),
          ),
          Text(
            '(${e.value.day}.${e.value.month}.${e.value.year})',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          Text(
            '${days > 0 ? days : 0} Gün',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: themeManager.textColor,
            ),
          ),
        ],
      );
    }).toList();
  }
}

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _WhiteCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 40, color: themeManager.iconColor),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: themeManager.textColor,
              ),
            ),
          ),
          Icon(Icons.chevron_right, color: Colors.grey.shade600),
        ],
      ),
    );
  }
}

// ---------------------- TEMA AYARLARI SAYFASI (YENİ) ----------------------

class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Tema değişikliğini anlık görmek için AnimatedBuilder burada da kullanılır
    return AnimatedBuilder(
      animation: themeManager,
      builder: (context, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Tema ve Görünüm'),
            backgroundColor: themeManager.appBarColor,
            foregroundColor: Colors.white,
          ),
          backgroundColor: themeManager.scaffoldBackgroundColor,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader('Mod Seçimi'),
                _WhiteCard(
                  child: SwitchListTile(
                    title: Text(
                      'Karanlık Mod (Dark Mode)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: themeManager.textColor,
                      ),
                    ),
                    subtitle: Text(
                      'Göz yormayan koyu tema',
                      style: TextStyle(
                        color: themeManager.textColor.withOpacity(0.7),
                      ),
                    ),
                    activeColor: themeManager.primaryColor,
                    value: themeManager.isDarkMode,
                    onChanged: (val) {
                      themeManager.toggleDarkMode(val);
                    },
                    secondary: Icon(
                      themeManager.isDarkMode
                          ? Icons.dark_mode
                          : Icons.light_mode,
                      color: themeManager.iconColor,
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                _buildSectionHeader('Renk Teması'),
                _WhiteCard(
                  child: Column(
                    children: [
                      _buildColorOption(
                        AppThemeColor.orange,
                        'Turuncu',
                        Colors.orange,
                      ),
                      const Divider(),
                      _buildColorOption(
                        AppThemeColor.teal,
                        'Turkuaz (Teal)',
                        Colors.teal,
                      ),
                      const Divider(),
                      _buildColorOption(
                        AppThemeColor.darkBlue,
                        'Koyu Mavi',
                        Colors.indigo,
                      ),
                      const Divider(),
                      _buildColorOption(
                        AppThemeColor.darkGreen,
                        'Koyu Yeşil',
                        Colors.green,
                      ),
                      const Divider(),
                      _buildColorOption(
                        AppThemeColor.black,
                        'Siyah (Monokrom)',
                        Colors.black,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: themeManager.isDarkMode ? Colors.white70 : Colors.black87,
        ),
      ),
    );
  }

  Widget _buildColorOption(
    AppThemeColor color,
    String label,
    Color displayColor,
  ) {
    return RadioListTile<AppThemeColor>(
      title: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: displayColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade300),
            ),
          ),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: themeManager.textColor)),
        ],
      ),
      value: color,
      groupValue: themeManager.selectedColor,
      activeColor: themeManager.primaryColor,
      onChanged: (val) {
        if (val != null) {
          themeManager.changeColor(val);
        }
      },
    );
  }
}

// ---------------------- SÖZLÜK EKRANI ----------------------

class DictionaryScreen extends StatelessWidget {
  final AppData appData;
  const DictionaryScreen({super.key, required this.appData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SÖZLÜK – TERİMLER'),
        backgroundColor: Colors.white,
        foregroundColor: themeManager.primaryColor,
      ),
      backgroundColor: themeManager.scaffoldBackgroundColor,
      body: appData.dictionary.isEmpty
          ? const Center(
              child: Text(
                "Sözlük verisi bulunamadı.",
                style: TextStyle(color: Colors.white),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: appData.dictionary.length,
              separatorBuilder: (ctx, index) =>
                  const Divider(color: Colors.white24, height: 24),
              itemBuilder: (ctx, index) {
                final term = appData.dictionary[index];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sıra Numarası (Sabit genişlik yerine normal Text)
                    Text(
                      "${index + 1}.",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),

                    // Araya Sabit Kısa Boşluk
                    const SizedBox(width: 6),

                    // Kelime Kutusu
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.black, width: 1.5),
                      ),
                      child: Text(
                        term.word,
                        style: TextStyle(
                          color:
                              themeManager.primaryColor, // Kutu içi yazı rengi
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Açıklama
                    Expanded(
                      child: Text(
                        term.definition,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

// ---------------------- HAP BİLGİLER LİSTESİ ----------------------

class HapBilgilerScreen extends StatelessWidget {
  final AppData appData;
  const HapBilgilerScreen({super.key, required this.appData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'HAP BİLGİLER (SORU - CEVAP)',
          textAlign: TextAlign.center,
          maxLines: 2,
          style: TextStyle(fontSize: 16),
        ),
        backgroundColor: Colors.white,
        foregroundColor: themeManager.primaryColor,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final category in appData.factCategories)
              _WhiteCard(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          FactCategoryDetailScreen(category: category),
                    ),
                  );
                },
                child: Row(
                  children: [
                    Icon(Icons.menu_book, color: themeManager.iconColor),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        category.categoryName.toUpperCase(),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: themeManager.textColor,
                        ),
                      ),
                    ),
                    Icon(Icons.book_outlined, color: themeManager.iconColor),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------- HAP BİLGİ DETAY ----------------------

class FactCategoryDetailScreen extends StatelessWidget {
  final FactCategory category;
  const FactCategoryDetailScreen({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          category.categoryName,
          style: const TextStyle(fontSize: 16),
          maxLines: 2,
        ),
        backgroundColor: Colors.white,
        foregroundColor: themeManager.primaryColor,
      ),
      body: Container(
        color: themeManager.isDarkMode
            ? const Color(0xFF121212)
            : themeManager.primaryColor.withOpacity(0.1),
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: category.facts.length,
          itemBuilder: (ctx, index) {
            return _FactCard(fact: category.facts[index]);
          },
        ),
      ),
    );
  }
}

class _FactCard extends StatefulWidget {
  final Fact fact;
  const _FactCard({required this.fact});

  @override
  State<_FactCard> createState() => _FactCardState();
}

class _FactCardState extends State<_FactCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: themeManager.cardBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            setState(() {
              _isExpanded = !_isExpanded;
            });
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        widget.fact.question,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: themeManager.textColor,
                        ),
                      ),
                    ),
                    Icon(
                      _isExpanded ? Icons.arrow_drop_up : Icons.arrow_right,
                      color: themeManager.iconColor,
                    ),
                  ],
                ),
                if (_isExpanded) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: themeManager.isDarkMode
                          ? Colors.black26
                          : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: themeManager.isDarkMode
                            ? Colors.white24
                            : themeManager.primaryColor.withOpacity(0.3),
                      ),
                    ),
                    child: Text(
                      widget.fact.answer,
                      style: TextStyle(
                        color: themeManager.isDarkMode
                            ? Colors.white
                            : themeManager.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------- KONU TESTLERİ LİSTESİ ----------------------

class TopicsScreen extends StatefulWidget {
  final AppData appData;
  const TopicsScreen({super.key, required this.appData});

  @override
  State<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends State<TopicsScreen> {
  // Tüm konulardan favori ve yanlışları toplar
  List<ReviewData> _getAllTopicQuestions(bool isFavorite) {
    List<ReviewData> list = [];
    for (var topic in widget.appData.topics) {
      if (globalStats.topicResults.containsKey(topic.id)) {
        final tests = globalStats.topicResults[topic.id]!;
        for (var test in topic.testSets) {
          if (tests.containsKey(test.testName)) {
            final res = tests[test.testName]!;
            for (int i = 0; i < test.questions.length; i++) {
              if (isFavorite) {
                if (res.favoriteQuestions.contains(i)) {
                  list.add(
                    ReviewData(
                      test.questions[i],
                      res.selectedOptions[i],
                      '${topic.topicName} - ${test.testName}',
                    ),
                  );
                }
              } else {
                final userAns = res.selectedOptions[i];
                if (userAns != null &&
                    userAns != test.questions[i].correctOption) {
                  list.add(
                    ReviewData(
                      test.questions[i],
                      userAns,
                      '${topic.topicName} - ${test.testName}',
                    ),
                  );
                }
              }
            }
          }
        }
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final stats = globalStats.getOverallTopicStats();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Konu Testleri'),
        backgroundColor: themeManager.appBarColor,
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatsHeader(title: 'Genel Başarı Oranı', stats: stats),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.favorite_border,
                    label: 'Favori Sorularım',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Tüm Konular - Favoriler',
                            data: _getAllTopicQuestions(true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.warning_amber_outlined,
                    label: 'Yanlış Çözdüklerim',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Tüm Konular - Yanlışlar',
                            data: _getAllTopicQuestions(false),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final topic in widget.appData.topics)
              _WhiteCard(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TopicDetailScreen(topic: topic),
                    ),
                  );
                  setState(() {});
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topic.topicName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: themeManager.textColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _TopicStatsRow(topicId: topic.id),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopicStatsRow extends StatelessWidget {
  final String topicId;
  const _TopicStatsRow({required this.topicId});

  @override
  Widget build(BuildContext context) {
    final s = globalStats.getTopicStats(topicId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('Toplam Soru Sayısı', '${s.totalQuestions}'),
        _row('Toplam Doğru Sayısı', '${s.correctCount}'),
        _row('Toplam Yanlış Sayısı', '${s.wrongCount}'),
        _row('Toplam Boş Sayısı', '${s.emptyCount}'),
        _row(
          'GENEL BAŞARI',
          '%${s.successRate.toStringAsFixed(1)}',
          isBold: true,
        ),
      ],
    );
  }

  Widget _row(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: themeManager.textColor)),
          Text(
            value,
            style: TextStyle(
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              color: themeManager.textColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------- KONU DETAY ----------------------

class TopicDetailScreen extends StatefulWidget {
  final Topic topic;
  const TopicDetailScreen({super.key, required this.topic});

  @override
  State<TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<TopicDetailScreen> {
  late TestResult _topicStats;

  @override
  void initState() {
    super.initState();
    _topicStats = globalStats.getTopicStats(widget.topic.id);

    if (!_dismissedTopicInfo.contains(widget.topic.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showInfo());
    }
  }

  List<ReviewData> _getTopicQuestions(bool isFavorite) {
    List<ReviewData> list = [];
    if (globalStats.topicResults.containsKey(widget.topic.id)) {
      final tests = globalStats.topicResults[widget.topic.id]!;
      for (var test in widget.topic.testSets) {
        if (tests.containsKey(test.testName)) {
          final res = tests[test.testName]!;
          for (int i = 0; i < test.questions.length; i++) {
            if (isFavorite) {
              if (res.favoriteQuestions.contains(i)) {
                list.add(
                  ReviewData(
                    test.questions[i],
                    res.selectedOptions[i],
                    test.testName,
                  ),
                );
              }
            } else {
              final userAns = res.selectedOptions[i];
              if (userAns != null &&
                  userAns != test.questions[i].correctOption) {
                list.add(ReviewData(test.questions[i], userAns, test.testName));
              }
            }
          }
        }
      }
    }
    return list;
  }

  List<ReviewData> _getTestQuestions(TestSet test, bool isFavorite) {
    List<ReviewData> list = [];
    final res = globalStats.topicResults[widget.topic.id]![test.testName]!;
    for (int i = 0; i < test.questions.length; i++) {
      if (isFavorite) {
        if (res.favoriteQuestions.contains(i)) {
          list.add(
            ReviewData(
              test.questions[i],
              res.selectedOptions[i],
              test.testName,
            ),
          );
        }
      } else {
        final userAns = res.selectedOptions[i];
        if (userAns != null && userAns != test.questions[i].correctOption) {
          list.add(ReviewData(test.questions[i], userAns, test.testName));
        }
      }
    }
    return list;
  }

  void _showInfo() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: themeManager.cardBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Bilgilendirme!',
              style: TextStyle(color: themeManager.textColor),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(
                Icons.close,
                color: themeManager.isDarkMode ? Colors.white70 : Colors.grey,
              ),
              onPressed: () {
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        content: Text(
          'Bu sayfada, tüm testlerdeki favori ve yanlış yaptığınız soruları genel bir şekilde görüntüleyebilirsiniz. Her testin üzerine basılı tutarak, o teste ait favori ve yanlış soruları detaylı olarak görebilir, aynı zamanda testle ilgili bilgilere de ulaşabilirsiniz. İsterseniz testi sıfırlayarak, soruları baştan çözebilir ve ilerlemenizi yeniden takip edebilirsiniz.',
          style: TextStyle(fontSize: 15, color: themeManager.textColor),
        ),
        actions: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: themeManager.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () {
                _dismissedTopicInfo.add(widget.topic.id);
                globalStats.saveDismissedInfo();
                Navigator.pop(ctx);
              },
              child: const Text('Tekrar Gösterme'),
            ),
          ),
        ],
      ),
    );
  }

  void _resetTest(TestSet test) {
    setState(() {
      final res = globalStats.topicResults[widget.topic.id]![test.testName]!;
      res.reset();
      globalStats.saveTestResult(widget.topic.id, test.testName, res, true);
      _topicStats = globalStats.getTopicStats(widget.topic.id);
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${test.testName} sıfırlandı')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic.topicName),
        backgroundColor: themeManager.appBarColor,
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatsHeader(
              title: '${widget.topic.topicName} Başarı Oranı',
              stats: _topicStats,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.favorite,
                    label: 'Favori Sorularım',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Favorilerim',
                            data: _getTopicQuestions(true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.warning_amber,
                    label: 'Yanlış Çözdüklerim',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Yanlışlarım',
                            data: _getTopicQuestions(false),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final test in widget.topic.testSets)
              _TestListItem(
                testName: test.testName,
                testId: test.testName,
                topicId: widget.topic.id,
                questions: test.questions,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TestSolveScreen(topic: widget.topic, testSet: test),
                    ),
                  );
                  setState(() {
                    _topicStats = globalStats.getTopicStats(widget.topic.id);
                  });
                },
                onLongPress: () => _showTestSummaryDialog(test),
              ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, [Color? color]) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: themeManager.isDarkMode
            ? Colors.white10
            : themeManager.primaryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: themeManager.textColor)),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color ?? themeManager.textColor,
            ),
          ),
        ],
      ),
    );
  }

  void _showTestSummaryDialog(TestSet test) {
    final result = globalStats.topicResults[widget.topic.id]![test.testName]!;

    final durationText = _formatDuration(result.timeSpentSeconds);
    // YENİ MANTIK: Toplam Süre / Toplam Soru Sayısı
    final avgSeconds = result.totalQuestions == 0
        ? 0.0
        : result.timeSpentSeconds.toDouble() / result.totalQuestions.toDouble();
    final avgText = avgSeconds.toStringAsFixed(1).replaceAll('.', ',');

    final total = result.totalQuestions;
    final correct = result.correctCount;
    final wrong = result.wrongCount;
    final empty = result.emptyCount;
    final success = result.successRate;
    final successText = '%${success.toStringAsFixed(1).replaceAll('.', ',')}';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: themeManager.cardBackgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            '${widget.topic.topicName} - ${test.testName}',
            style: TextStyle(color: themeManager.textColor),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _summaryRow('Testte Harcanan Süre', durationText),
                _summaryRow('Ortalama Süre (sn)', avgText),
                _summaryRow('Soru Sayısı', result.totalQuestions.toString()),
                _summaryRow(
                  'Doğru',
                  result.correctCount.toString(),
                  Colors.green,
                ),
                _summaryRow('Yanlış', result.wrongCount.toString(), Colors.red),
                _summaryRow('Boş', result.emptyCount.toString()),
                _summaryRow(
                  'Başarı Puanı',
                  successText,
                  success >= 50 ? Colors.green : Colors.red,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MiniTopButton(
                        icon: Icons.favorite,
                        label: 'Favoriler',
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuestionsReviewScreen(
                                title: '${test.testName} - Favoriler',
                                data: _getTestQuestions(test, true),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: _MiniTopButton(
                        icon: Icons.warning,
                        label: 'Yanlışlar',
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuestionsReviewScreen(
                                title: '${test.testName} - Yanlışlar',
                                data: _getTestQuestions(test, false),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Testi Sıfırla'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _resetTest(test);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TestListItem extends StatelessWidget {
  final String testName;
  final String testId;
  final String? topicId;
  final List<Question> questions;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TestListItem({
    required this.testName,
    required this.testId,
    this.topicId,
    required this.questions,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final result = topicId != null
        ? globalStats.topicResults[topicId]![testName]!
        : globalStats.examResults[testId]!;

    return _WhiteCard(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              testName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: themeManager.textColor,
              ),
            ),
          ),
          if (result.isFullySolved)
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Center(
                child: Text(
                  '✅ Tamamı Çözüldü ✅',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Soru: ${questions.length}',
                style: TextStyle(color: themeManager.textColor),
              ),
              Text(
                'Doğru: ${result.correctCount}',
                style: TextStyle(color: themeManager.textColor),
              ),
              Text(
                'Yanlış: ${result.wrongCount}',
                style: TextStyle(color: themeManager.textColor),
              ),
              Text(
                'Boş: ${result.emptyCount}',
                style: TextStyle(color: themeManager.textColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------- DENEMELER ----------------------

class ExamsScreen extends StatefulWidget {
  final AppData appData;
  const ExamsScreen({super.key, required this.appData});

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen> {
  // --- YENİ EKLENEN KISIM: AÇILIŞTA BİLGİLENDİRME ---
  @override
  void initState() {
    super.initState();
    // Eğer "exams_info_shown" ID'si kayıtlı değilse göster
    if (!_dismissedTopicInfo.contains("exams_info_shown")) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showInfo());
    }
  }

  void _showInfo() {
    showDialog(
      context: context,
      barrierDismissible: false, // Dışarı tıklayınca kapanmasın
      builder: (ctx) => AlertDialog(
        backgroundColor: themeManager.cardBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        // Başlık: Sol tarafta yazı, Sağ tarafta Çarpı (X)
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Bilgilendirme!',
              style: TextStyle(color: themeManager.textColor),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(
                Icons.close,
                color: themeManager.isDarkMode ? Colors.white70 : Colors.grey,
              ),
              onPressed: () {
                // Çarpıya basınca sadece kapat, tercihi KAYDETME.
                // Bir sonraki girişte tekrar çıkar.
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        content: Text(
          'Bu sayfada, tüm testlerdeki favori ve yanlış yaptığınız soruları genel bir şekilde görüntüleyebilirsiniz. Her testin üzerine basılı tutarak, o teste ait favori ve yanlış soruları detaylı olarak görebilir, aynı zamanda testle ilgili bilgilere de ulaşabilirsiniz. İsterseniz testi sıfırlayarak, soruları baştan çözebilir ve ilerlemenizi yeniden takip edebilirsiniz.',
          style: TextStyle(fontSize: 15, color: themeManager.textColor),
        ),
        actions: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: themeManager.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () {
                // "exams_info_shown" ID'sini kaydet, bir daha çıkmasın
                _dismissedTopicInfo.add("exams_info_shown");
                globalStats.saveDismissedInfo();
                Navigator.pop(ctx);
              },
              child: const Text('Tekrar Gösterme'),
            ),
          ),
        ],
      ),
    );
  }
  // --- BİLGİLENDİRME KISMI BİTİŞ ---

  void _resetExam(ExamTest exam) {
    setState(() {
      final res = globalStats.examResults[exam.id]!;
      res.reset();
      globalStats.saveTestResult("", exam.id, res, false);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${exam.testName} verileri sıfırlandı.')),
    );
  }

  List<ReviewData> _getAllExamQuestions(bool isFavorite) {
    List<ReviewData> list = [];
    for (var exam in widget.appData.exams) {
      final res = globalStats.examResults[exam.id]!;
      for (int i = 0; i < exam.questions.length; i++) {
        if (isFavorite) {
          if (res.favoriteQuestions.contains(i)) {
            list.add(
              ReviewData(
                exam.questions[i],
                res.selectedOptions[i],
                exam.testName,
              ),
            );
          }
        } else {
          final userAns = res.selectedOptions[i];
          if (userAns != null && userAns != exam.questions[i].correctOption) {
            list.add(ReviewData(exam.questions[i], userAns, exam.testName));
          }
        }
      }
    }
    return list;
  }

  List<ReviewData> _getSingleExamQuestions(ExamTest exam, bool isFavorite) {
    List<ReviewData> list = [];
    final res = globalStats.examResults[exam.id]!;
    for (int i = 0; i < exam.questions.length; i++) {
      if (isFavorite) {
        if (res.favoriteQuestions.contains(i)) {
          list.add(
            ReviewData(
              exam.questions[i],
              res.selectedOptions[i],
              exam.testName,
            ),
          );
        }
      } else {
        final userAns = res.selectedOptions[i];
        if (userAns != null && userAns != exam.questions[i].correctOption) {
          list.add(ReviewData(exam.questions[i], userAns, exam.testName));
        }
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final stats = globalStats.getOverallExamStats();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Denemeler'),
        backgroundColor: themeManager.appBarColor,
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatsHeader(title: 'DENEMELER Genel Başarı Oranı', stats: stats),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.favorite_border,
                    label: 'Favori Sorularım',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Denemeler - Favoriler',
                            data: _getAllExamQuestions(true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.warning_amber_outlined,
                    label: 'Yanlış Çözdüklerim',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Denemeler - Yanlışlar',
                            data: _getAllExamQuestions(false),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final exam in widget.appData.exams)
              _TestListItem(
                testName: exam.testName,
                testId: exam.id,
                questions: exam.questions,
                topicId: null,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TestSolveScreen(exam: exam, testSet: exam),
                    ),
                  );
                  setState(() {});
                },
                onLongPress: () {
                  _showExamSummaryDialog(exam);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, [Color? color]) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: themeManager.isDarkMode
            ? Colors.white10
            : themeManager.primaryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: themeManager.textColor)),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color ?? themeManager.textColor,
            ),
          ),
        ],
      ),
    );
  }

  void _showExamSummaryDialog(ExamTest exam) {
    final result = globalStats.examResults[exam.id]!;

    final durationText = _formatDuration(result.timeSpentSeconds);
    // ORTALAMA SÜRE: Toplam Süre / Toplam Soru Sayısı
    final avgSeconds = result.totalQuestions == 0
        ? 0.0
        : result.timeSpentSeconds.toDouble() / result.totalQuestions.toDouble();
    final avgText = avgSeconds.toStringAsFixed(1).replaceAll('.', ',');

    final total = result.totalQuestions;
    final correct = result.correctCount;
    final wrong = result.wrongCount;
    final empty = result.emptyCount;
    final success = result.successRate;
    final successText = '%${success.toStringAsFixed(1).replaceAll('.', ',')}';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: themeManager.cardBackgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            'DENEMELER - ${exam.testName}',
            style: TextStyle(color: themeManager.textColor),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _summaryRow('Testte Harcanan Süre', durationText),
                _summaryRow('Ortalama Süre (sn)', avgText),
                _summaryRow('Soru Sayısı', total.toString()),
                _summaryRow('Doğru Sayısı', correct.toString(), Colors.green),
                _summaryRow('Yanlış Sayısı', wrong.toString(), Colors.red),
                _summaryRow('Boş Sayısı', empty.toString()),
                _summaryRow(
                  'Başarı Puanı',
                  successText,
                  success >= 50 ? Colors.green : Colors.red,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MiniTopButton(
                        icon: Icons.favorite,
                        label: 'Favoriler',
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuestionsReviewScreen(
                                title: '${exam.testName} - Favoriler',
                                data: _getSingleExamQuestions(exam, true),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniTopButton(
                        icon: Icons.warning,
                        label: 'Yanlışlar',
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuestionsReviewScreen(
                                title: '${exam.testName} - Yanlışlar',
                                data: _getSingleExamQuestions(exam, false),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.delete),
                    label: const Text('Denemeyi Sıfırla'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _resetExam(exam);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------- SORU İNCELEME EKRANI ----------------------

class QuestionsReviewScreen extends StatelessWidget {
  final String title;
  final List<ReviewData> data;

  const QuestionsReviewScreen({
    super.key,
    required this.title,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: themeManager.appBarColor,
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: data.isEmpty
            ? const Center(
                child: Text(
                  'Kayıt bulunamadı.',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: data.length,
                itemBuilder: (ctx, index) {
                  final item = data[index];
                  return _WhiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: themeManager.isDarkMode
                                ? Colors.white10
                                : themeManager.primaryColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            item.sourceTestName,
                            style: TextStyle(
                              color: themeManager.isDarkMode
                                  ? Colors.white70
                                  : themeManager.primaryColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.question.text,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 16,
                            color: themeManager.textColor,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...List.generate(item.question.options.length, (
                          optIndex,
                        ) {
                          final char = String.fromCharCode(65 + optIndex);
                          final text = item.question.options[optIndex];
                          final isCorrect = char == item.question.correctOption;
                          final isUserSelected = char == item.givenAnswer;

                          Color bgColor = themeManager.isDarkMode
                              ? Colors.black26
                              : Colors.white;
                          Color borderColor = Colors.grey.shade300;

                          if (isCorrect) {
                            bgColor = Colors.green.shade100;
                            borderColor = Colors.green;
                          } else if (isUserSelected) {
                            bgColor = Colors.red.shade100;
                            borderColor = Colors.red;
                          }

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: bgColor,
                              border: Border.all(color: borderColor),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  '$char)',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors
                                        .black87, // Seçenek metinleri her zaman koyu olsun (arka plan açık çünkü)
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    text,
                                    style: const TextStyle(
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                        if (item.question.solution.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(8),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: themeManager.isDarkMode
                                  ? Colors.black45
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Çözüm: ${item.question.solution}',
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: themeManager.textColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

// ---------------------- TEST ÇÖZÜM EKRANI ----------------------

class TestSolveScreen extends StatefulWidget {
  final Topic? topic;
  final ExamTest? exam;
  final TestSet testSet;

  const TestSolveScreen({
    super.key,
    this.topic,
    this.exam,
    required this.testSet,
  });

  @override
  State<TestSolveScreen> createState() => _TestSolveScreenState();
}

class _TestSolveScreenState extends State<TestSolveScreen> {
  int _index = 0;
  late TestResult _result;
  Timer? _timer;
  bool _showAnswer = false;

  @override
  void initState() {
    super.initState();
    if (widget.topic != null) {
      _result =
          globalStats.topicResults[widget.topic!.id]![widget.testSet.testName]!;
    } else {
      _result = globalStats.examResults[widget.exam!.id]!;
    }
    _startTimer();
  }

  void _startTimer() {
    if (!_result.isFullySolved) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _result.timeSpentSeconds++;
        });
        // Anlık süre kaydı (her 5 saniyede bir veya çıkışta yapmak daha iyi olabilir ama basitlik için anlık)
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Çıkarken son durumu kaydet (Süre vb)
    _saveProgress();
    super.dispose();
  }

  // Durumu kaydetme yardımcısı
  void _saveProgress() {
    if (widget.topic != null) {
      globalStats.saveTestResult(
        widget.topic!.id,
        widget.testSet.testName,
        _result,
        true,
      );
    } else {
      globalStats.saveTestResult("", widget.exam!.id, _result, false);
    }
  }

  void _select(String option) {
    if (_result.selectedOptions[_index] == option) {
      _result.selectedOptions.remove(_index);
    } else {
      _result.selectedOptions[_index] = option;
    }
    _showAnswer = false;
    _updateStats();
    _saveProgress(); // Seçim yapınca kaydet
  }

  void _updateStats() {
    int c = 0, w = 0, s = 0;
    for (int i = 0; i < widget.testSet.questions.length; i++) {
      final sel = _result.selectedOptions[i];
      if (sel != null) {
        s++;
        if (sel == widget.testSet.questions[i].correctOption)
          c++;
        else
          w++;
      }
    }
    setState(() {
      _result.correctCount = c;
      _result.wrongCount = w;
      _result.solvedQuestions = s;
      _result.emptyCount = _result.totalQuestions - s;
    });
    if (_result.isFullySolved) _timer?.cancel();
  }

  void _reset() {
    setState(() {
      _result.reset();
      _index = 0;
      _showAnswer = false;
    });
    _saveProgress(); // Sıfırlamayı kaydet
    _startTimer();
  }

  void _toggleFavorite() {
    setState(() {
      if (_result.favoriteQuestions.contains(_index))
        _result.favoriteQuestions.remove(_index);
      else
        _result.favoriteQuestions.add(_index);
    });
    _saveProgress(); // Favori değişimini kaydet
  }

  List<ReviewData> _getCurrentTestQuestions(bool isFavorite) {
    List<ReviewData> list = [];
    for (int i = 0; i < widget.testSet.questions.length; i++) {
      if (isFavorite) {
        if (_result.favoriteQuestions.contains(i)) {
          list.add(
            ReviewData(
              widget.testSet.questions[i],
              _result.selectedOptions[i],
              widget.testSet.testName,
            ),
          );
        }
      } else {
        final u = _result.selectedOptions[i];
        if (u != null && u != widget.testSet.questions[i].correctOption) {
          list.add(
            ReviewData(widget.testSet.questions[i], u, widget.testSet.testName),
          );
        }
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.testSet.questions[_index];
    final total = widget.testSet.questions.length;
    final title = widget.topic != null
        ? '${widget.topic!.topicName} - ${widget.testSet.testName}'
        : widget.exam!.testName;

    return Scaffold(
      body: Column(
        children: [
          // ÜST KISIM (BEYAZ/KOYU)
          Container(
            color: themeManager.cardBackgroundColor,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              bottom: 12,
              left: 16,
              right: 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: () {},
                      icon: Icon(
                        Icons.flag_outlined,
                        color: themeManager.primaryColor,
                      ),
                      label: Text(
                        'Bildir',
                        style: TextStyle(color: themeManager.primaryColor),
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          color: themeManager.primaryColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatDuration(_result.timeSpentSeconds),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: themeManager.textColor,
                          ),
                        ),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: () => _showResultDialog(),
                      icon: Icon(
                        Icons.check_circle_outline,
                        color: themeManager.primaryColor,
                      ),
                      label: Text(
                        'Bitir',
                        style: TextStyle(color: themeManager.primaryColor),
                      ),
                    ),
                  ],
                ),
                Divider(color: Colors.grey.shade300),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: themeManager.textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  q.text,
                  style: TextStyle(
                    fontSize: 16 * globalQuestionTextScale,
                    fontWeight: FontWeight.w500,
                    color: themeManager.textColor,
                  ),
                ),
                const SizedBox(height: 12),

                // İstatistik Satırı
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _result.favoriteQuestions.contains(_index)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: _result.favoriteQuestions.contains(_index)
                            ? Colors.red
                            : Colors.grey,
                      ),
                      onPressed: _toggleFavorite,
                    ),
                    Text(
                      '${_result.correctCount} Doğru',
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => _showPicker(total),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: themeManager.primaryColor),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_index + 1}/$total',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: themeManager.textColor,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_result.wrongCount} Yanlış',
                      style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _showSizeDialog,
                      child: Row(
                        children: [
                          Icon(
                            Icons.text_fields,
                            size: 16,
                            color: themeManager.textColor,
                          ),
                          Text(
                            ' Boyut',
                            style: TextStyle(color: themeManager.textColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ALT KISIM (RENKLİ/KOYU)
          Expanded(
            child: Container(
              color: themeManager.scaffoldBackgroundColor,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: List.generate(q.options.length, (i) {
                          final char = String.fromCharCode(65 + i);
                          final opt = q.options[i];
                          final isSel = _result.selectedOptions[_index] == char;

                          // ------ DÜZELTİLEN RENK MANTIĞI ------
                          bool isAnswered = _result.selectedOptions.containsKey(
                            _index,
                          );
                          Color bgColor = Colors.white;
                          Color borderColor = Colors.transparent;

                          if (_showAnswer || isAnswered) {
                            if (char == q.correctOption) {
                              bgColor = Colors.green.shade100;
                              borderColor = Colors.green;
                            } else if (isSel) {
                              bgColor = Colors.red.shade100;
                              borderColor = Colors.red;
                            }
                          } else if (isSel) {
                            bgColor = Colors.blue.shade50;
                            borderColor = Colors.blue;
                          }
                          // -------------------------------------

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: borderColor == Colors.transparent
                                    ? Colors.white
                                    : borderColor,
                                width: 2,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => setState(() => _select(char)),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      Text(
                                        '$char)',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize:
                                              18 * globalQuestionTextScale,
                                          color: Colors
                                              .black87, // Şıklar daima koyu
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          opt,
                                          style: TextStyle(
                                            fontSize:
                                                16 * globalQuestionTextScale,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),

                  // Navigasyon
                  Row(
                    children: [
                      Expanded(
                        child: _NavButton(
                          icon: Icons.arrow_back,
                          label: 'Önceki',
                          onTap: _index > 0
                              ? () => setState(() {
                                  _index--;
                                  _showAnswer = false;
                                })
                              : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _NavButton(
                          icon: Icons.arrow_forward,
                          label: 'Sonraki',
                          onTap: _index < total - 1
                              ? () => setState(() {
                                  _index++;
                                  _showAnswer = false;
                                })
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _NavButton(
                          icon: Icons.check,
                          label: 'Doğru Cevap',
                          onTap: () => setState(() => _showAnswer = true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _NavButton(
                          icon: Icons.edit,
                          label: 'Not Defterim',
                          onTap: () {},
                        ),
                      ),
                    ],
                  ),
                  if ((_showAnswer ||
                          _result.selectedOptions.containsKey(_index)) &&
                      q.solution.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Çözüm: ${q.solution}',
                        style: const TextStyle(color: Colors.black87),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSizeDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        double temp = globalQuestionTextScale;
        return StatefulBuilder(
          builder: (context, setD) => AlertDialog(
            backgroundColor: themeManager.cardBackgroundColor,
            title: Text(
              'Yazı Boyutu',
              style: TextStyle(color: themeManager.textColor),
            ),
            content: Slider(
              value: temp,
              min: 0.8,
              max: 1.5,
              onChanged: (v) => setD(() => temp = v),
              activeColor: themeManager.primaryColor,
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() => globalQuestionTextScale = temp);
                  Navigator.pop(ctx);
                },
                child: Text(
                  'Tamam',
                  style: TextStyle(color: themeManager.primaryColor),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPicker(int total) {
    showModalBottomSheet(
      context: context,
      backgroundColor: themeManager.cardBackgroundColor,
      builder: (ctx) => Container(
        height: 300,
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: total,
          itemBuilder: (c, i) {
            final isSel = _result.selectedOptions.containsKey(i);
            return InkWell(
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _index = i;
                  _showAnswer = false;
                });
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel
                      ? (_result.selectedOptions[i] ==
                                widget.testSet.questions[i].correctOption
                            ? Colors.green.shade300
                            : Colors.red.shade300)
                      : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showResultDialog() {
    _timer?.cancel();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: themeManager.cardBackgroundColor,
        title: Text(
          'Sonuç Tablosu',
          style: TextStyle(color: themeManager.textColor),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Doğru: ${_result.correctCount}',
              style: TextStyle(color: themeManager.textColor),
            ),
            Text(
              'Yanlış: ${_result.wrongCount}',
              style: TextStyle(color: themeManager.textColor),
            ),
            Text(
              'Boş: ${_result.emptyCount}',
              style: TextStyle(color: themeManager.textColor),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.favorite,
                    label: 'Favoriler',
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Bu Test - Favoriler',
                            data: _getCurrentTestQuestions(true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: _MiniTopButton(
                    icon: Icons.warning,
                    label: 'Yanlışlar',
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuestionsReviewScreen(
                            title: 'Bu Test - Yanlışlar',
                            data: _getCurrentTestQuestions(false),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: Text(
              'Çıkış',
              style: TextStyle(color: themeManager.primaryColor),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _reset();
            },
            child: Text(
              'Başa Dön',
              style: TextStyle(color: themeManager.primaryColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _NavButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        // Arka plan rengi temadan gelir
        backgroundColor: themeManager.cardBackgroundColor,
        foregroundColor: themeManager.textColor,
        // ÖNEMLİ: Material 3'ün otomatik grileşme/renklenme özelliğini kapatır:
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onPressed: onTap,
      icon: Icon(icon, color: themeManager.iconColor),
      label: Text(label),
    );
  }
}
// ---------------------------------------------------------------------------
//  YENİ VE DİNAMİK KONU ÖZETLERİ MODÜLÜ
// ---------------------------------------------------------------------------

/// 1. Veri Modeli
class KonuDetay {
  final String konuAdi;
  final List<KonuBolum> bolumler;

  KonuDetay({required this.konuAdi, required this.bolumler});

  factory KonuDetay.fromJson(Map<String, dynamic> json) {
    return KonuDetay(
      konuAdi: json['konu_adi'] ?? '',
      bolumler:
          (json['bolumler'] as List<dynamic>?)
              ?.map((item) => KonuBolum.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class KonuBolum {
  final String tip;
  final String? metin;
  final List<dynamic>? maddeler;

  KonuBolum({required this.tip, this.metin, this.maddeler});

  factory KonuBolum.fromJson(Map<String, dynamic> json) {
    return KonuBolum(
      tip: json['tip'] ?? 'paragraf',
      metin: json['metin'],
      maddeler: json['maddeler'],
    );
  }
}

/// Liste Elemanı Modeli (Dosya yolu ve Konu Adını tutar)
class KonuDosyaBilgisi {
  final String tamYol;
  final String konuAdi;

  KonuDosyaBilgisi({required this.tamYol, required this.konuAdi});
}

/// 2. Konu Listesi Ekranı (ARAMA ÇUBUĞU EKLENDİ 🔍)
class KonuOzetleriListScreen extends StatefulWidget {
  const KonuOzetleriListScreen({super.key});

  @override
  State<KonuOzetleriListScreen> createState() => _KonuOzetleriListScreenState();
}

class _KonuOzetleriListScreenState extends State<KonuOzetleriListScreen> {
  // Tüm konuları tutan ana liste
  List<KonuDosyaBilgisi> _tumKonular = [];
  // Arama sonucunda ekranda gösterilen filtrelenmiş liste
  List<KonuDosyaBilgisi> _filtrelenmisKonular = [];

  // Arama kutusunu kontrol eden araç
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _konulariYukle();
  }

  /// JSON dosyalarını tarayıp listeyi doldurur
  Future<void> _konulariYukle() async {
    try {
      final context = this.context;
      // 1. Manifest dosyasını oku
      final manifestContent = await DefaultAssetBundle.of(
        context,
      ).loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      // 2. Sadece konu özetlerini filtrele
      final dosyaYollari = manifestMap.keys
          .where(
            (String key) =>
                key.startsWith('assets/konu_ozeti/') && key.endsWith('.json'),
          )
          .toList();

      List<KonuDosyaBilgisi> geciciListe = [];

      // 3. Dosyaları oku ve başlıkları al
      for (String yol in dosyaYollari) {
        try {
          final content = await rootBundle.loadString(yol);
          final jsonMap = json.decode(content);
          final baslik = jsonMap['konu_adi'] ?? 'İsimsiz Konu';
          geciciListe.add(KonuDosyaBilgisi(tamYol: yol, konuAdi: baslik));
        } catch (e) {
          debugPrint("Dosya okuma hatası: $yol -> $e");
        }
      }

      // 4. Sırala
      geciciListe.sort((a, b) => a.tamYol.compareTo(b.tamYol));

      // 5. Listeleri güncelle
      if (mounted) {
        setState(() {
          _tumKonular = geciciListe;
          _filtrelenmisKonular = geciciListe; // Başlangıçta hepsi görünür
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// Arama kutusuna her harf yazıldığında çalışır
  void _aramaYap(String query) {
    setState(() {
      if (query.isEmpty) {
        // Arama boşsa hepsini göster
        _filtrelenmisKonular = _tumKonular;
      } else {
        // Arama doluysa başlığa göre filtrele (Küçük/büyük harf duyarsız)
        _filtrelenmisKonular = _tumKonular
            .where(
              (konu) =>
                  konu.konuAdi.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KONU ÖZETLERİ'),
        backgroundColor: themeManager.appBarColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: themeManager.scaffoldBackgroundColor,
        child: Column(
          children: [
            // --- ARAMA ÇUBUĞU KISMI ---
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              decoration: BoxDecoration(
                color: themeManager.appBarColor, // AppBar ile bütünlük sağlasın
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _aramaYap,
                style: const TextStyle(color: Colors.black),
                decoration: InputDecoration(
                  hintText: 'Konu Ara...',
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                  prefixIcon: Icon(
                    Icons.search,
                    color: themeManager.primaryColor,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            _aramaYap('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            // --- LİSTE KISMI ---
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : _errorMessage.isNotEmpty
                  ? Center(
                      child: Text(
                        'Hata: $_errorMessage',
                        style: const TextStyle(color: Colors.white),
                      ),
                    )
                  : _filtrelenmisKonular.isEmpty
                  ? const Center(
                      child: Text(
                        'Aradığınız kriterde konu bulunamadı.',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _filtrelenmisKonular.length,
                      itemBuilder: (context, index) {
                        final konu = _filtrelenmisKonular[index];
                        return _WhiteCard(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => KonuDetayPage(
                                  dosyaYolu: konu.tamYol,
                                  baslik: konu.konuAdi,
                                ),
                              ),
                            );
                          },
                          child: Row(
                            children: [
                              Icon(
                                Icons.library_books,
                                color: themeManager.primaryColor,
                                size: 32,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  konu.konuAdi,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: themeManager.textColor,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  KONU DETAY SAYFASI - DİJİTAL KAĞIT (PAPER) TASARIMI
// ---------------------------------------------------------------------------

class KonuDetayPage extends StatefulWidget {
  final String dosyaYolu;
  final String baslik;

  const KonuDetayPage({
    super.key,
    required this.dosyaYolu,
    required this.baslik,
  });

  @override
  State<KonuDetayPage> createState() => _KonuDetayPageState();
}

class _KonuDetayPageState extends State<KonuDetayPage> {
  Future<KonuDetay>? _konuDetayFuture;

  @override
  void initState() {
    super.initState();
    _konuDetayFuture = _jsonDosyasiniOku();
  }

  Future<KonuDetay> _jsonDosyasiniOku() async {
    final String jsonString = await rootBundle.loadString(widget.dosyaYolu);
    final Map<String, dynamic> jsonMap = json.decode(jsonString);
    return KonuDetay.fromJson(jsonMap);
  }

  @override
  Widget build(BuildContext context) {
    // Tema değişikliğini dinlemek için AnimatedBuilder (isteğe bağlı ama daha akıcı olur)
    return AnimatedBuilder(
      animation: themeManager,
      builder: (context, child) {
        return Scaffold(
          // 1. ZEMİN RENGİ: Karanlık modda SİYAH, Açık modda Pastel
          backgroundColor: themeManager.scaffoldBackgroundColor,

          appBar: AppBar(
            title: Text(widget.baslik, style: const TextStyle(fontSize: 16)),
            backgroundColor: themeManager.appBarColor,
            foregroundColor: Colors.white,
            iconTheme: const IconThemeData(color: Colors.white),
          ),

          body: FutureBuilder<KonuDetay>(
            future: _konuDetayFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(
                  child: CircularProgressIndicator(
                    color: themeManager.isDarkMode
                        ? Colors.white
                        : themeManager.primaryColor,
                  ),
                );
              } else if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Hata: ${snapshot.error}',
                    style: TextStyle(color: themeManager.textColor),
                  ),
                );
              } else if (!snapshot.hasData) {
                return Center(
                  child: Text(
                    'Veri bulunamadı.',
                    style: TextStyle(color: themeManager.textColor),
                  ),
                );
              }

              final veri = snapshot.data!;

              // --- DİJİTAL KAĞIT TASARIMI ---
              return Container(
                width: double.infinity,
                height: double.infinity,
                // Ekran kenarlarından boşluk bırak (Siyah zemin görünsün)
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  // Kağıt Rengi: Karanlıkta Gri, Aydınlıkta Beyaz
                  color: themeManager.cardBackgroundColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                // İçerik köşelerden taşmasın diye kırpıyoruz
                clipBehavior: Clip.hardEdge,
                child: ListView.builder(
                  padding: const EdgeInsets.all(20.0), // Kağıt içi boşluk
                  itemCount: veri.bolumler.length,
                  itemBuilder: (context, index) {
                    return _buildBolum(veri.bolumler[index]);
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBolum(KonuBolum bolum) {
    // Not: Burada metin renklerini (Colors.black vb.) değiştirmemize gerek kalmadı.
    // Çünkü zemin artık gri (dark mode) veya beyaz (light mode).
    // Siyah yazı gri zemin üzerinde gayet net okunur.

    switch (bolum.tip) {
      case 'baslik_1':
        return Padding(
          padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
          child: Text(
            bolum.metin ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.black, // Gri üzerinde Siyah (Net)
            ),
          ),
        );

      case 'baslik_2':
        return Container(
          margin: const EdgeInsets.only(top: 24.0, bottom: 12.0),
          padding: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                // Çizgi rengini temaya uyduralım
                color: themeManager.primaryColor,
                width: 2,
              ),
            ),
          ),
          child: Text(
            bolum.metin ?? '',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              // Koyu renkler gri üzerinde okunabilir
              color: themeManager.primaryColor.shade900,
            ),
          ),
        );

      case 'baslik_3_kirmizi':
        return Padding(
          padding: const EdgeInsets.only(top: 14.0, bottom: 8.0),
          child: Text(
            bolum.metin ?? '',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.redAccent, // Gri üzerinde Kırmızı (Net)
            ),
          ),
        );

      case 'paragraf':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Text(
            bolum.metin ?? '',
            style: const TextStyle(
              fontSize: 16,
              height: 1.5,
              color: Colors.black87, // Gri üzerinde Koyu Gri/Siyah
            ),
          ),
        );

      case 'liste':
        if (bolum.maddeler == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: bolum.maddeler!
              .map((madde) => _buildListeMaddesi(madde))
              .toList(),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildListeMaddesi(dynamic madde) {
    if (madde is String) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "• ",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: themeManager.primaryColor,
              ),
            ),
            Expanded(
              child: Text(
                madde,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.4,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
      );
    } else if (madde is Map) {
      String icerik = madde['metin'] ?? '';
      List<String> parcalar = icerik.split(':');

      if (parcalar.length > 1) {
        String baslikKismi = parcalar[0];
        String aciklamaKismi = parcalar.sublist(1).join(':');

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "• ",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: themeManager.primaryColor,
                ),
              ),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.black87,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(
                        text: "$baslikKismi:",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      TextSpan(text: aciklamaKismi),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      } else {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "• ",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: themeManager.primaryColor,
                ),
              ),
              Expanded(
                child: Text(
                  icerik,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
    return const SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------
//  PREMIUM ÜYELİK EKRANI (VITRIN TASARIMI)
// ---------------------------------------------------------------------------

class PremiumMembershipPage extends StatefulWidget {
  const PremiumMembershipPage({super.key});

  @override
  State<PremiumMembershipPage> createState() => _PremiumMembershipPageState();
}

class _PremiumMembershipPageState extends State<PremiumMembershipPage> {
  // Seçilen paketin indexi (Varsayılan olarak Yıllık paketi seçili getirelim: 3. index)
  int _selectedIndex = 3;

  // Paket Verileri
  final List<Map<String, dynamic>> _packages = [
    {
      "title": "1 Ay",
      "price": "44.99 ₺",
      "totalPrice": 44.99,
      "desc": "Denemek isteyenler için.",
      "badge": null,
    },
    {
      "title": "3 Ay",
      "price": "119.99 ₺",
      "totalPrice": 119.99,
      "desc": "Aylık ~40 ₺'ye gelir.",
      "badge": null,
    },
    {
      "title": "6 Ay",
      "price": "210.00 ₺",
      "totalPrice": 210.00,
      "desc": "Aylık 35 ₺'ye gelir.",
      "badge": "Fırsat",
    },
    {
      "title": "1 Yıl",
      "price": "300.00 ₺",
      "totalPrice": 300.00,
      "desc": "Aylık sadece 25 ₺!",
      "badge": "En Popüler", // En avantajlısı bu
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // AppBar yerine özel bir tasarım yapalım
      body: Column(
        children: [
          // --- ÜST KISIM (HEADER) ---
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              right: 16,
              bottom: 30,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  themeManager.primaryColor.shade800,
                  themeManager.primaryColor.shade400,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Column(
              children: [
                // Geri Butonu ve Başlık
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    const Text(
                      "PREMIUM'A GEÇ",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 40), // Ortalama için boşluk
                  ],
                ),
                const SizedBox(height: 20),
                const Icon(
                  Icons.workspace_premium,
                  color: Colors.white,
                  size: 60,
                ),
                const SizedBox(height: 10),
                const Text(
                  "Sınırsız Erişim & Reklamsız Deneyim",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Tüm ders uygulamalarımızda geçerli tek üyelik!",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),

          // --- İÇERİK KISMI ---
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Faydalar Listesi
                  const Text(
                    "Neler Kazanacaksın?",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  _buildFeatureRow("Tüm Reklamları Kaldır"),
                  _buildFeatureRow("Diğer Ders Uygulamalarına Erişim"),
                  _buildFeatureRow("Sınırsız Test Çözümü"),
                  _buildFeatureRow("Favori Sorular & İstatistikler"),

                  const SizedBox(height: 24),

                  // Paket Seçimi Başlığı
                  const Text(
                    "Sana Uygun Paketi Seç",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  // Paket Kartları
                  ...List.generate(_packages.length, (index) {
                    final p = _packages[index];
                    return _buildPackageCard(
                      index: index,
                      title: p['title'],
                      price: p['price'],
                      desc: p['desc'],
                      badge: p['badge'],
                    );
                  }),

                  const SizedBox(height: 20),

                  // Satın Al Butonu
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: themeManager.primaryColor.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 5,
                      ),
                      onPressed: () {
                        // BURAYA İLERİDE SATIN ALMA KODLARI GELECEK
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "${_packages[_selectedIndex]['title']} paketi seçildi. Satın alma yakında aktif!",
                            ),
                          ),
                        );
                      },
                      child: const Text(
                        "ABONELİĞİ BAŞLAT",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // Alt Linkler (Zorunlu)
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () {},
                        child: const Text(
                          "Satın Alımları Geri Yükle",
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                      const Text("|", style: TextStyle(color: Colors.grey)),
                      TextButton(
                        onPressed: () {},
                        child: const Text(
                          "Gizlilik & Şartlar",
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Özellik Satırı Widget'ı (Tik işareti + Yazı)
  Widget _buildFeatureRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.green.shade100,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, size: 16, color: Colors.green),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // Paket Kartı Widget'ı
  Widget _buildPackageCard({
    required int index,
    required String title,
    required String price,
    required String desc,
    String? badge,
  }) {
    bool isSelected = _selectedIndex == index;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isSelected
                  ? themeManager.primaryColor.shade50
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? themeManager.primaryColor.shade700
                    : Colors.grey.shade300,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: themeManager.primaryColor.withOpacity(0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : [],
            ),
            child: Row(
              children: [
                // Radio Buton Görünümü
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: isSelected
                      ? themeManager.primaryColor.shade700
                      : Colors.grey,
                ),
                const SizedBox(width: 16),
                // Yazılar
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isSelected ? Colors.black : Colors.black87,
                        ),
                      ),
                      Text(
                        desc,
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected
                              ? themeManager.primaryColor.shade900
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                // Fiyat
                Text(
                  price,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isSelected
                        ? themeManager.primaryColor.shade700
                        : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          // "En Popüler" Etiketi
          if (badge != null)
            Positioned(
              top: -8,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// YENİ: ONBOARDING EKRANI (İKON VE RESİM DESTEKLİ HİBRİT YAPI)
// ---------------------------------------------------------------------------

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onOnboardingComplete;
  const OnboardingScreen({super.key, required this.onOnboardingComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Tanıtım Kartları Verisi
  // Hem 'icon' hem de 'image' alabilecek şekilde dynamic yaptık.
  final List<Map<String, dynamic>> slides = [
    // 1. KART: HOŞ GELDİNİZ (İKONLU)
    {
      'title': 'Hoş Geldiniz!',
      'description':
          'KPSS Tarih Soru Bankası ile hedeflerinize ulaşmaya başlayın. Tüm özelliklere ücretsiz bir şekilde erişebilirsiniz. İşte temel özellikler:',
      'icon': Icons.school, // Bu kartta ikon kullanılacak
    },
    // 2. KART: KONU TESTLERİ (RESİMLİ)
    {
      'image': 'assets/onboarding/konu_testleri_ok.jpg',
      'title': 'Konu Testleri Kısmına Hoş Geldiniz!',
      'description':
          "Konu Testleri kısmında yaklaşık 2000'e yakın soruyla her bir konu özelinde bilgilerinizin pekişmesi için sorular hazırladık. Konu eksiklerinize dair sorular için her zaman uğrayabilirsiniz.",
    },
    // 3. KART: DENEMELER
    {
      'image': 'assets/onboarding/denemeler_ok.jpg',
      'title': '50 farklı deneme ile kendinizi test edin!',
      'description':
          "Karışık konulara ait tam Deneme Sınavlarını çözerek kendinizi sınav ortamında test edin ve zaman yönetiminizi geliştirin.",
    },
    // 4. KART: HAP BİLGİLER
    {
      'image': 'assets/onboarding/hap_bilgiler_ok.jpg',
      'title': 'Hap Bilgilere hoş geldiniz!',
      'description':
          "Soru-cevap tarzında hazırlanan kısa ve kritik bilgilerle konuları eksiksiz bir şekilde tamamlayın ve ezberinizi güçlendirin.",
    },
    // 5. KART: SÖZLÜK
    {
      'image': 'assets/onboarding/sozluk_ok.jpg',
      'title': 'KPSS Tarih Sözlüğüne hoş geldiniz!',
      'description':
          "KPSS Tarih için 400'den fazla kelime ve anlamını pekiştirerek sorularda anlamadığınız kelime kalmayacak.",
    },
    // 6. KART: KONU ÖZETİ
    {
      'image': 'assets/onboarding/konu_ozeti_ok.jpg',
      'title': 'Konu eksiğine son!',
      'description':
          "Detaylı ve güzel bir arayüz ile 59 farklı alt başlığa ait konu özetlerine istediğiniz zaman erişebilir, konu eksiklerinizi tamamen bitirebilirsiniz.",
    },
    // 7. KART: PUAN VER
    {
      'image': 'assets/onboarding/puan_ver_ok.jpg',
      'title': 'En Önemli Şey Düşünceleriniz!',
      'description':
          "Uygulamamızı beğendiyseniz puan vermeyi, varsa görüşlerinizi ve geliştirilmesini istediğiniz konular hakkındaki fikirlerinizi yorumlarda belirterek bize destek olabilirsiniz.",
    },
    // 8. KART: PREMIUM
    {
      'image': 'assets/onboarding/premium_ok.jpg',
      'title': 'Reklamlardan sıkıldınız mı?',
      'description':
          "Reklamları görmek istemiyorsanız, düşük fiyatlı premium üyeliğimizden faydalanabilirsiniz. Premium üyemiz olduğunuzda diğer tüm uygulamalarımızdan da reklamsız bir şekilde yararlanacaksınız. Farklı premium seçeneklerini deneyebilir, diğer uygulamalarımızdan da reklam görmeden yararlanabilirsiniz!",
    },
  ];

  void _finishOnboarding() async {
    // 1. SharedPreferences'a tamamlandı bilgisini kaydet.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_tamamlandi', true);

    // 2. Ana uygulamaya geri dön.
    widget.onOnboardingComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: themeManager.primaryColor.shade700,
      body: SafeArea(
        child: Column(
          children: [
            // ÜST KISIM: RESİM/İKON VE METİNLER
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: slides.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemBuilder: (context, index) {
                  final slide = slides[index];
                  // Bu kartta resim var mı kontrol edelim
                  final hasImage = slide.containsKey('image');

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24.0,
                      vertical: 16.0,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Görsel veya İkon Alanı
                        Expanded(
                          flex: 3,
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                              // Sadece resim varsa gölge ekleyelim
                              boxShadow: hasImage
                                  ? [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 10,
                                        offset: const Offset(0, 5),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: hasImage
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: Image.asset(
                                      slide['image'] as String,
                                      fit: BoxFit.contain,
                                    ),
                                  )
                                : Icon(
                                    slide['icon'] as IconData,
                                    size: 120, // İkon boyutu
                                    color: Colors.white,
                                  ),
                          ),
                        ),

                        const SizedBox(height: 30),

                        // Başlık
                        Text(
                          slide['title'] as String,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Açıklama
                        Expanded(
                          flex: 2,
                          child: SingleChildScrollView(
                            child: Text(
                              slide['description'] as String,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.white70,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // ALT KISIM: BUTONLAR VE NOKTALAR
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Atla Butonu
                  TextButton(
                    onPressed: _finishOnboarding,
                    child: const Text(
                      'ATLA',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ),

                  // Noktalar (Sayfa Göstergesi)
                  Row(
                    children: List.generate(
                      slides.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        height: 8,
                        width: _currentPage == i ? 24 : 8,
                        decoration: BoxDecoration(
                          color: _currentPage == i
                              ? Colors.white
                              : Colors.white30,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),

                  // İleri / Başla Butonu
                  _currentPage == slides.length - 1
                      ? ElevatedButton(
                          onPressed: _finishOnboarding,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: themeManager.primaryColor.shade700,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          child: const Text(
                            'BAŞLA',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : TextButton(
                          onPressed: () {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeIn,
                            );
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Text(
                                'İLERİ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(
                                Icons.arrow_forward,
                                color: Colors.white,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
