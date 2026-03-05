import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:convert';
import 'dart:io';

// Importações do Firebase
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart'; // Ficheiro gerado pelo FlutterFire

// Importações para o cache local
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

// Modelos para as perguntas iniciais dinâmicas
abstract class PerguntaInicial {
  final String pergunta;
  PerguntaInicial({required this.pergunta});
}

class PerguntaTextoLivre extends PerguntaInicial {
  PerguntaTextoLivre({required super.pergunta});
}

class PerguntaComOpcoes extends PerguntaInicial {
  final List<String> opcoes;
  PerguntaComOpcoes({required super.pergunta, required this.opcoes});
}


class InfoItem {
  final String descricao;
  final String? imagemLocal;

  InfoItem({required this.descricao, this.imagemLocal});
}

class HistoricoOrcamentosService {
  Future<File> _getHistoricoFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/historico_orcamentos.json');
  }

  Future<List<Map<String, dynamic>>> carregarHistorico() async {
    final file = await _getHistoricoFile();
    if (!await file.exists()) {
      return [];
    }

    final conteudo = await file.readAsString();
    if (conteudo.trim().isEmpty) {
      return [];
    }

    final data = json.decode(conteudo);
    if (data is! List) {
      return [];
    }

    return data
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> _salvarHistorico(List<Map<String, dynamic>> registros) async {
    final file = await _getHistoricoFile();
    await file.writeAsString(json.encode(registros));
  }

  Future<String> registrarOrcamento({
    required Map<String, dynamic> dados,
    required bool finalizado,
    required bool enviadoFirebase,
  }) async {
    final registros = await carregarHistorico();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final agora = DateTime.now().toIso8601String();

    registros.insert(0, {
      'id': id,
      'criadoEm': agora,
      'atualizadoEm': agora,
      'finalizado': finalizado,
      'enviadoFirebase': enviadoFirebase,
      'dados': dados,
    });

    await _salvarHistorico(registros);
    return id;
  }

  Future<void> atualizarRegistro({
    required String id,
    Map<String, dynamic>? dados,
    bool? finalizado,
    bool? enviadoFirebase,
    String? erroEnvio,
  }) async {
    final registros = await carregarHistorico();
    final index = registros.indexWhere((item) => item['id'] == id);
    if (index == -1) return;

    final atual = registros[index];
    if (dados != null) {
      atual['dados'] = dados;
    }
    if (finalizado != null) {
      atual['finalizado'] = finalizado;
    }
    if (enviadoFirebase != null) {
      atual['enviadoFirebase'] = enviadoFirebase;
    }

    if (erroEnvio != null && erroEnvio.isNotEmpty) {
      atual['erroEnvio'] = erroEnvio;
    } else {
      atual.remove('erroEnvio');
    }

    atual['atualizadoEm'] = DateTime.now().toIso8601String();
    registros[index] = atual;
    await _salvarHistorico(registros);
  }

  Future<List<Map<String, dynamic>>> carregarPendentesEnvio() async {
    final registros = await carregarHistorico();
    return registros
        .where((item) => item['enviadoFirebase'] != true)
        .toList();
  }
}

class LimitService {
// ... (código existente da classe LimitService)
  static const int maxOrcamentos = 25;
  static const int maxSincronizacoes = 1;

  late SharedPreferences _prefs;

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    await _verificarResetDiario();
  }

  String _getHoje() {
    return DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  Future<void> _verificarResetDiario() async {
    final hoje = _getHoje();
    final dataSalva = _prefs.getString('limites_data');

    if (dataSalva != hoje) {
      await _prefs.setString('limites_data', hoje);
      await _prefs.setInt('orcamentos_feitos', 0);
      await _prefs.setInt('sincronizacoes_feitas', 0);
    }
  }

  Future<bool> podeFazerOrcamento() async {
    await _init();
    return (_prefs.getInt('orcamentos_feitos') ?? 0) < maxOrcamentos;
  }

  Future<void> registrarOrcamento() async {
    await _init();
    int atual = _prefs.getInt('orcamentos_feitos') ?? 0;
    await _prefs.setInt('orcamentos_feitos', atual + 1);
  }

  Future<int> getContagemOrcamentos() async {
    await _init();
    return _prefs.getInt('orcamentos_feitos') ?? 0;
  }

  Future<bool> podeSincronizar() async {
    await _init();
    return (_prefs.getInt('sincronizacoes_feitas') ?? 0) < maxSincronizacoes;
  }

  Future<void> registrarSincronizacao() async {
    await _init();
    int atual = _prefs.getInt('sincronizacoes_feitas') ?? 0;
    await _prefs.setInt('sincronizacoes_feitas', atual + 1);
  }

  Future<int> getContagemSincronizacoes() async {
    await _init();
    return _prefs.getInt('sincronizacoes_feitas') ?? 0;
  }
}

Future<void> enviarRelatorioParaFirebase({
  required Map<String, dynamic> dadosRelatorio,
  required String escopoEmailTexto,
}) async {
  final firestore = FirebaseFirestore.instance;

  await firestore.collection('relatorios').add({
    ...dadosRelatorio,
    'criadoEm': FieldValue.serverTimestamp(),
  });

  await firestore.collection('EscopoEmail').add({
    'to': dadosRelatorio['destinatario'],
    'orcamentistaEmail': dadosRelatorio['orcamentistaEmail'],
    'escopoTexto': escopoEmailTexto,
    'template': {
      'name': 'relatorioOrcamento',
      'data': {
        'orcamentistaEmail': dadosRelatorio['orcamentistaEmail'],
        'escopoTexto': escopoEmailTexto,
      }
    },
    'criadoEm': FieldValue.serverTimestamp(),
  });
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
// ... (código existente da classe MyApp)
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Diagnóstico de Equipamentos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',

        // 🌈 Paleta vibrante
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
          secondary: const Color(0xFFEE7752),
          tertiary: const Color(0xFF23A6D5),
        ),

        // 📝 Tipografia premium
        textTheme: ThemeData.light().textTheme.copyWith(
          headlineLarge: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D1B2A),
            letterSpacing: -1,
          ),
          headlineSmall: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1B263B),
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Color(0xFF33475B),
          ),
          bodyMedium: const TextStyle(
            fontSize: 16,
            color: Color(0xFF1C1C1C),
            height: 1.6,
          ),
          labelLarge: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),

        // 🌌 Fundo elegante
        scaffoldBackgroundColor: const Color(0xFFF4F6F9),

        // 🔝 AppBar clean
        appBarTheme: AppBarTheme(
          elevation: 0,
          centerTitle: true,
          backgroundColor: Colors.white.withOpacity(0.95),
          foregroundColor: Colors.teal.shade900,
          titleTextStyle: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D1B2A),
            fontFamily: 'Roboto',
          ),
          shadowColor: Colors.black.withOpacity(0.04),
        ),

        // 🃏 Cards modernos translúcidos
        cardTheme: CardThemeData(
          elevation: 10,
          shadowColor: Colors.black.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
          color: Colors.white.withOpacity(0.9),
        ),

        // 🔘 Botões elegantes (sem gradiente forçado)
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(40),
            ),
            elevation: 6,
            shadowColor: Colors.black.withOpacity(0.25),
            textStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
        ),

        // ✏️ Inputs estilo fintech
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.grey.shade300, width: 1.2),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            borderSide: BorderSide(color: Colors.teal, width: 2),
          ),
          hintStyle: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 15,
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
// ... (código existente da classe AuthGate)
  const AuthGate({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoginPage();
        }
        return const PerguntasLivresScreen();
      },
    );
  }
}

