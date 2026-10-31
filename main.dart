import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  await PlantaoStore.instance.load();
  await NotificationService.instance.initialize();
  runApp(const PlantaoApp());
}

enum WorkType { samu, particular }
enum DayStatus { normal, folga, ausencia }

extension WorkTypeLabel on WorkType {
  String get label => this == WorkType.samu ? 'SAMU' : 'Particular';
  Color get color => this == WorkType.samu ? const Color(0xFFD32F2F) : const Color(0xFF1976D2);
}

class DayOverride {
  final DayStatus status;
  final String note;
  const DayOverride(this.status, {this.note = ''});

  Map<String, dynamic> toJson() => {'status': status.name, 'note': note};
  factory DayOverride.fromJson(Map<String, dynamic> json) => DayOverride(
    DayStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => DayStatus.normal),
    note: json['note'] as String? ?? '',
  );
}

class DayTimes {
  final String start;
  final String alarm; // hora exata do alarme, HH:mm
  const DayTimes(this.start, this.alarm);
  Map<String, dynamic> toJson() => {'start': start, 'alarm': alarm};
  factory DayTimes.fromJson(Map<String, dynamic> j) {
    final start = j['start'] as String? ?? '19:00';
    return DayTimes(start, _alarmFrom(j['alarm'], start, '17:00'));
  }
}

class SwapRecord {
  final DateTime first;
  final DateTime second;
  final String colleague;
  final String note;
  const SwapRecord(this.first, this.second, {this.colleague = '', this.note = ''});

