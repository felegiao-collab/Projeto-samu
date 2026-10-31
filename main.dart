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

  DateTime startDate = DateTime(2026, 11, 1);
  WorkType firstType = WorkType.samu;
  String samuStart = '19:00';
  String privateStart = '19:00';
  int durationHours = 12;
  String samuAlarm = '17:00';
  String privateAlarm = '17:00';
  final Map<String, DayOverride> overrides = {};
  final List<SwapRecord> swaps = [];
  final Map<String, DayTimes> timeOverrides = {};

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
    notifyListeners();
    await NotificationService.instance.refresh(this);
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

  Future<void> refresh(PlantaoStore store) async {
    await plugin.cancelAll();
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
    }
  }
}

class PlantaoApp extends StatelessWidget {
  const PlantaoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Controle de Plantão 12/36',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD32F2F)),
    ),
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
  void _changed() { if (mounted) setState(() {}); }

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
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Configurar horários e alarmes'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
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

  @override
  Widget build(BuildContext context) {
    final type = store.effectiveType(selected);
    final override = store.overrideFor(selected);
    final start = store.startOn(selected);
    final startParts = start.split(':');
    final endHour = (int.parse(startParts[0]) + store.durationHours) % 24;
    final end = '${endHour.toString().padLeft(2, '0')}:${startParts[1]}';
    final firstWeekday = DateTime(month.year, month.month, 1).weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = ((firstWeekday + daysInMonth + 6) ~/ 7) * 7;
    final beforeStart = _day(selected).isBefore(_day(store.startDate));
    return Scaffold(
      appBar: AppBar(
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Plantão 12/36', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('SAMU & Particular', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          IconButton(onPressed: _settings, icon: const Icon(Icons.notifications_active_outlined), tooltip: 'Horários e alarmes'),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconButton(onPressed: () => _shiftMonth(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Mês anterior'),
                Expanded(child: Text('${_months[month.month - 1].toUpperCase()} ${month.year}',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(onPressed: () => _shiftMonth(1), icon: const Icon(Icons.chevron_right), tooltip: 'Próximo mês'),
              ]),
              const SizedBox(height: 4),
              const Text('Alternância diária • início em 01/11/2026 com SAMU'),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: const [
                _WeekLabel('D'), _WeekLabel('S'), _WeekLabel('T'), _WeekLabel('Q'),
                _WeekLabel('Q'), _WeekLabel('S'), _WeekLabel('S'),
              ]),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                itemCount: cells,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 5, crossAxisSpacing: 5),
                itemBuilder: (context, index) {
                  final day = index - firstWeekday + 1;
                  if (day < 1 || day > daysInMonth) return const SizedBox.shrink();
                  final date = DateTime(month.year, month.month, day);
                  final t = store.effectiveType(date);
                  final o = store.overrideFor(date);
                  final selectedDay = date == _day(selected);
                  final pre = date.isBefore(_day(store.startDate));
                  final color = pre ? Colors.grey :
                    o?.status == DayStatus.folga ? Colors.green :
                    o?.status == DayStatus.ausencia ? Colors.orange : t.color;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => selected = date),
                    child: Container(
                      decoration: BoxDecoration(
                        color: selectedDay ? color.withValues(alpha: .18) : null,
                        border: Border.all(color: selectedDay ? color : Colors.transparent, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('$day', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      ]),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              const Wrap(spacing: 12, runSpacing: 8, children: [
                _Legend(color: Color(0xFFD32F2F), label: 'SAMU'),
                _Legend(color: Color(0xFF1976D2), label: 'Particular'),
                _Legend(color: Colors.green, label: 'Folga'),
                _Legend(color: Colors.orange, label: 'Ausência'),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Dia ${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              Row(children: [
                CircleAvatar(backgroundColor: type.color.withValues(alpha: .15), child: Icon(type == WorkType.samu ? Icons.local_hospital : Icons.airport_shuttle, color: type.color)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(type.label, style: TextStyle(fontWeight: FontWeight.bold, color: type.color, fontSize: 18)),
                  Text('Escala original: ${store.originalType(selected).label}', style: Theme.of(context).textTheme.bodySmall),
                ])),
                Chip(label: Text(beforeStart ? 'Antes do início' : override?.status == DayStatus.folga ? 'Folga' : override?.status == DayStatus.ausencia ? 'Ausência' : 'Programado')),
              ]),
              const SizedBox(height: 12),
              if (beforeStart) const Text('A escala só começa em 01/11/2026.', style: TextStyle(fontStyle: FontStyle.italic)),
              Text('Horário: $start às $end'),
              Text('Alarme: às ${store.alarmOn(selected)}${store.hasTimeOverride(selected) ? ' (ajustado só neste dia)' : ''}'),
              if (override?.note.isNotEmpty == true) Text('Observação: ${override!.note}'),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: _editTimes, icon: const Icon(Icons.alarm), label: const Text('Horário / alarme')),
                OutlinedButton.icon(onPressed: _editDay, icon: const Icon(Icons.edit_calendar), label: const Text('Folga / ausência')),
                FilledButton.icon(onPressed: _swap, icon: const Icon(Icons.swap_horiz), label: const Text('Trocar plantões')),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(child: ListTile(
          leading: const Icon(Icons.save_outlined),
          title: const Text('Dados salvos no aparelho'),
          subtitle: const Text('Regras, folgas, ausências e trocas ficam armazenadas localmente.'),
          trailing: IconButton(onPressed: _settings, icon: const Icon(Icons.settings)),
        )),
      ]),
    );
  }
}

class _WeekLabel extends StatelessWidget {
  final String label;
  const _WeekLabel(this.label);
  @override
  Widget build(BuildContext context) => SizedBox(width: 30, child: Center(child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))));
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 5), Text(label, style: Theme.of(context).textTheme.bodySmall),
  ]);
}