class LoginPage extends StatefulWidget {
// ... (código existente da classe LoginPage)
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
// ... (código existente da classe _LoginPageState)
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _signIn() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });
      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('last_auth_validation_timestamp', DateTime.now().millisecondsSinceEpoch);
      } on FirebaseAuthException catch (e) {
        String errorMessage = 'Ocorreu um erro.';
        if (e.code == 'user-not-found' || e.code == 'wrong-password' || e.code == 'invalid-credential') {
          errorMessage = 'E-mail ou palavra-passe incorretos.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.teal.shade200, Colors.teal.shade500],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Card(
              elevation: 12,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/logo.png',
                        height: 80,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.shield_rounded, size: 64, color: Theme.of(context).primaryColor),
                      ),
                      const SizedBox(height: 24),
                      Text('Acesso ao Sistema', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text('Por favor, insira suas credenciais.', style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _emailController,
                        decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.email_outlined)),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) => (value == null || value.isEmpty) ? 'Por favor, insira o e-mail.' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        decoration: const InputDecoration(labelText: 'Palavra-passe', prefixIcon: Icon(Icons.lock_outline)),
                        obscureText: true,
                        validator: (value) => (value == null || value.isEmpty) ? 'Por favor, insira a palavra-passe.' : null,
                      ),
                      const SizedBox(height: 32),
                      _isLoading
                          ? const CircularProgressIndicator()
                          : SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.login),
                          onPressed: _signIn,
                          label: const Text('ENTRAR'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DataService {
// ... (código existente da classe DataService)
  Future<File> get _localPrecosFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/precos.json');
  }

  Future<File> get _localPerguntasIniciaisFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/perguntas_iniciais.json');
  }

  Future<String> importarPrecosDoFirebase() async {
    final precosCollection = FirebaseFirestore.instance.collection('precos');
    final snapshot = await precosCollection.get();

    if (snapshot.docs.isEmpty) {
      throw Exception('Nenhum preço encontrado no Firebase.');
    }

    final List<Map<String, dynamic>> listaDePrecos = snapshot.docs.map((doc) {
      final data = doc.data();
      return {
        'selecionado': data['selecionado'],
        'precos': data['precos'],
      };
    }).toList();

    final Map<String, dynamic> jsonData = {'Planilha1': listaDePrecos};
    final file = await _localPrecosFile;
    await file.writeAsString(json.encode(jsonData));

    return 'Preços atualizados com sucesso: ${snapshot.docs.length} itens importados.';
  }

  Future<String> importarPerguntasIniciaisDoFirebase() async {
    final collectionRef = FirebaseFirestore.instance.collection('perguntas_iniciais');
    final snapshot = await collectionRef.get();

    if (snapshot.docs.isEmpty) {
      throw Exception("Nenhum documento de configuração encontrado para importar.");
    }

    final doc = snapshot.docs.first;
    final jsonData = doc.data();

    final file = await _localPerguntasIniciaisFile;
    await file.writeAsString(json.encode(jsonData));

    return 'Perguntas iniciais atualizadas com sucesso.';
  }

  Future<Map<String, double>> carregarPrecosJson() async {
    String jsonString;

    final file = await _localPrecosFile;
    if (await file.exists()) {
      print("Lendo preços do arquivo local (importado do Firebase)...");
      jsonString = await file.readAsString();
    }
    else {
      print("Arquivo local não encontrado. Lendo preços dos assets...");
      jsonString = await rootBundle.loadString('assets/precos.json');
    }

    final Map<String, dynamic> data = json.decode(jsonString);
    final mapaPrecos = <String, double>{};
    final String primeiraAba = data.keys.first;
    final List<dynamic> linhas = data[primeiraAba];

    for (var row in linhas) {
      if (row is Map<String, dynamic>) {
        final item = row['selecionado']?.toString();
        final precoValor = row['precos'];

        if (item != null && item.isNotEmpty && precoValor != null) {
          double? preco;
          if (precoValor is num) {
            preco = precoValor.toDouble();
          } else {
            preco = double.tryParse(precoValor.toString().replaceAll(',', '.'));
          }

          if (preco != null) {
            mapaPrecos[item] = preco;
          }
        }
      }
    }

    print("${mapaPrecos.length} itens carregados");
    return mapaPrecos;
  }

  Future<List<PerguntaInicial>> carregarPerguntasIniciais() async {
    try {
      final file = await _localPerguntasIniciaisFile;
      if (await file.exists()) {
        print("Lendo perguntas iniciais do arquivo local...");
        final jsonString = await file.readAsString();
        final Map<String, dynamic> data = json.decode(jsonString);
        return _parsePerguntasIniciaisData(data);
      } else {
        print("Arquivo local de perguntas não encontrado. Buscando do Firebase pela primeira vez...");
        return await _fetchAndCachePerguntasIniciais();
      }
    } catch (e) {
      print("Erro ao carregar perguntas iniciais (local ou Firebase): $e. Usando fallback local XLSX.");
      final perguntasFallback = await carregarPerguntasLivresDoXLSX();
      return perguntasFallback.map((p) => PerguntaTextoLivre(pergunta: p)).toList();
    }
  }

  List<PerguntaInicial> _parsePerguntasIniciaisData(Map<String, dynamic> data) {
    final List<String> ordem = List<String>.from(data['ordem'] ?? []);
    final Map<String, dynamic> perguntasMap = data['perguntas'] ?? {};

    final List<PerguntaInicial> resultado = [];
    for (String perguntaTitulo in ordem) {
      final Map<String, dynamic>? config = perguntasMap[perguntaTitulo];
      if (config != null) {
        if (config['tipo'] == 'texto_livre') {
          resultado.add(PerguntaTextoLivre(pergunta: perguntaTitulo));
        } else if (config['tipo'] == 'opcoes' && config['opcoes'] is List) {
          resultado.add(PerguntaComOpcoes(
              pergunta: perguntaTitulo,
              opcoes: List<String>.from(config['opcoes'])
          ));
        }
      }
    }
    return resultado;
  }

  Future<List<PerguntaInicial>> _fetchAndCachePerguntasIniciais() async {
    final collectionRef = FirebaseFirestore.instance.collection('perguntas_iniciais');
    final snapshot = await collectionRef.get();

    if (snapshot.docs.isEmpty) {
      throw Exception("Nenhum documento de configuração encontrado em 'perguntas_iniciais'.");
    }

    final doc = snapshot.docs.first;
    final data = doc.data();

    final file = await _localPerguntasIniciaisFile;
    await file.writeAsString(json.encode(data));
    print("Perguntas iniciais salvas no cache local.");

    return _parsePerguntasIniciaisData(data);
  }

  Future<List<String>> carregarPerguntasLivresDoXLSX() async {
    final data = await rootBundle.load('assets/perguntas_livres.xlsx');
    final excel = Excel.decodeBytes(data.buffer.asUint8List());
    final sheet = excel.tables[excel.tables.keys.first]!;
    final out = <String>[];
    for (final row in sheet.rows) {
      if (row.isNotEmpty && row.first != null) {
        final v = row.first!.value.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    }
    return out;
  }

  Future<List<String>> carregarPerguntas() async {
    final data = await rootBundle.load('assets/perguntas.xlsx');
    final excel = Excel.decodeBytes(data.buffer.asUint8List());
    final sheet = excel.tables[excel.tables.keys.first]!;
    final out = <String>[];
    for (final row in sheet.rows) {
      if (row.isNotEmpty && row.first != null) {
        final v = row.first!.value.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    }
    return out;
  }

  Future<Map<String, List<String>>> carregarItens() async {
    final data = await rootBundle.load('assets/itens.xlsx');
    final excel = Excel.decodeBytes(data.buffer.asUint8List());
    final sheet = excel.tables[excel.tables.keys.first]!;
    if (sheet.rows.isEmpty) return {};

    final header = sheet.rows.first
        .map((c) => (c?.value?.toString() ?? '').trim())
        .toList();

    final itens = <String, List<String>>{};
    for (int c = 0; c < header.length; c++) {
      final pergunta = header[c];
      if (pergunta.isEmpty) continue;
      final options = <String>[];
      for (int r = 1; r < sheet.rows.length; r++) {
        final cell = (c < sheet.rows[r].length) ? sheet.rows[r][c] : null;
        final v = cell?.value?.toString().trim() ?? '';
        if (v.isNotEmpty && !options.contains(v)) options.add(v);
      }
      itens[pergunta] = options;
    }
    return itens;
  }

  Future<Map<String, Set<String>>> carregarVinculosSemHeader() async {
    final data = await rootBundle.load('assets/vinculos.xlsx');
    final excel = Excel.decodeBytes(data.buffer.asUint8List());
    final sheet = excel.tables[excel.tables.keys.first]!;
    final mapa = <String, Set<String>>{};

    for (final row in sheet.rows) {
      if (row.isEmpty) continue;
      final chave = row.first?.value?.toString().trim() ?? '';
      if (chave.isEmpty) continue;

      final setVals = mapa.putIfAbsent(chave, () => <String>{});
      for (int c = 1; c < row.length; c++) {
        final v = row[c]?.value?.toString().trim() ?? '';
        if (v.isNotEmpty) setVals.add(v);
      }
    }
    return mapa;
  }

  Future<Map<String, InfoItem>> carregarInformacoesRespostas() async {
    final mapa = <String, InfoItem>{};
    try {
      final data = await rootBundle.load('assets/informacoes.xlsx');
      final excel = Excel.decodeBytes(data.buffer.asUint8List());
      final sheet = excel.tables[excel.tables.keys.first]!;

      for (int i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.length >= 2 && row[0] != null && row[1] != null) {
          final item = row[0]!.value.toString().trim();
          final descricao = row[1]!.value.toString().trim();
          final imagemLocal = (row.length > 2 && row[2] != null)
              ? row[2]!.value.toString().trim()
              : null;

          if (item.isNotEmpty && descricao.isNotEmpty) {
            mapa[item] = InfoItem(descricao: descricao, imagemLocal: imagemLocal);
          }
        }
      }
    } catch (e) {
      print("Arquivo 'informacoes.xlsx' não encontrado ou com erro: $e.");
    }
    return mapa;
  }

  Future<Map<String, InfoItem>> carregarInformacoesPerguntas() async {
    final mapa = <String, InfoItem>{};
    try {
      final data = await rootBundle.load('assets/informacoes_perguntas.xlsx');
      final excel = Excel.decodeBytes(data.buffer.asUint8List());
      final sheet = excel.tables[excel.tables.keys.first]!;

      for (int i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.length >= 2 && row[0] != null && row[1] != null) {
          final pergunta = row[0]!.value.toString().trim();
          final descricao = row[1]!.value.toString().trim();
          final imagemLocal = (row.length > 2 && row[2] != null)
              ? row[2]!.value.toString().trim()
              : null;

          if (pergunta.isNotEmpty && descricao.isNotEmpty) {
            mapa[pergunta] = InfoItem(descricao: descricao, imagemLocal: imagemLocal);
          }
        }
      }
    } catch (e) {
      print("Arquivo 'informacoes_perguntas.xlsx' não encontrado ou com erro: $e.");
    }
    return mapa;
  }

  Future<List<InfoItem>> carregarInformacoesIniciais() async {
    final List<InfoItem> informacoes = [];
    try {
      final data = await rootBundle.load('assets/informacao_inicial.xlsx');
      final excel = Excel.decodeBytes(data.buffer.asUint8List());
      final sheet = excel.tables[excel.tables.keys.first]!;

      if (sheet.rows.length < 2) return informacoes;

      final header = sheet.rows.first.map((cell) => cell?.value.toString().trim().toLowerCase() ?? '').toList();
      final inicialIndex = header.indexOf('inicial');
      final imagemIndex = header.indexOf('imagem_inicial');

      if (inicialIndex == -1) return informacoes;

      for (int i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.length <= inicialIndex || row[inicialIndex] == null) continue;

        final descricao = row[inicialIndex]?.value.toString().trim() ?? '';
        if (descricao.isEmpty) continue;

        final imagemLocal = (imagemIndex != -1 && row.length > imagemIndex && row[imagemIndex] != null)
            ? row[imagemIndex]!.value.toString().trim()
            : null;

        informacoes.add(InfoItem(descricao: descricao, imagemLocal: imagemLocal));
      }
    } catch (e) {
      print("Arquivo 'informacao_inicial.xlsx' não encontrado ou com erro: $e.");
    }
    return informacoes;
  }
}