  Map<String, dynamic> toJson() => {
    'first': _dateKey(first), 'second': _dateKey(second),
    'colleague': colleague, 'note': note,
  };
  factory SwapRecord.fromJson(Map<String, dynamic> json) => SwapRecord(
    DateTime.parse(json['first'] as String), DateTime.parse(json['second'] as String),
    colleague: json['colleague'] as String? ?? '',
    note: json['note'] as String? ?? '',
  );
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _fmt(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Converte dados antigos (alarme em "minutos antes") para hora exata.
String _minusMinutes(String hhmm, int minutes) {
  final p = hhmm.split(':');
  final t = ((int.parse(p[0]) * 60 + int.parse(p[1]) - minutes) % 1440 + 1440) % 1440;
  return '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
}

String _alarmFrom(dynamic v, String start, String fallback) {
  if (v is String) return v;
  if (v is int) return _minusMinutes(start, v);
  return fallback;
}

class PlantaoStore extends ChangeNotifier {
  PlantaoStore._();
  static final instance = PlantaoStore._();

  DateTime startDate = DateTime(2026, 10, 31); // SAMU em 31/10 => SAMU nos dias pares de novembro
  WorkType firstType = WorkType.samu;
  String samuStart = '19:00';
  String privateStart = '19:00';
  int durationHours = 12;
  String samuAlarm = '17:00';
  String privateAlarm = '17:00';
  final Map<String, DayOverride> overrides = {};
  final List<SwapRecord> swaps = [];
  final Map<String, DayTimes> timeOverrides = {};
  String? notifError; // última falha ao agendar alarmes (mostrada na tela)

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('plantao_config');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      startDate = DateTime.tryParse(j['startDate'] ?? '') ?? startDate;
      firstType = WorkType.values.firstWhere((e) => e.name == j['firstType'], orElse: () => WorkType.samu);
      samuStart = j['samuStart'] ?? samuStart;
      privateStart = j['privateStart'] ?? privateStart;
      durationHours = j['durationHours'] ?? durationHours;
      samuAlarm = _alarmFrom(j['samuAlarm'] ?? j['samuAlarmMinutes'], samuStart, samuAlarm);
      privateAlarm = _alarmFrom(j['privateAlarm'] ?? j['privateAlarmMinutes'], privateStart, privateAlarm);
      overrides.clear();
      (j['overrides'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        overrides[k] = DayOverride.fromJson(Map<String, dynamic>.from(v));
      });
      timeOverrides.clear();
      (j['timeOverrides'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        timeOverrides[k] = DayTimes.fromJson(Map<String, dynamic>.from(v));
      });
      swaps
        ..clear()
        ..addAll((j['swaps'] as List? ?? []).map((e) => SwapRecord.fromJson(Map<String, dynamic>.from(e))));
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('plantao_config', jsonEncode({
      'startDate': _dateKey(startDate),
      'firstType': firstType.name,
      'samuStart': samuStart,
      'privateStart': privateStart,
      'durationHours': durationHours,
      'samuAlarm': samuAlarm,
      'privateAlarm': privateAlarm,
      'overrides': overrides.map((k, v) => MapEntry(k, v.toJson())),
      'swaps': swaps.map((e) => e.toJson()).toList(),
      'timeOverrides': timeOverrides.map((k, v) => MapEntry(k, v.toJson())),
    }));
    await NotificationService.instance.refresh(this);
    notifyListeners();
  }

  WorkType originalType(DateTime date) {
    final days = _day(date).difference(_day(startDate)).inDays;
    return days.isEven ? firstType : (firstType == WorkType.samu ? WorkType.particular : WorkType.samu);
  }

  WorkType effectiveType(DateTime date) {
    var type = originalType(date);
    for (final s in swaps) {
      if (_day(date) == _day(s.first)) type = originalType(s.second);
      if (_day(date) == _day(s.second)) type = originalType(s.first);
    }
    return type;
  }

  DayOverride? overrideFor(DateTime date) => overrides[_dateKey(date)];

  Future<void> setStatus(DateTime date, DayStatus status, {String note = ''}) async {
    final key = _dateKey(date);
    if (status == DayStatus.normal) {
      overrides.remove(key);
    } else {
      overrides[key] = DayOverride(status, note: note);
    }
    await save();
  }

  Future<void> addSwap(DateTime a, DateTime b, {String colleague = '', String note = ''}) async {
    swaps.removeWhere((s) => _day(s.first) == _day(a) || _day(s.second) == _day(a) ||
        _day(s.first) == _day(b) || _day(s.second) == _day(b));
    swaps.add(SwapRecord(_day(a), _day(b), colleague: colleague, note: note));
    await save();
  }

  Future<void> removeSwapFor(DateTime date) async {
    swaps.removeWhere((s) => _day(s.first) == _day(date) || _day(s.second) == _day(date));
    await save();
  }

  bool hasTimeOverride(DateTime date) => timeOverrides.containsKey(_dateKey(date));
  String startOn(DateTime date) => timeOverrides[_dateKey(date)]?.start ?? startFor(effectiveType(date));
  String alarmOn(DateTime date) => timeOverrides[_dateKey(date)]?.alarm ?? alarmFor(effectiveType(date));

  /// Define horário/alarme de um dia. Com [allOfType], vira o padrão de toda a
  /// empresa (SAMU ou particular) e remove ajustes individuais desses dias.
  Future<void> setDayTimes(DateTime date, String start, String alarm, {required bool allOfType}) async {
    if (allOfType) {
      final type = effectiveType(date);
      if (type == WorkType.samu) { samuStart = start; samuAlarm = alarm; }
      else { privateStart = start; privateAlarm = alarm; }
      timeOverrides.removeWhere((k, _) => effectiveType(DateTime.parse(k)) == type);
    } else {
      timeOverrides[_dateKey(date)] = DayTimes(start, alarm);
    }
    await save();
  }

  Future<void> resetDayTimes(DateTime date) async {
    timeOverrides.remove(_dateKey(date));
    await save();
  }

  /// Aplica a mesma entrada e hora de alarme a vários dias de uma vez.
  Future<void> setTimesForDates(Iterable<DateTime> dates, String start, String alarm) async {
    for (final d in dates) {
      timeOverrides[_dateKey(d)] = DayTimes(start, alarm);
    }
    await save();
  }

  Future<void> resetTimesForDates(Iterable<DateTime> dates) async {
    for (final d in dates) {
      timeOverrides.remove(_dateKey(d));
    }
    await save();
  }

  String startFor(WorkType type) => type == WorkType.samu ? samuStart : privateStart;
  String alarmFor(WorkType type) => type == WorkType.samu ? samuAlarm : privateAlarm;
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final plugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: android));
    final androidPlugin = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
  }

  Future<void> _last = Future.value();

  /// Reagenda os alarmes, um refresh por vez (evita corrida entre salvamentos).
  /// Nunca lança: falhas ficam em store.notifError e viram um aviso na tela.
  Future<void> refresh(PlantaoStore store) {
    _last = _last.then((_) => _refresh(store));
    return _last;
  }

  Future<void> _refresh(PlantaoStore store) async {
    try {
      await plugin.cancelAll();
    } catch (e) {
      store.notifError = 'cancelar: $e';
    }
    final now = DateTime.now();
    // Mantém uma janela móvel de 60 dias de notificações futuras.
    for (var i = 0; i < 60; i++) {
      final date = _day(now.add(Duration(days: i)));
      if (date.isBefore(_day(store.startDate))) continue; // escala ainda não começou
      final override = store.overrideFor(date);
      if (override?.status == DayStatus.folga || override?.status == DayStatus.ausencia) continue;
      final type = store.effectiveType(date);
      final parts = store.startOn(date).split(':');
      final start = DateTime(date.year, date.month, date.day, int.parse(parts[0]), int.parse(parts[1]));
      final ap = store.alarmOn(date).split(':');
      var fireAt = DateTime(date.year, date.month, date.day, int.parse(ap[0]), int.parse(ap[1]));
      // Alarme com hora posterior à entrada = dia anterior (ex.: entrada 00:30, alarme 23:00).
      if (fireAt.isAfter(start)) fireAt = fireAt.subtract(const Duration(days: 1));
      if (!fireAt.isAfter(now)) continue;
      final scheduled = tz.TZDateTime.from(fireAt, tz.local);
      final id = int.parse('${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}${type == WorkType.samu ? 1 : 2}');
      try {
      await plugin.zonedSchedule(
        id,
        'Plantão ${type.label}',
        'Seu plantão começa às ${store.startOn(date)}.',
        scheduled,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'plantao_alertas', 'Alertas de plantão',
            channelDescription: 'Lembretes de início dos plantões',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      } catch (e) {
        store.notifError = 'agendar: $e';
      }
    }
  }
}