class PerguntasLivresScreen extends StatefulWidget {
// ... (código existente da classe PerguntasLivresScreen)
  const PerguntasLivresScreen({super.key});

  @override
  State<PerguntasLivresScreen> createState() => _PerguntasLivresScreenState();
}

class _PerguntasLivresScreenState extends State<PerguntasLivresScreen> {
// ... (código existente da classe _PerguntasLivresScreenState)
  final _formKey = GlobalKey<FormState>();
  final _service = DataService();
  final _limitService = LimitService();
  final _historicoService = HistoricoOrcamentosService();
  bool _isLoading = true;
  bool _isImporting = false;
  String _limitStatus = '';

  List<PerguntaInicial> _perguntasIniciais = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String?> _respostasDeOpcoes = {};

  @override
  void initState() {
    super.initState();
    _carregarDadosIniciais();
  }

  Future<void> _carregarDadosIniciais() async {
    await _atualizarStatusLimite();
    await _sincronizarHistoricoPendentes();
    await _carregarPerguntas();
  }

  Future<void> _sincronizarHistoricoPendentes() async {
    final pendentes = await _historicoService.carregarPendentesEnvio();
    if (pendentes.isEmpty) return;

    int enviados = 0;

    for (final registro in pendentes) {
      final id = registro['id']?.toString();
      final dados = registro['dados'];
      if (id == null || dados is! Map) {
        continue;
      }

      final dadosMap = Map<String, dynamic>.from(dados);
      final escopo = dadosMap['escopoEmailTexto']?.toString() ?? '';
      if (escopo.isEmpty) {
        continue;
      }

      try {
        await enviarRelatorioParaFirebase(
          dadosRelatorio: dadosMap,
          escopoEmailTexto: escopo,
        );
        enviados += 1;
        await _historicoService.atualizarRegistro(
          id: id,
          enviadoFirebase: true,
          erroEnvio: '',
        );
      } catch (e) {
        await _historicoService.atualizarRegistro(
          id: id,
          erroEnvio: e.toString(),
        );
      }
    }

    if (mounted && enviados > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$enviados orçamento(s) pendente(s) enviado(s) ao Firebase.')),
      );
    }
  }

  Future<void> _atualizarStatusLimite() async {
    final orcamentos = await _limitService.getContagemOrcamentos();
    final sincronizacoes = await _limitService.getContagemSincronizacoes();
    if(mounted) {
      setState(() {
        _limitStatus = 'Orçamentos (hoje): $orcamentos/${LimitService.maxOrcamentos} | Sincronizações (hoje): $sincronizacoes/${LimitService.maxSincronizacoes}';
      });
    }
  }

  Future<void> _carregarPerguntas() async {
    if(!mounted) return;
    setState(() => _isLoading = true);
    try {
      _perguntasIniciais = await _service.carregarPerguntasIniciais();
      _controllers.clear();
      _respostasDeOpcoes.clear();
      for (var p in _perguntasIniciais) {
        if (p is PerguntaTextoLivre) {
          _controllers[p.pergunta] = TextEditingController();
        } else if (p is PerguntaComOpcoes) {
          _respostasDeOpcoes[p.pergunta] = null;
        }
      }
    } catch (e) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar perguntas iniciais: $e')),
        );
      }
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSync() async {
    setState(() => _isImporting = true);
    String? precosResultado, perguntasResultado;
    String? erro;

    try {
      precosResultado = await _service.importarPrecosDoFirebase();
    } catch (e) {
      erro = 'Erro ao importar preços: $e';
    }

    try {
      perguntasResultado = await _service.importarPerguntasIniciaisDoFirebase();
    } catch (e) {
      final erroPerguntas = 'Erro ao importar perguntas: $e';
      erro = erro == null ? erroPerguntas : '$erro\n$erroPerguntas';
    }

    if (mounted) {
      if (erro != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(erro), backgroundColor: Colors.red),
        );
      } else {
        await _limitService.registrarSincronizacao();
        await _atualizarStatusLimite();
        final successMessage = '${precosResultado ?? ''}\n${perguntasResultado ?? ''}'.trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMessage), backgroundColor: Colors.green),
        );
        await _carregarPerguntas();
      }
      setState(() => _isImporting = false);
    }
  }

  Future<void> _confirmarESincronizar() async {
    if (!await _limitService.podeSincronizar()) {
      if(mounted) {
        showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Limite Atingido'),
              content: const Text('Você já atingiu o limite diário de 1 sincronização. Tente novamente amanhã.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
              ],
            )
        );
      }
      return;
    }

    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirmar Sincronização'),
          content: const Text('Deseja atualizar os dados do servidor (preços e perguntas iniciais)?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('CONFIRMAR'),
            ),
          ],
        );
      },
    );

    if (confirmar == true) {
      await _handleSync();
    }
  }

  void _navegarParaProximaTela(Map<String, String> respostasIniciais) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PerguntaScreen(respostasIniciais: respostasIniciais),
      ),
    );
  }

  void _iniciarFluxoDeInformacoes(List<InfoItem> informacoes, int index, Map<String, String> respostasIniciais) {
    if (index >= informacoes.length) {
      _navegarParaProximaTela(respostasIniciais);
      return;
    }

    final info = informacoes[index];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Informação Importante'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.descricao, style: const TextStyle(fontSize: 16)),
                if (info.imagemLocal != null && info.imagemLocal!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8.0),
                    child: Image.asset(
                      'assets/images/${info.imagemLocal!}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                SizedBox(height: 4),
                                Text("Imagem não encontrada", style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _navegarParaProximaTela(respostasIniciais);
              },
              child: const Text('PULAR TODAS'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _iniciarFluxoDeInformacoes(informacoes, index + 1, respostasIniciais);
              },
              child: const Text('PRÓXIMO'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _iniciarQuestionarioPrincipal() async {
    if (_formKey.currentState!.validate()) {
      final Map<String, String> respostasIniciais = {};

      for (var pergunta in _perguntasIniciais) {
        if (pergunta is PerguntaTextoLivre) {
          respostasIniciais[pergunta.pergunta] = _controllers[pergunta.pergunta]!.text.trim();
        } else if (pergunta is PerguntaComOpcoes) {
          respostasIniciais[pergunta.pergunta] = _respostasDeOpcoes[pergunta.pergunta] ?? '';
        }
      }

      final informacoes = await _service.carregarInformacoesIniciais();
      if (mounted) {
        if (informacoes.isNotEmpty) {
          _iniciarFluxoDeInformacoes(informacoes, 0, respostasIniciais);
        } else {
          _navegarParaProximaTela(respostasIniciais);
        }
      }
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _buildCampoPergunta(PerguntaInicial pergunta) {
    if (pergunta is PerguntaTextoLivre) {
      return TextFormField(
        controller: _controllers[pergunta.pergunta],
        decoration: InputDecoration(
          labelText: pergunta.pergunta,
          border: const OutlineInputBorder(),
        ),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return 'Este campo é obrigatório.';
          }
          return null;
        },
      );
    } else if (pergunta is PerguntaComOpcoes) {
      return DropdownButtonFormField<String>(
        value: _respostasDeOpcoes[pergunta.pergunta],
        decoration: InputDecoration(
          labelText: pergunta.pergunta,
          border: const OutlineInputBorder(),
        ),
        items: pergunta.opcoes.map((opcao) {
          return DropdownMenuItem<String>(
            value: opcao,
            child: Text(opcao),
          );
        }).toList(),
        onChanged: (String? newValue) {
          setState(() {
            _respostasDeOpcoes[pergunta.pergunta] = newValue;
          });
        },
        validator: (value) {
          if (value == null || value.isEmpty) {
            return 'Por favor, selecione uma opção.';
          }
          return null;
        },
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 30,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.business),
            ),
            const SizedBox(width: 10),
            const Text('NextStage Retrofit'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Histórico de orçamentos',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoricoOrcamentosScreen()),
              );
            },
          ),
          _isImporting
              ? const Padding(padding: EdgeInsets.all(16.0), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)))
              : IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sincronizar Dados',
            onPressed: _confirmarESincronizar,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24.0),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.teal.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _limitStatus,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.teal.shade800,
                    fontWeight: FontWeight.bold
                ),
              ),
            ),
            const SizedBox(height: 24),
            ..._perguntasIniciais.map((pergunta) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: _buildCampoPergunta(pergunta),
              );
            }).toList(),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.arrow_forward),
              onPressed: _iniciarQuestionarioPrincipal,
              label: const Text('CONTINUAR'),
            ),
          ],
        ),
      ),
    );
  }
}


class OpcaoComVinculo {
// ... (código existente da classe OpcaoComVinculo)
  final String nome;
  final bool eValida;
  final List<String> pecasIncompativeis; // Armazena as peças que causam o conflito

  OpcaoComVinculo({
    required this.nome,
    required this.eValida,
    this.pecasIncompativeis = const [],
  });
}


class PerguntaScreen extends StatefulWidget {
// ... (código existente da classe PerguntaScreen)
  final Map<String, String> respostasIniciais;

  const PerguntaScreen({super.key, required this.respostasIniciais});
  @override
  State<PerguntaScreen> createState() => _PerguntaScreenState();
}

class _PerguntaScreenState extends State<PerguntaScreen> {
// ... (código existente da classe _PerguntaScreenState)
  final service = DataService();
  final _limitService = LimitService();

  List<String> perguntas = [];
  Map<String, List<String>> itens = {};
  Map<String, Set<String>> vinculosMapa = {};
  Map<String, double> precosMapa = {};
  Map<String, InfoItem> informacoesRespostasMapa = {};
  Map<String, InfoItem> informacoesPerguntasMapa = {};

  int perguntaIndex = 0;
  final Map<String, String> respostasQuestionario = {};

  bool carregando = true;
  final List<String> logs = [];
  final Duration _authValidationInterval = const Duration(days: 2);

  // Controles para exibir ou não os pop-ups
  bool _exibirComentariosPerguntas = true;
  bool _exibirComentariosRespostas = true;

  @override
  void initState() {
    super.initState();
    _carregarTudo();
  }