class PlantaoApp extends StatelessWidget {
  const PlantaoApp({super.key});

  ThemeData _theme(Brightness b) => ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F51B5), brightness: b),
    visualDensity: VisualDensity.standard,
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Controle de Plantão 12/36',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final store = PlantaoStore.instance;
  late DateTime selected = _initialSelected();
  late DateTime month = DateTime(selected.year, selected.month);

  static const _months = ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
    'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'];

  static DateTime _initialSelected() {
    final today = _day(DateTime.now());
    final start = _day(PlantaoStore.instance.startDate);
    return today.isBefore(start) ? start : today;
  }

  void _shiftMonth(int delta) => setState(() => month = DateTime(month.year, month.month + delta));

  static const _weekdays = ['Segunda-feira', 'Terça-feira', 'Quarta-feira', 'Quinta-feira',
    'Sexta-feira', 'Sábado', 'Domingo'];

  bool selecting = false;
  final Set<DateTime> picked = {};

  bool _isBeforeStart(DateTime d) => d.isBefore(_day(store.startDate));

  void _exitSelecting() => setState(() { selecting = false; picked.clear(); });

  void _pickType(WorkType t) => setState(() {
    final n = DateTime(month.year, month.month + 1, 0).day;
    for (var d = 1; d <= n; d++) {
      final date = DateTime(month.year, month.month, d);
      if (!_isBeforeStart(date) && store.effectiveType(date) == t) picked.add(date);
    }
  });

  Future<void> _bulkTimes() async {
    final dates = (picked.toList()..sort()).where((d) => !_isBeforeStart(d)).toList();
    if (dates.isEmpty) return;
    final startCtl = TextEditingController(text: store.startOn(dates.first));
    final alarmCtl = TextEditingController(text: store.alarmOn(dates.first));
    final samuN = dates.where((d) => store.effectiveType(d) == WorkType.samu).length;
    final privN = dates.length - samuN;
    var done = false;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${dates.length} dias selecionados'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SAMU: $samuN  •  Particular: $privN'),
          const SizedBox(height: 12),
          TextField(controller: startCtl, decoration: const InputDecoration(labelText: 'Entrada (HH:mm)', border: OutlineInputBorder()), keyboardType: TextInputType.datetime),
          const SizedBox(height: 12),
          TextField(controller: alarmCtl, decoration: const InputDecoration(labelText: 'Hora do alarme (HH:mm)', border: OutlineInputBorder()), keyboardType: TextInputType.datetime),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(
            onPressed: () async {
              await store.resetTimesForDates(dates);
              done = true;
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Restaurar padrão'),
          ),
          FilledButton(
            onPressed: () async {
              if (!_validTime(startCtl.text) || !_validTime(alarmCtl.text)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe horários válidos no formato HH:mm.')));
                return;
              }
              await store.setTimesForDates(dates, startCtl.text, alarmCtl.text);
              done = true;
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    if (done && mounted) _exitSelecting();
  }

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => NotificationService.instance.refresh(store));
  }
  @override
  void dispose() {
    store.removeListener(_changed);
    super.dispose();
  }
  void _changed() {
    if (!mounted) return;
    setState(() {});
    final e = store.notifError;
    if (e != null) {
      store.notifError = null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Salvo, mas houve falha nos alarmes ($e)'),
      ));
    }
  }

  Future<void> _editDay() async {
    final status = store.overrideFor(selected)?.status ?? DayStatus.normal;
    final note = TextEditingController(text: store.overrideFor(selected)?.note ?? '');
    var choice = status;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setModal) => Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Editar ${_dateKey(selected)}', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('Escala original: ${store.originalType(selected).label}'),
          const SizedBox(height: 12),
          DropdownButtonFormField<DayStatus>(
            value: choice,
            decoration: const InputDecoration(labelText: 'Situação do dia', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: DayStatus.normal, child: Text('Plantão normal')),
              DropdownMenuItem(value: DayStatus.folga, child: Text('Folga')),
              DropdownMenuItem(value: DayStatus.ausencia, child: Text('Ausência / imprevisto')),
            ],
            onChanged: (v) => setModal(() => choice = v ?? DayStatus.normal),
          ),
          const SizedBox(height: 12),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Observação (opcional)', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await store.setStatus(selected, choice, note: note.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Salvar alteração'),
          ),
        ]),
      )),
    );
  }

  Future<void> _editTimes() async {
    final type = store.effectiveType(selected);
    final startCtl = TextEditingController(text: store.startOn(selected));
    final alarmCtl = TextEditingController(text: store.alarmOn(selected));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) {
        Future<void> apply(bool all) async {
          if (!_validTime(startCtl.text) || !_validTime(alarmCtl.text)) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe horários válidos no formato HH:mm.')));
            return;
          }
          await store.setDayTimes(selected, startCtl.text, alarmCtl.text, allOfType: all);
          if (ctx.mounted) Navigator.pop(ctx);
        }
        return AlertDialog(
          title: Text('${_dateKey(selected)} • ${type.label}'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: startCtl, decoration: const InputDecoration(labelText: 'Entrada (HH:mm)'), keyboardType: TextInputType.datetime),
            const SizedBox(height: 12),
            TextField(controller: alarmCtl, decoration: const InputDecoration(labelText: 'Hora do alarme (HH:mm)'), keyboardType: TextInputType.datetime),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            if (store.hasTimeOverride(selected))
              TextButton(
                onPressed: () async { await store.resetDayTimes(selected); if (ctx.mounted) Navigator.pop(ctx); },
                child: const Text('Restaurar padrão'),
              ),
            OutlinedButton(onPressed: () => apply(false), child: const Text('Só este dia')),
            FilledButton(onPressed: () => apply(true), child: Text('Todos os dias ${type.label}')),
          ],
        );
      }),
    );
  }

  Future<void> _swap() async {
    DateTime other = selected.add(const Duration(days: 1));
    final colleague = TextEditingController();
    final note = TextEditingController();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Trocar dois plantões'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Dia selecionado: ${_dateKey(selected)} (${store.originalType(selected).label})'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: ctx, initialDate: other, firstDate: DateTime(2025), lastDate: DateTime(2035));
              if (d != null) setDialog(() => other = d);
            },
            icon: const Icon(Icons.calendar_month), label: Text('Trocar com: ${_dateKey(other)}'),
          ),
          TextField(controller: colleague, decoration: const InputDecoration(labelText: 'Colega (opcional)')),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Observação (opcional)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              await store.addSwap(selected, other, colleague: colleague.text.trim(), note: note.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Confirmar troca'),
          ),
        ],
      )),
    );
  }

  Future<void> _settings() async {
    final samu = TextEditingController(text: store.samuStart);
    final priv = TextEditingController(text: store.privateStart);
    final alarmS = TextEditingController(text: store.samuAlarm);
    final alarmP = TextEditingController(text: store.privateAlarm);
    var duration = store.durationHours;
    var startDay = _day(store.startDate);
    var first = store.firstType;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Configurar horários e alarmes'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: ctx, initialDate: startDay, firstDate: DateTime(2020), lastDate: DateTime(2035));
              if (d != null) setDialog(() => startDay = _day(d));
            },
            icon: const Icon(Icons.event), label: Text('Início da escala: ${_fmt(startDay)}'),
          ),
          DropdownButtonFormField<WorkType>(
            value: first, decoration: const InputDecoration(labelText: 'Plantão nesse dia de início'),
            items: const [
              DropdownMenuItem(value: WorkType.samu, child: Text('SAMU')),
              DropdownMenuItem(value: WorkType.particular, child: Text('Particular')),
            ],
            onChanged: (v) => setDialog(() => first = v ?? first),
          ),
          const SizedBox(height: 12),
          TextField(controller: samu, decoration: const InputDecoration(labelText: 'Entrada SAMU (HH:mm)'), keyboardType: TextInputType.datetime),
          TextField(controller: priv, decoration: const InputDecoration(labelText: 'Entrada particular (HH:mm)'), keyboardType: TextInputType.datetime),
          const SizedBox(height: 12),
          TextField(controller: alarmS, decoration: const InputDecoration(labelText: 'Hora do alarme SAMU (HH:mm)'), keyboardType: TextInputType.datetime),
          TextField(controller: alarmP, decoration: const InputDecoration(labelText: 'Hora do alarme particular (HH:mm)'), keyboardType: TextInputType.datetime),
          DropdownButtonFormField<int>(
            value: duration, decoration: const InputDecoration(labelText: 'Duração do plantão'),
            items: [6, 8, 12, 24].map((v) => DropdownMenuItem(value: v, child: Text('$v horas'))).toList(),
            onChanged: (v) => setDialog(() => duration = v ?? duration),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              if (![samu.text, priv.text, alarmS.text, alarmP.text].every(_validTime)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe horários válidos no formato HH:mm.')));
                return;
              }
              store.samuStart = samu.text;
              store.privateStart = priv.text;
              store.samuAlarm = alarmS.text;
              store.privateAlarm = alarmP.text;
              store.durationHours = duration;
              store.startDate = startDay;
              store.firstType = first;
              await store.save();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Salvar'),
          ),
        ],
      )),
    );
  }

  bool _validTime(String s) {
    final m = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').firstMatch(s);
    return m != null;
  }

  Color _baseColor(DateTime date) {
    if (_isBeforeStart(date)) return Colors.blueGrey;
    final st = store.overrideFor(date)?.status ?? DayStatus.normal;
    if (st == DayStatus.folga) return const Color(0xFF2E7D32);
    if (st == DayStatus.ausencia) return const Color(0xFFEF6C00);
    return store.effectiveType(date).color;
  }

  Widget _heroCard() {
    final type = store.effectiveType(selected);
    final status = store.overrideFor(selected)?.status ?? DayStatus.normal;
    final note = store.overrideFor(selected)?.note ?? '';
    final before = _isBeforeStart(selected);
    final base = _baseColor(selected);
    final normal = !before && status == DayStatus.normal;

    final start = store.startOn(selected);
    final sp = start.split(':');
    final end = '${((int.parse(sp[0]) + store.durationHours) % 24).toString().padLeft(2, '0')}:${sp[1]}';

    final title = before ? 'Sem escala' : status == DayStatus.folga ? 'Folga' : status == DayStatus.ausencia ? 'Ausência' : type.label;
    final icon = before ? Icons.hourglass_empty : status == DayStatus.folga ? Icons.beach_access
        : status == DayStatus.ausencia ? Icons.event_busy : type == WorkType.samu ? Icons.local_hospital : Icons.airport_shuttle;
    final swapped = !before && type != store.originalType(selected);

    final btnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [base, Color.lerp(base, Colors.black, .3)!]),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: base.withValues(alpha: .35), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_weekdays[selected.weekday - 1]}, ${selected.day} de ${_months[selected.month - 1].toLowerCase()}',
          style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1.1)),
            if (!before && status != DayStatus.normal)
              Text('Escala do dia: ${type.label}', style: const TextStyle(color: Colors.white70)),
            if (before)
              Text('A escala começa em ${_fmt(store.startDate)}', style: const TextStyle(color: Colors.white70)),
          ])),
        ]),
        if (normal) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _Pill(icon: Icons.schedule, text: '$start – $end'),
            _Pill(icon: Icons.alarm, text: 'Alarme ${store.alarmOn(selected)}${store.hasTimeOverride(selected) ? ' •  só este dia' : ''}'),
            if (swapped) _Pill(icon: Icons.swap_horiz, text: 'Troca (original: ${store.originalType(selected).label})'),
          ]),
        ],
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(note, style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(style: btnStyle, onPressed: before ? null : _editTimes, icon: const Icon(Icons.alarm, size: 18), label: const Text('Horário')),
          OutlinedButton.icon(style: btnStyle, onPressed: before ? null : _editDay, icon: const Icon(Icons.edit_calendar, size: 18), label: const Text('Folga / ausência')),
          OutlinedButton.icon(style: btnStyle, onPressed: before ? null : _swap, icon: const Icon(Icons.swap_horiz, size: 18), label: const Text('Trocar')),
        ]),
      ]),
    );
  }

  Widget _calendarCard() {
    final cs = Theme.of(context).colorScheme;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = ((firstWeekday + daysInMonth + 6) ~/ 7) * 7;
    final today = _day(DateTime.now());

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(28)),
      child: Column(children: [
        Row(children: [
          IconButton(onPressed: () => _shiftMonth(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Mês anterior'),
          Expanded(child: Text('${_months[month.month - 1]} ${month.year}',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          IconButton(onPressed: () => _shiftMonth(1), icon: const Icon(Icons.chevron_right), tooltip: 'Próximo mês'),
          IconButton.filledTonal(
            onPressed: () => selecting ? _exitSelecting() : setState(() => selecting = true),
            icon: Icon(selecting ? Icons.close : Icons.checklist),
            tooltip: selecting ? 'Cancelar seleção' : 'Selecionar vários dias',
          ),
        ]),
        if (selecting) ...[
          const SizedBox(height: 4),
          Text(picked.isEmpty ? 'Toque nos dias para marcar' : '${picked.length} dia(s) marcado(s)',
            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, alignment: WrapAlignment.center, children: [
            ActionChip(avatar: const Icon(Icons.circle, size: 12, color: Color(0xFFD32F2F)), label: const Text('Todos SAMU'), onPressed: () => _pickType(WorkType.samu)),
            ActionChip(avatar: const Icon(Icons.circle, size: 12, color: Color(0xFF1976D2)), label: const Text('Todos particular'), onPressed: () => _pickType(WorkType.particular)),
            ActionChip(avatar: const Icon(Icons.clear_all, size: 16), label: const Text('Limpar'), onPressed: () => setState(picked.clear)),
          ]),
        ],
        const SizedBox(height: 10),
        Row(children: [
          for (final l in const ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'])
            Expanded(child: Center(child: Text(l, style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)))),
        ]),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          itemCount: cells,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 6, crossAxisSpacing: 6),
          itemBuilder: (context, index) {
            final day = index - firstWeekday + 1;
            if (day < 1 || day > daysInMonth) return const SizedBox.shrink();
            final date = DateTime(month.year, month.month, day);
            final pre = _isBeforeStart(date);
            final color = _baseColor(date);
            final isSel = selecting ? picked.contains(date) : date == _day(selected);
            final custom = !pre && store.hasTimeOverride(date);
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: (pre && selecting) ? null : () => setState(() {
                selected = date;
                if (selecting && !picked.remove(date)) picked.add(date);
              }),
              onLongPress: pre ? null : () => setState(() {
                selecting = true;
                selected = date;
                picked.add(date);
              }),
              child: Container(
                decoration: BoxDecoration(
                  color: isSel ? color : (pre ? Colors.transparent : color.withValues(alpha: .15)),
                  borderRadius: BorderRadius.circular(14),
                  border: date == today ? Border.all(color: cs.onSurface, width: 1.8) : null,
                ),
                child: Stack(alignment: Alignment.center, children: [
                  Text('$day', style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isSel ? Colors.white : (pre ? cs.onSurface.withValues(alpha: .35) : color))),
                  if (custom)
                    Positioned(bottom: 4, child: Icon(Icons.alarm, size: 10, color: isSel ? Colors.white : color)),
                  if (selecting && isSel)
                    const Positioned(top: 2, right: 2, child: Icon(Icons.check_circle, size: 13, color: Colors.white)),
                ]),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        const Wrap(spacing: 14, runSpacing: 6, children: [
          _Legend(color: Color(0xFFD32F2F), label: 'SAMU'),
          _Legend(color: Color(0xFF1976D2), label: 'Particular'),
          _Legend(color: Color(0xFF2E7D32), label: 'Folga'),
          _Legend(color: Color(0xFFEF6C00), label: 'Ausência'),
        ]),
        const SizedBox(height: 6),
        Text('Segure um dia para selecionar vários • ⏰ = horário próprio',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: selecting
          ? FloatingActionButton.extended(
              onPressed: picked.isEmpty ? null : _bulkTimes,
              icon: const Icon(Icons.alarm_add),
              label: Text(picked.isEmpty ? 'Marque os dias' : 'Definir horário (${picked.length})'),
            )
          : null,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 110), children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Plantão 12/36', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              Text('SAMU & Particular', style: TextStyle(color: cs.onSurfaceVariant)),
            ])),
            IconButton.filledTonal(onPressed: _settings, icon: const Icon(Icons.tune), tooltip: 'Horários padrão'),
          ]),
          const SizedBox(height: 16),
          _heroCard(),
          const SizedBox(height: 16),
          _calendarCard(),
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Pill({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(14)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: Colors.white),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 5), Text(label, style: Theme.of(context).textTheme.bodySmall),
  ]);
}