  Future<void> _carregarTudo() async {
    final prefs = await SharedPreferences.getInstance();
    _exibirComentariosPerguntas = prefs.getBool('exibirComentariosPerguntas') ?? true;
    _exibirComentariosRespostas = prefs.getBool('exibirComentariosRespostas') ?? true;

    await _validateUserStatus();
    try {
      final futureResultados = await Future.wait([
        service.carregarPerguntas(),
        service.carregarItens(),
        service.carregarVinculosSemHeader(),
        service.carregarPrecosJson(),
        service.carregarInformacoesRespostas(),
        service.carregarInformacoesPerguntas(),
      ]);

      perguntas = futureResultados[0] as List<String>;
      itens = futureResultados[1] as Map<String, List<String>>;
      vinculosMapa = futureResultados[2] as Map<String, Set<String>>;
      precosMapa = futureResultados[3] as Map<String, double>;
      informacoesRespostasMapa = futureResultados[4] as Map<String, InfoItem>;
      informacoesPerguntasMapa = futureResultados[5] as Map<String, InfoItem>;

      setState(() => carregando = false);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _verificarEExibirInfoPergunta();
      });

    } catch (e) {
      if(mounted) {
        setState(() => carregando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro fatal ao carregar dados: $e')),
        );
      }
    }
  }

  Future<void> _validateUserStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    final lastValidationMillis = prefs.getInt('last_auth_validation_timestamp') ?? 0;
    final lastValidation = DateTime.fromMillisecondsSinceEpoch(lastValidationMillis);

    if (DateTime.now().difference(lastValidation) > _authValidationInterval) {
      print("Realizando verificação periódica do status do usuário...");
      try {
        await user.reload();
        print("Usuário ainda válido. Atualizando data da verificação.");
        await prefs.setInt('last_auth_validation_timestamp', DateTime.now().millisecondsSinceEpoch);
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-disabled' || e.code == 'user-not-found' || e.code == 'invalid-user-token') {
          print("Usuário desativado ou inválido. Realizando logout forçado.");
          await FirebaseAuth.instance.signOut();
        } else {
          print("Erro durante a verificação do usuário: ${e.code}");
        }
      }
    } else {
      print("Ainda não é hora de realizar a verificação periódica do usuário.");
    }
  }

  void _showLogDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Log de Processamento'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Text(
                    logs[index],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              child: const Text('FECHAR'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  void _promptSenhaLog() {
    final controller = TextEditingController();
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Acesso Restrito'),
            content: TextFormField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Senha',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCELAR')),
              ElevatedButton(
                  onPressed: () {
                    if (controller.text == 'log') {
                      Navigator.of(context).pop();
                      _showLogDialog();
                    } else {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Senha incorreta.'), backgroundColor: Colors.red)
                      );
                    }
                  },
                  child: const Text('ACESSAR')
              ),
            ],
          );
        }
    );
  }

  // MODIFICADO: A função agora retorna uma lista de `OpcaoComVinculo`
  List<OpcaoComVinculo> _opcoesParaPerguntaAtual() {
    final perguntaAtual = perguntas[perguntaIndex];
    logs.add('\n🔎 Pergunta ${perguntaIndex + 1}/${perguntas.length}: "$perguntaAtual"');

    // Sempre começamos com todas as opções possíveis para a pergunta atual
    final todasAsOpcoes = List<String>.from(itens[perguntaAtual] ?? const []);
    logs.add('📄 Opções padrão (itens.xlsx) para "$perguntaAtual": ${todasAsOpcoes.isEmpty ? '—' : todasAsOpcoes}');

    // Se for a primeira pergunta ou não houver respostas anteriores, todas são válidas.
    if (perguntaIndex == 0 || respostasQuestionario.isEmpty) {
      logs.add('ℹ️ Primeira pergunta ou sem respostas anteriores → todas as opções são válidas.');
      return todasAsOpcoes.map((nome) => OpcaoComVinculo(nome: nome, eValida: true)).toList();
    }

    // Coleta os vínculos de todas as respostas anteriores que são relevantes
    final vinculosDasRespostasAnteriores = <String, Set<String>>{};
    for (final resposta in respostasQuestionario.values) {
      final vinculos = vinculosMapa[resposta];
      if (vinculos != null && vinculos.isNotEmpty) {
        // Normalizamos para minúsculas para evitar problemas de case
        vinculosDasRespostasAnteriores[resposta] = vinculos.map((v) => v.trim().toLowerCase()).toSet();
      }
    }

    if (vinculosDasRespostasAnteriores.isEmpty) {
      logs.add('ℹ️ Nenhuma resposta anterior tinha vínculos → todas as opções são válidas.');
      return todasAsOpcoes.map((nome) => OpcaoComVinculo(nome: nome, eValida: true)).toList();
    }

    final resultadoFinal = <OpcaoComVinculo>[];

    // Para cada opção possível, verificamos se ela é compatível com TODAS as respostas anteriores.
    for (final opcao in todasAsOpcoes) {
      final pecasIncompativeis = <String>[];
      bool eValida = true;

      final opcaoNormalizada = opcao.trim().toLowerCase();

      // Itera sobre cada resposta anterior e seu conjunto de vínculos
      for (final entry in vinculosDasRespostasAnteriores.entries) {
        final respostaAnterior = entry.key;
        final vinculosDessaResposta = entry.value;

        if (!vinculosDessaResposta.contains(opcaoNormalizada)) {
          eValida = false;
          pecasIncompativeis.add(respostaAnterior); // Adiciona a peça que causou a incompatibilidade
        }
      }

      if (!eValida) {
        logs.add('❌ Opção "$opcao" é inválida. Conflito com: $pecasIncompativeis');
      }

      resultadoFinal.add(OpcaoComVinculo(
        nome: opcao,
        eValida: eValida,
        pecasIncompativeis: pecasIncompativeis,
      ));
    }

    logs.add('✅ Verificação de vínculos concluída.');
    return resultadoFinal;
  }

  // NOVO: Função para exibir o diálogo de incompatibilidade
  void _mostrarIncompatibilidade(OpcaoComVinculo opcao) {
    showDialog(
        context: context,
        builder: (context) {
          // Transforma a lista de peças em uma string formatada
          final pecasListadas = opcao.pecasIncompativeis.map((p) => '- $p').join('\n');

          return AlertDialog(
            title: const Text('Opção Indisponível'),
            content: SingleChildScrollView(
              child: Text(
                'A opção "${opcao.nome}" não é compatível com as seguintes peças já selecionadas:\n\n$pecasListadas',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('ENTENDI'),
              ),
            ],
          );
        }
    );
  }


  void _mostrarDialogoInfo(InfoItem info, {VoidCallback? onContinuar}) {
    showDialog(
      context: context,
      barrierDismissible: onContinuar == null,
      builder: (context) {
        return AlertDialog(
          title: const Text('Informações sobre a próxima pergunta'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.descricao, style: const TextStyle(fontSize: 16)),
                if (info.imagemLocal != null && info.imagemLocal!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8.0),
                    child: Image.asset(
                      'assets/images/${info.imagemLocal!}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                SizedBox(height: 4),
                                Text("Imagem não encontrada", style: TextStyle(color: Colors.grey),),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                if(onContinuar != null) {
                  onContinuar();
                }
              },
              child: Text(onContinuar != null ? 'CONTINUAR' : 'FECHAR'),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _mostrarDialogoConfirmacaoResposta(InfoItem info) async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Informações da peça selecionada'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.descricao, style: const TextStyle(fontSize: 16)),
                if (info.imagemLocal != null && info.imagemLocal!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8.0),
                    child: Image.asset(
                      'assets/images/${info.imagemLocal!}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                SizedBox(height: 4),
                                Text("Imagem não encontrada", style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('VOLTAR'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('ACEITAR'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _selecionar(String respostaEscolhida) async {
    final perguntaAtual = perguntas[perguntaIndex];

    void proximoPasso() {
      if (perguntaIndex < perguntas.length - 1) {
        perguntaIndex++;
        _verificarEExibirInfoPergunta();
      } else {
        _irParaResultado();
      }
    }

    if (_exibirComentariosRespostas && informacoesRespostasMapa.containsKey(respostaEscolhida)) {
      final info = informacoesRespostasMapa[respostaEscolhida]!;
      final bool? aceitou = await _mostrarDialogoConfirmacaoResposta(info);

      if (aceitou == true) {
        setState(() {
          respostasQuestionario[perguntaAtual] = respostaEscolhida;
          logs.add('👉 Escolhido: "$perguntaAtual" = "$respostaEscolhida"');
          proximoPasso();
        });
      } else {
        logs.add('↪️ Usuário voltou da informação da peça: "$respostaEscolhida"');
      }
    } else {
      setState(() {
        respostasQuestionario[perguntaAtual] = respostaEscolhida;
        logs.add('👉 Escolhido: "$perguntaAtual" = "$respostaEscolhida"');
        proximoPasso();
      });
    }
  }

  void _pularPergunta() {
    final perguntaAtual = perguntas[perguntaIndex];
    setState(() {
      respostasQuestionario.remove(perguntaAtual);
      logs.add('⏭️ Pergunta "${perguntaAtual}" pulada.');
      if (perguntaIndex < perguntas.length - 1) {
        perguntaIndex++;
        _verificarEExibirInfoPergunta();
      } else {
        _irParaResultado();
      }
    });
  }

  void _voltar() {
    if (perguntaIndex == 0) return;
    setState(() {
      perguntaIndex--;
      final p = perguntas[perguntaIndex];
      respostasQuestionario.remove(p);
      logs.add('⬅️ Voltou para: "${p}".');
      _verificarEExibirInfoPergunta();
    });
  }

  void _verificarEExibirInfoPergunta() {
    if (!_exibirComentariosPerguntas) return;

    final perguntaAtual = perguntas[perguntaIndex];
    if (informacoesPerguntasMapa.containsKey(perguntaAtual)) {
      _mostrarDialogoInfo(informacoesPerguntasMapa[perguntaAtual]!);
    }
  }

  void _reiniciar() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const PerguntasLivresScreen()),
          (Route<dynamic> route) => false,
    );
  }

  Future<void> _confirmarEReiniciarTudo() async {
    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirmar Ação'),
          content: const Text('Deseja reiniciar as perguntas?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('CONFIRMAR'),
            ),
          ],
        );
      },
    );

    if (confirmar == true) {
      _reiniciar();
    }
  }

  Future<void> _irParaResultado() async {
    if (!await _limitService.podeFazerOrcamento()) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Limite Diário Atingido'),
            content: Text('Você atingiu o limite de ${LimitService.maxOrcamentos} orçamentos por dia e não pode salvar este relatório. Por favor, tente novamente amanhã.'),
            actions: [
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultadoScreen(
          respostasIniciais: widget.respostasIniciais,
          respostasQuestionario: respostasQuestionario,
          precos: precosMapa,
          logs: logs,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (carregando) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (perguntas.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Erro')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Não foi possível carregar as perguntas. Verifique os arquivos XLSX e reinicie o aplicativo.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, color: Colors.red),
            ),
          ),
        ),
      );
    }

    final pergunta = perguntas[perguntaIndex];
    final opcoesComVinculo = _opcoesParaPerguntaAtual();
    final bool temAlgumaOpcaoValida = opcoesComVinculo.any((o) => o.eValida);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 30,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.business),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'NextStage Retrofit',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4.0),
          child: LinearProgressIndicator(
            value: (perguntaIndex + 1) / perguntas.length,
            backgroundColor: Colors.teal.withOpacity(0.2),
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.comment_outlined),
            tooltip: 'Opções de Comentários',
            onSelected: (value) async {
              final prefs = await SharedPreferences.getInstance();
              if (value == 'toggle_perguntas') {
                setState(() {
                  _exibirComentariosPerguntas = !_exibirComentariosPerguntas;
                });
                await prefs.setBool('exibirComentariosPerguntas', _exibirComentariosPerguntas);
              } else if (value == 'toggle_respostas') {
                setState(() {
                  _exibirComentariosRespostas = !_exibirComentariosRespostas;
                });
                await prefs.setBool('exibirComentariosRespostas', _exibirComentariosRespostas);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: 'toggle_perguntas',
                checked: _exibirComentariosPerguntas,
                child: const Text('Comentários das Perguntas'),
              ),
              CheckedPopupMenuItem<String>(
                value: 'toggle_respostas',
                checked: _exibirComentariosRespostas,
                child: const Text('Comentários das Respostas'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Ver Log',
            onPressed: _promptSenhaLog,
          ),
          IconButton(onPressed: _confirmarEReiniciarTudo, icon: const Icon(Icons.refresh), tooltip: 'Reiniciar Tudo'),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const AuthGate()),
                      (Route<dynamic> route) => false,
                );
              }
            },
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${perguntaIndex + 1}. ${pergunta}',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 22),
          ),
          const SizedBox(height: 24),

          // Caso 1: A lista de itens para a pergunta está completamente vazia.
          if (opcoesComVinculo.isEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: Colors.amber.shade100,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.amber.shade300),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 32),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            'Nenhuma opção compatível foi encontrada com base nas suas seleções anteriores.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.amber.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _pularPergunta,
                  icon: const Icon(Icons.skip_next_rounded),
                  label: const Text('AVANÇAR / PULAR PERGUNTA'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.teal,
                    elevation: 1,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.teal.withOpacity(0.5)),
                    ),
                  ),
                ),
              ],
            )
          // Caso 2: Existem opções, então as exibimos.
          else
            Column(
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: opcoesComVinculo.map((opcao) {
                    final bool eValida = opcao.eValida;
                    return ElevatedButton(
                      onPressed: () => eValida ? _selecionar(opcao.nome) : _mostrarIncompatibilidade(opcao),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: eValida ? Colors.white : Colors.grey.shade200,
                        foregroundColor: eValida ? Colors.teal : Colors.grey.shade500,
                        elevation: eValida ? 1 : 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: eValida ? Colors.teal.withOpacity(0.5) : Colors.grey.shade300,
                          ),
                        ),
                      ),
                      child: Text(
                        opcao.nome,
                        style: TextStyle(
                          decoration: eValida ? TextDecoration.none : TextDecoration.lineThrough,
                        ),
                      ),
                    );
                  }).toList(),
                ),

                // Se, após exibir as opções, nenhuma for válida, mostramos o botão de pular.
                if (!temAlgumaOpcaoValida) ...[
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _pularPergunta,
                    icon: const Icon(Icons.skip_next_rounded),
                    label: const Text('AVANÇAR / PULAR PERGUNTA'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.teal,
                      elevation: 1,
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.teal.withOpacity(0.5)),
                      ),
                    ),
                  ),
                ],
              ],
            ),

          const SizedBox(height: 32),
          if (respostasQuestionario.isNotEmpty) ...[
            Text('Respostas Anteriores:', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: respostasQuestionario.entries.map(
                      (e) => ListTile(
                    dense: true,
                    title: Text(e.key),
                    subtitle: Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold)),
                    leading: CircleAvatar(
                      backgroundColor: Colors.teal.withOpacity(0.1),
                      child: const Icon(Icons.check, color: Colors.teal, size: 18),
                    ),
                  ),
                ).toList(),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              onPressed: _voltar,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Voltar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey.shade300,
                foregroundColor: Colors.black87,
              ),
            ),
            // O botão "Finalizar" foi removido daqui
          ],
        ),
      ),
    );
  }
}


class ResultadoScreen extends StatefulWidget {
// ... (código existente da classe ResultadoScreen)
  final Map<String, String> respostasIniciais;
  final Map<String, String> respostasQuestionario;
  final Map<String, double> precos;
  final List<String> logs;

  const ResultadoScreen({
    super.key,
    required this.respostasIniciais,
    required this.respostasQuestionario,
    required this.precos,
    required this.logs,
  });

  @override
  State<ResultadoScreen> createState() => _ResultadoScreenState();
}

class _ResultadoScreenState extends State<ResultadoScreen> {
  OrcamentoConfiguracao? _orcamentoConfig;
  bool _relatorioSalvo = false;
  final _historicoService = HistoricoOrcamentosService();
  String? _historicoRegistroId;


  @override
  void initState() {
    super.initState();
    _registrarNoHistoricoAoAbrirResultado();
  }

  String _montarEscopoEmail(
      List<OrcamentoItem> itensAtuais,
      String estimativaFormatada,
      ) {
    final buffer = StringBuffer();

    buffer.writeln('<h3>PERGUNTAS INICIAIS</h3>');

    widget.respostasIniciais.forEach((pergunta, resposta) {
      buffer.writeln('• <b>$pergunta</b>: $resposta<br>');
    });

    buffer.writeln('<br><h3>PERGUNTAS TÉCNICAS</h3>');

    widget.respostasQuestionario.forEach((pergunta, resposta) {
      buffer.writeln('• <b>$pergunta</b>: $resposta<br>');
    });

    final itensPadrao = _itensPadrao();
    final itensComAlteracoes = <String>[];

    for (int i = 0; i < itensAtuais.length; i++) {
      final itemAtual = itensAtuais[i];
      final itemPadrao = i < itensPadrao.length ? itensPadrao[i] : null;

      if (itemPadrao == null ||
          itemPadrao.descricao != itemAtual.descricao ||
          itemPadrao.valor != itemAtual.valor) {

        final valorOriginal = itemPadrao?.valor ?? 0.0;
        final descricaoOriginal = itemPadrao?.descricao ?? 'Não definido';

        itensComAlteracoes.add(
          '• ${itemAtual.descricao} (antes: "$descricaoOriginal" / R\$ ${valorOriginal.toStringAsFixed(2)}, agora: R\$ ${itemAtual.valor.toStringAsFixed(2)})<br>',
        );
      }
    }

    buffer.writeln('<br><h3>MODIFICAÇÕES</h3>');

    if (itensComAlteracoes.isEmpty) {
      buffer.writeln('• Nenhuma modificação manual aplicada ao orçamento.<br>');
    } else {
      for (final alteracao in itensComAlteracoes) {
        buffer.writeln(alteracao);
      }
    }

    buffer.writeln('<br><h3>RESULTADOS FINAIS</h3>');

    buffer.writeln('• <b>Estimativa final:</b> $estimativaFormatada<br>');
    buffer.writeln('• <b>Margem aplicada:</b> ${_margemPercentualAtual.toStringAsFixed(2)}%<br>');
    buffer.writeln('• <b>Margem mínima:</b> ${_margemMinimaPercentualAtual.toStringAsFixed(2)}%<br>');

    buffer.writeln('<br><b>Itens finais do orçamento</b><br>');

    for (final item in itensAtuais) {
      buffer.writeln('• ${item.descricao}: R\$ ${item.valor.toStringAsFixed(2)}<br>');
    }

    return buffer.toString();
  }

  List<OrcamentoItem> _itensPadrao() {
    return widget.respostasQuestionario.values
        .map((resposta) => OrcamentoItem(
      descricao: resposta,
      valor: widget.precos[resposta] ?? 0.0,
    ))
        .toList();
  }

  List<OrcamentoItem> _itensAtuais() {
    final origem = _orcamentoConfig?.itens ?? _itensPadrao();
    return origem.map((item) => item.copy()).toList();
  }

  double get _margemPercentualAtual => _orcamentoConfig?.margemPercentual ?? 15.0;
  double get _margemMinimaPercentualAtual => _orcamentoConfig?.margemMinimaPercentual ?? 0.0;

  Map<String, dynamic> _montarDadosRelatorio(String estimativaFormatada) {
    final user = FirebaseAuth.instance.currentUser;
    final userEmail = user?.email ?? 'Usuário desconhecido';
    const emailDestinatario = 'luis.cappeletti@grupobaw.com.br';
    final itens = _itensAtuais();

    return {
      'destinatario': emailDestinatario,
      'orcamentistaEmail': userEmail,
      'respostasIniciais': widget.respostasIniciais,
      'respostasQuestionario': widget.respostasQuestionario,
      'estimativaFormatada': estimativaFormatada,
      'margemPercentual': _margemPercentualAtual,
      'margemMinimaPercentual': _margemMinimaPercentualAtual,
      'itensOrcamento': itens
          .map((item) => {
                'descricao': item.descricao,
                'valor': item.valor,
              })
          .toList(),
      'escopoEmailTexto': _montarEscopoEmail(itens, estimativaFormatada),
    };
  }

  String _estimativaFormatadaAtual() {
    final estimativa = _calcularEstimativa();
    final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
    return '${currencyFormat.format(estimativa['min'])} ~ ${currencyFormat.format(estimativa['max'])}';
  }

  Future<void> _registrarNoHistoricoAoAbrirResultado() async {
    final dados = _montarDadosRelatorio(_estimativaFormatadaAtual());
    _historicoRegistroId = await _historicoService.registrarOrcamento(
      dados: dados,
      finalizado: false,
      enviadoFirebase: false,
    );
  }

  Future<bool> _salvarRelatorioNoFirestore(BuildContext context, String estimativaFormatada) async {
    final limitService = LimitService();
    if (!await limitService.podeFazerOrcamento()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Erro: Limite diário de relatórios atingido.'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }

    try {
      final dadosParaSalvar = _montarDadosRelatorio(estimativaFormatada);
      _historicoRegistroId ??= await _historicoService.registrarOrcamento(
        dados: dadosParaSalvar,
        finalizado: false,
        enviadoFirebase: false,
      );

      await enviarRelatorioParaFirebase(
        dadosRelatorio: dadosParaSalvar,
        escopoEmailTexto: dadosParaSalvar['escopoEmailTexto'] as String,
      );

      await limitService.registrarOrcamento();

      if (_historicoRegistroId != null) {
        await _historicoService.atualizarRegistro(
          id: _historicoRegistroId!,
          dados: dadosParaSalvar,
          finalizado: true,
          enviadoFirebase: true,
          erroEnvio: '',
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Estimativa gerada'),
          backgroundColor: Colors.green,
        ),
      );
      _relatorioSalvo = true;
      return true;
    } catch (e) {
      if (_historicoRegistroId != null) {
        await _historicoService.atualizarRegistro(
          id: _historicoRegistroId!,
          finalizado: true,
          enviadoFirebase: false,
          erroEnvio: e.toString(),
        );
      }

      String errorMessage = 'Ocorreu um erro inesperado: $e';
      if (e is FirebaseException && e.code == 'permission-denied') {
        errorMessage = 'Permissão negada. Verifique as regras de segurança do Firestore.';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  void _showLogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Log de Processamento'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              itemCount: widget.logs.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Text(
                    widget.logs[index],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              child: const Text('FECHAR'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _promptSenhaLog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Acesso Restrito'),
          content: TextFormField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Senha',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('CANCELAR')),
            ElevatedButton(
              onPressed: () {
                if (controller.text == 'log') {
                  Navigator.of(dialogContext).pop();
                  _showLogDialog(context);
                } else {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Senha incorreta.'), backgroundColor: Colors.red),
                  );
                }
              },
              child: const Text('ACESSAR'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _promptSenhaEdicaoOrcamento(BuildContext context) async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Acesso Restrito'),
          content: TextFormField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Senha para editar orçamento',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (controller.text != 'log') {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Senha incorreta.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }

                Navigator.of(dialogContext).pop();
                final config = await Navigator.push<OrcamentoConfiguracao>(
                  context,
                  MaterialPageRoute(
                    builder: (context) => DetalheOrcamentoScreen(
                      respostasQuestionario: widget.respostasQuestionario,
                      precos: widget.precos,
                      itensIniciais: _itensAtuais(),
                      margemPercentualInicial: _margemPercentualAtual,
                      margemMinimaPercentualInicial: _margemMinimaPercentualAtual,
                    ),
                  ),
                );

                if (!mounted || config == null) {
                  return;
                }

                setState(() {
                  _orcamentoConfig = config;
                  _relatorioSalvo = false;
                });

                if (_historicoRegistroId != null) {
                  await _historicoService.atualizarRegistro(
                    id: _historicoRegistroId!,
                    dados: _montarDadosRelatorio(_estimativaFormatadaAtual()),
                  );
                }
              },
              child: const Text('ACESSAR'),
            ),
          ],
        );
      },
    );
  }

  Map<String, double> _calcularEstimativa() {
    final itens = _itensAtuais();
    final margemPercentual = _margemPercentualAtual;
    final margemMinimaPercentual = _margemMinimaPercentualAtual;

    double somaTotal = 0.0;
    widget.logs.add('\n🔎 Iniciando Cálculo de Preços...');

    for (final item in itens) {
      somaTotal += item.valor;
      widget.logs.add('✅ Item ["${item.descricao}"]: ${NumberFormat.currency(locale: 'pt_BR', symbol: r'R$').format(item.valor)}');
    }

    final fatorMargemMinima = 1 + (margemMinimaPercentual / 100);
    final fatorMargem = 1 + (margemPercentual / 100);
    final valorMinimo = somaTotal * fatorMargemMinima;
    final valorMaximo = somaTotal * fatorMargem;

    final double valorMinimoArredondado = (valorMinimo / 1000).round() * 1000.0;
    final double valorMaximoArredondado = (valorMaximo / 1000).round() * 1000.0;

    widget.logs.add('📊 Soma total: ${NumberFormat.currency(locale: 'pt_BR', symbol: r'R$').format(somaTotal)}');
    widget.logs.add('📉 Margem mínima aplicada: ${margemMinimaPercentual.toStringAsFixed(1)}%');
    widget.logs.add('📈 Margem máxima aplicada: ${margemPercentual.toStringAsFixed(1)}%');

    return {
      'subtotal': somaTotal,
      'margemPercentual': margemPercentual,
      'margemMinimaPercentual': margemMinimaPercentual,
      'min': valorMinimoArredondado,
      'max': valorMaximoArredondado,
    };
  }

  pw.Widget _buildAnswersSection(String title, Map<String, String> answers, pw.Font boldFont, pw.Font regularFont) {
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text(title, style: pw.TextStyle(font: boldFont, fontSize: 18)),
      pw.SizedBox(height: 10),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300), borderRadius: pw.BorderRadius.circular(5)),
        child: pw.Column(
          children: answers.entries.map((entry) {
            return pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Expanded(flex: 2, child: pw.Text('${entry.key}:', style: pw.TextStyle(font: boldFont))),
                pw.SizedBox(width: 8),
                pw.Expanded(flex: 3, child: pw.Text(entry.value, style: pw.TextStyle(font: regularFont))),
              ]),
            );
          }).toList(),
        ),
      ),
    ]);
  }

  pw.Widget _buildItensOrcamentoSection(List<OrcamentoItem> itens, pw.Font boldFont, pw.Font font) {
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('Itens do Orçamento', style: pw.TextStyle(font: boldFont, fontSize: 18)),
      pw.SizedBox(height: 8),
      ...itens.map(
            (item) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Expanded(child: pw.Text(item.descricao, style: pw.TextStyle(font: font, fontSize: 11))),
          ]),
        ),
      ),
    ]);
  }

  Future<Uint8List> _generatePdfReport(PdfPageFormat format) async {
    final doc = pw.Document();
    pw.Font font;
    pw.Font boldFont;
    try {
      font = await PdfGoogleFonts.robotoRegular();
      boldFont = await PdfGoogleFonts.robotoBold();
    } catch (_) {
      font = pw.Font.helvetica();
      boldFont = pw.Font.helveticaBold();
    }

    pw.MemoryImage? logoImage;
    try {
      final logoData = await rootBundle.load('assets/images/logo.png');
      final logoBytes = logoData.buffer.asUint8List();
      logoImage = pw.MemoryImage(logoBytes);
    } catch (_) {
      logoImage = null;
    }

    final itens = _itensAtuais();
    final estimativa = _calcularEstimativa();
    final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
    final estimativaFormatada =
        '${currencyFormat.format(estimativa['min'])} ~ ${currencyFormat.format(estimativa['max'])}';

    final dataAtual = DateTime.now();
    final dataValidade = DateTime(dataAtual.year, dataAtual.month + 1, dataAtual.day);
    final dataValidadeFormatada = DateFormat('dd/MM/yyyy').format(dataValidade);

    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        header: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('RESUMO DO ORÇAMENTO', style: pw.TextStyle(font: boldFont, fontSize: 22)),
                      pw.Text(DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now()), style: pw.TextStyle(font: font, fontSize: 12)),
                    ],
                  ),
                  if (logoImage != null) pw.Image(logoImage, height: 50),
                ],
              ),
              pw.Divider(thickness: 2),
              pw.SizedBox(height: 20),
            ],
          );
        },
        build: (pw.Context context) => [
          _buildAnswersSection('Informações do Cliente', widget.respostasIniciais, boldFont, font),
          pw.SizedBox(height: 20),
          _buildItensOrcamentoSection(itens, boldFont, font),
          pw.SizedBox(height: 12),
          pw.Text('Estimativa de Valor', style: pw.TextStyle(font: boldFont, fontSize: 18)),
          pw.SizedBox(height: 8),
          pw.Text(estimativaFormatada, style: pw.TextStyle(font: font, fontSize: 16)),
          pw.SizedBox(height: 8),
          pw.Text(
            'Orçamento válido até: $dataValidadeFormatada',
            style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey800),
          ),
          pw.SizedBox(height: 20),
          _buildAnswersSection('Respostas do Diagnóstico', widget.respostasQuestionario, boldFont, font),
        ],
        footer: (pw.Context context) {
          return pw.Footer(
            title: pw.Text(
              'Documento gerado por NS Retrofit',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey),
            ),
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> _shareReport(BuildContext context) async {
    try {
      final estimativa = _calcularEstimativa();
      final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
      final estimativaFormatada =
          '${currencyFormat.format(estimativa['min'])} ~ ${currencyFormat.format(estimativa['max'])}';

      if (!_relatorioSalvo) {
        final salvou = await _salvarRelatorioNoFirestore(context, estimativaFormatada);
        if (!salvou) {
          return;
        }
      }

      final pdfBytes = await _generatePdfReport(PdfPageFormat.a4);
      await Printing.sharePdf(bytes: pdfBytes, filename: 'relatorio_perguntas.pdf');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relatório finalizado e PDF gerado com sucesso.')),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const PerguntasLivresScreen()),
              (Route<dynamic> route) => false,
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao gerar ou partilhar PDF: $e')));
    }
  }

  Future<void> _finalizarRelatorioSemPdf(BuildContext context) async {
    final estimativa = _calcularEstimativa();
    final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
    final estimativaFormatada =
        '${currencyFormat.format(estimativa['min'])} ~ ${currencyFormat.format(estimativa['max'])}';

    if (!_relatorioSalvo) {
      final salvou = await _salvarRelatorioNoFirestore(context, estimativaFormatada);
      if (!salvou) {
        return;
      }
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Relatório finalizado e enviado para processamento.')),
    );
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const PerguntasLivresScreen()),
          (Route<dynamic> route) => false,
    );
  }

  Widget _buildSectionCard(BuildContext context, {required String title, required IconData icon, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).primaryColor),
                const SizedBox(width: 12),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void reiniciarTudo() {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const PerguntasLivresScreen()),
            (Route<dynamic> route) => false,
      );
    }

    Future<void> confirmarEReiniciarTudo() async {
      final bool? confirmar = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Confirmar Ação'),
            content: const Text('Deseja iniciar um novo diagnóstico?'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('CONFIRMAR'),
              ),
            ],
          );
        },
      );

      if (confirmar == true) {
        reiniciarTudo();
      }
    }

    final estimativa = _calcularEstimativa();
    final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
    final estimativaFormatada =
        '${currencyFormat.format(estimativa['min'])} ~ ${currencyFormat.format(estimativa['max'])}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Resultado Final'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const AuthGate()),
                      (Route<dynamic> route) => false,
                );
              }
            },
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onDoubleTap: () {
              _promptSenhaEdicaoOrcamento(context);
            },
            child: Card(
              color: Colors.teal,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Estimativa de Valor',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      estimativaFormatada,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white, fontSize: 32),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '(margem mínima: ${_margemMinimaPercentualAtual.toStringAsFixed(1)}% | margem máxima: ${_margemPercentualAtual.toStringAsFixed(1)}%)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            context,
            title: 'Informações do Atendimento',
            icon: Icons.receipt_long,
            children: widget.respostasIniciais.entries
                .map(
                  (e) => ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
                .toList(),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            context,
            title: 'Respostas do Diagnóstico',
            icon: Icons.checklist_rtl,
            children: widget.respostasQuestionario.entries
                .map(
                  (e) => ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
                .toList(),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('FINALIZAR RELATÓRIO'),
            onPressed: () => _finalizarRelatorioSemPdf(context),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('GERAR PDF E FINALIZAR RELATÓRIO'),
            onPressed: () => _shareReport(context),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.replay_outlined),
            label: const Text('INICIAR NOVO DIAGNÓSTICO'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.teal,
              side: const BorderSide(color: Colors.teal),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: confirmarEReiniciarTudo,
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.bug_report_outlined, size: 20),
              label: const Text('Ver Log de Processamento'),
              onPressed: () => _promptSenhaLog(context),
              style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }
}

//
// ✨✨✨ NOVA TELA ADICIONADA AQUI ✨✨✨
//
class OrcamentoItem {
  String descricao;
  double valor;

  OrcamentoItem({required this.descricao, required this.valor});

  OrcamentoItem copy() => OrcamentoItem(descricao: descricao, valor: valor);
}

class OrcamentoConfiguracao {
  final List<OrcamentoItem> itens;
  final double margemPercentual;
  final double margemMinimaPercentual;

  OrcamentoConfiguracao({
    required this.itens,
    required this.margemPercentual,
    this.margemMinimaPercentual = 0.0,
  });
}

class DetalheOrcamentoScreen extends StatefulWidget {
  final Map<String, String> respostasQuestionario;
  final Map<String, double> precos;
  final List<OrcamentoItem> itensIniciais;
  final double margemPercentualInicial;
  final double margemMinimaPercentualInicial;

  const DetalheOrcamentoScreen({
    super.key,
    required this.respostasQuestionario,
    required this.precos,
    required this.itensIniciais,
    required this.margemPercentualInicial,
    this.margemMinimaPercentualInicial = 0.0,
  });

  @override
  State<DetalheOrcamentoScreen> createState() => _DetalheOrcamentoScreenState();
}

class _DetalheOrcamentoScreenState extends State<DetalheOrcamentoScreen> {
  final List<OrcamentoItem> _itens = [];
  late double _margemPercentual;
  late double _margemMinimaPercentual;

  @override
  void initState() {
    super.initState();
    _itens.addAll(widget.itensIniciais.map((item) => item.copy()));
    _margemPercentual = widget.margemPercentualInicial;
    _margemMinimaPercentual = widget.margemMinimaPercentualInicial;
  }

  double _parseValor(String input) {
    return double.tryParse(input.replaceAll(',', '.')) ?? 0.0;
  }

  Future<void> _mostrarDialogoAdicionarItem() async {
    final descricaoController = TextEditingController();
    final valorController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Adicionar item manualmente'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: descricaoController,
                decoration: const InputDecoration(labelText: 'Descrição'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: valorController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Valor'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () {
                final descricao = descricaoController.text.trim();
                if (descricao.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Informe a descrição do item.')),
                  );
                  return;
                }

                final valor = _parseValor(valorController.text.trim());
                setState(() {
                  _itens.add(OrcamentoItem(descricao: descricao, valor: valor));
                });
                Navigator.of(dialogContext).pop();
              },
              child: const Text('ADICIONAR'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _mostrarDialogoEditarItem(int index) async {
    final item = _itens[index];
    final descricaoController = TextEditingController(text: item.descricao);
    final valorController = TextEditingController(text: item.valor.toStringAsFixed(2));

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Editar item'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: descricaoController,
                decoration: const InputDecoration(labelText: 'Descrição'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: valorController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Valor'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () {
                final descricao = descricaoController.text.trim();
                if (descricao.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Informe a descrição do item.')),
                  );
                  return;
                }

                setState(() {
                  _itens[index]
                    ..descricao = descricao
                    ..valor = _parseValor(valorController.text.trim());
                });
                Navigator.of(dialogContext).pop();
              },
              child: const Text('SALVAR'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: r'R$');
    double somaTotal = 0.0;
    final List<Widget> itensWidgets = [];

    for (int i = 0; i < _itens.length; i++) {
      final item = _itens[i];
      somaTotal += item.valor;
      itensWidgets.add(
        ListTile(
          title: Text(item.descricao),
          subtitle: Text('Valor ajustável apenas neste relatório', style: TextStyle(color: Colors.grey.shade600)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(currencyFormat.format(item.valor)),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Editar item',
                onPressed: () => _mostrarDialogoEditarItem(i),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remover item',
                onPressed: () {
                  setState(() {
                    _itens.removeAt(i);
                  });
                },
              ),
            ],
          ),
          dense: true,
        ),
      );
    }

    final fatorMargemMinima = 1 + (_margemMinimaPercentual / 100);
    final fatorMargem = 1 + (_margemPercentual / 100);
    final valorMinimoBruto = somaTotal * fatorMargemMinima;
    final valorMaximoBruto = somaTotal * fatorMargem;
    final valorMinimoArredondado = (valorMinimoBruto / 1000).round() * 1000.0;
    final valorMaximoArredondado = (valorMaximoBruto / 1000).round() * 1000.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalhamento do Orçamento'),
        actions: [
          IconButton(
            onPressed: _mostrarDialogoAdicionarItem,
            icon: const Icon(Icons.add),
            tooltip: 'Adicionar item',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Text(
            'Itens Selecionados',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: itensWidgets.isEmpty ? [const ListTile(title: Text('Nenhum item selecionado.'))] : itensWidgets,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Margem de Lucro',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Margem aplicada ao valor mínimo'),
                  trailing: Text('${_margemMinimaPercentual.toStringAsFixed(1)}%'),
                ),
                Slider(
                  min: -50,
                  max: 50,
                  divisions: 200,
                  value: _margemMinimaPercentual,
                  label: '${_margemMinimaPercentual.toStringAsFixed(1)}%',
                  onChanged: (novoValor) {
                    setState(() {
                      _margemMinimaPercentual = novoValor;
                    });
                  },
                ),
                ListTile(
                  title: const Text('Margem aplicada ao valor máximo'),
                  trailing: Text('${_margemPercentual.toStringAsFixed(1)}%'),
                ),
                Slider(
                  min: 0,
                  max: 50,
                  divisions: 100,
                  value: _margemPercentual,
                  label: '${_margemPercentual.toStringAsFixed(1)}%',
                  onChanged: (novoValor) {
                    setState(() {
                      _margemPercentual = novoValor;
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Cálculo da Estimativa',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Subtotal (Soma das Peças)', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: Text(currencyFormat.format(somaTotal), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                ListTile(
                  title: Text('Valor Mínimo (${_margemMinimaPercentual.toStringAsFixed(1)}%)'),
                  subtitle: const Text('Subtotal x (1 + margem mínima)'),
                  trailing: Text(currencyFormat.format(valorMinimoBruto)),
                ),
                ListTile(
                  title: Text('Valor Máximo (+${_margemPercentual.toStringAsFixed(1)}%)'),
                  subtitle: const Text('Subtotal x (1 + margem)'),
                  trailing: Text(currencyFormat.format(valorMaximoBruto)),
                ),
                const Divider(height: 20, thickness: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: Text('Estimativa Final (Arredondada)', style: TextStyle(color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold, fontSize: 18)),
                  trailing: Text(
                    '${currencyFormat.format(valorMinimoArredondado)} ~ ${currencyFormat.format(valorMaximoArredondado)}',
                    style: TextStyle(color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop(
                OrcamentoConfiguracao(
                  itens: _itens.map((item) => item.copy()).toList(),
                  margemPercentual: _margemPercentual,
                  margemMinimaPercentual: _margemMinimaPercentual,
                ),
              );
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('SALVAR ALTERAÇÕES DESTE ORÇAMENTO'),
          ),
        ],
      ),
    );
  }
}

class HistoricoOrcamentosScreen extends StatefulWidget {
  const HistoricoOrcamentosScreen({super.key});

  @override
  State<HistoricoOrcamentosScreen> createState() => _HistoricoOrcamentosScreenState();
}

class _HistoricoOrcamentosScreenState extends State<HistoricoOrcamentosScreen> {
  final _historicoService = HistoricoOrcamentosService();
  bool _carregando = true;
  List<Map<String, dynamic>> _registros = [];

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final historico = await _historicoService.carregarHistorico();
    if (!mounted) return;
    setState(() {
      _registros = historico;
      _carregando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Histórico de Orçamentos')),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : _registros.isEmpty
              ? const Center(
                  child: Text('Nenhum orçamento registrado ainda.'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _registros.length,
                  itemBuilder: (context, index) {
                    final registro = _registros[index];
                    final dados = registro['dados'] is Map
                        ? Map<String, dynamic>.from(registro['dados'])
                        : <String, dynamic>{};
                    final enviado = registro['enviadoFirebase'] == true;
                    final finalizado = registro['finalizado'] == true;
                    final criadoEm = DateTime.tryParse(registro['criadoEm']?.toString() ?? '');
                    final dataFormatada = criadoEm != null
                        ? DateFormat('dd/MM/yyyy HH:mm').format(criadoEm)
                        : 'Data não disponível';

                    return Card(
                      child: ExpansionTile(
                        leading: CircleAvatar(
                          backgroundColor: enviado ? Colors.green.shade100 : Colors.orange.shade100,
                          child: Icon(
                            enviado ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                            color: enviado ? Colors.green.shade700 : Colors.orange.shade700,
                          ),
                        ),
                        title: Text(dados['estimativaFormatada']?.toString() ?? 'Sem estimativa'),
                        subtitle: Text('Criado em: $dataFormatada'),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                avatar: Icon(
                                  enviado ? Icons.check_circle : Icons.pending,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                label: Text(enviado ? 'Enviado ao Firebase' : 'Pendente de envio'),
                                backgroundColor: enviado ? Colors.green : Colors.orange,
                                labelStyle: const TextStyle(color: Colors.white),
                              ),
                              Chip(
                                label: Text(finalizado ? 'Finalizado' : 'Não finalizado'),
                                backgroundColor: finalizado ? Colors.teal.shade100 : Colors.grey.shade300,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Orçamentista: ${dados['orcamentistaEmail'] ?? 'Não informado'}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text('Destinatário: ${dados['destinatario'] ?? 'Não informado'}'),
                          const SizedBox(height: 10),
                          if ((dados['respostasIniciais'] as Map?)?.isNotEmpty == true) ...[
                            const Text('Dados iniciais', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            ...(Map<String, dynamic>.from(dados['respostasIniciais'] as Map)).entries.map(
                              (e) => Text('• ${e.key}: ${e.value}'),
                            ),
                            const SizedBox(height: 10),
                          ],
                          if (registro['erroEnvio'] != null) ...[
                            Text(
                              'Último erro de envio: ${registro['erroEnvio']}',
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ]
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
