import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml_events.dart';

import 'package:knc/errors.dart';
import 'mapping.dart';
import 'dbf.dart';
import 'knc.dart';

import 'package:path/path.dart' as p;

/// преобразует число из минут в доли градуса
/// - `1.30` в минутах => `1.50` в градусах
double convertAngleMinuts2Gradus(final double val) {
  var v = (val % 1.0);
  return val + (v * 10.0 / 6.0) - v;
}

/// Возвращает разобраный тип данных угла
/// - `true` - минуты
/// - `false` - градусы
/// - `null` - неудалось разобрать
bool parseAngleType(final String txt) {
  // 11.30 град'мин.
  var k = txt.indexOf("'");
  if (k == -1) {
    return null;
  }
  switch (txt[k + 1].toLowerCase()) {
    case 'м':
      return true;
      break;
    case 'г':
      return false;
      break;
    default:
      return null;
  }
}

/// Конечные данные инклинометрии (одна точка)
class InkDataOneLineFinal {
  /// Глубина точки
  double depth;

  /// Угол (градусы)
  double angle;

  /// Азимут (градусы)
  double azimuth;

  static const length = 3;

  InkDataOneLineFinal(this.depth, this.angle, this.azimuth);

  void operator []=(final int i, final double val) {
    switch (i) {
      case 0:
        depth = val;
        break;
      case 1:
        angle = val;
        break;
      case 2:
        azimuth = val;
        break;
      default:
        throw RangeError.index(i, this, 'index', null, length);
    }
  }

  double operator [](final int i) {
    switch (i) {
      case 0:
        return depth;
      case 1:
        return angle;
      case 2:
        return azimuth;
      default:
        throw RangeError.index(i, this, 'index', null, length);
    }
  }

  /// Сохранение данных в бинарном виде
  void save(final IOSink io) {
    final bl = ByteData(8 * length);
    for (var i = 0; i < length; i++) {
      bl.setFloat64(8 * i, this[i]);
    }
    io.add(bl.buffer.asUint8List());
  }
}

/// Конечные данные инклинометрии
class SingleInkData {
  /// Путь к оригиналу файла
  final String origin;

  /// Наименование скважины
  final String well;

  /// Начальная глубина
  final double strt;

  /// Конечная глубина
  final double stop;

  /// Данные инклинометрии
  final List<InkDataOneLineFinal> data;

  SingleInkData(this.origin, this.well, this.strt, this.stop, this.data);

  /// Получить данные с помощью разобранных INK данных файла
  static SingleInkData getByInkData(final InkData ink) => SingleInkData(
      ink.origin,
      ink.well,
      ink.data.first.depthN,
      ink.data.last.depthN,
      ink.data
          .map((e) => InkDataOneLineFinal(e.depthN, e.angleN,
              ink.angleN != null ? e.azimuthN + ink.angleN : e.azimuthN))
          .toList(growable: false));

  /// Оператор сравнения на совпадение
  @override
  bool operator ==(dynamic other) {
    if (other is SingleInkData) {
      return well == other.well &&
          strt == other.strt &&
          stop == other.stop &&
          data.length == other.data.length;
    } else {
      return false;
    }
  }

  @override
  String toString() =>
      '[Origin: "$origin", Well: "$well", Strt: $strt, Stop: $stop, Points: ${data.length}]';

  /// Сохранение данных в бинарном виде
  void save(final IOSink io) {
    if (origin != null) {
      io.add(utf8.encoder.convert(origin));
    }
    io.add([0]);
    if (well != null) {
      io.add(utf8.encoder.convert(well));
    }
    io.add([0]);
    final bb = ByteData(20);
    bb.setFloat64(0, strt);
    bb.setFloat64(8, stop);
    bb.setUint32(16, data.length);
    io.add(bb.buffer.asUint8List());
    for (var i = 0; i < data.length; i++) {
      data[i].save(io);
    }
  }
}

/// Класс хранящий базу данных с инклинометрией
class InkDataBase {
  /// База данных, где ключём является Имя скважины
  var db = <String, List<SingleInkData>>{};

  /// Сохранение данных в бинарном виде в файл
  /// - `+{key1}{0}{listLen1}LIST{SingleInkData1}`
  /// - `+{key2}{0}{listLen2}LIST{SingleInkData2}`
  /// - `...`
  /// - `{0}`
  Future save(final String path) async {
    final io = File(path).openWrite(encoding: null, mode: FileMode.writeOnly);
    db.forEach((key, value) {
      io.add(['+'.codeUnits[0]]);
      io.add(utf8.encoder.convert(key));
      io.add([0]);
      final bb = ByteData(4);
      bb.setUint32(0, value.length);
      io.add(bb.buffer.asUint8List());
      for (final item in value) {
        item.save(io);
      }
    });
    io.add([0]);
    await io.flush();
    await io.close();
  }

  /// Загрузка бинарных данных
  Future load(final String path) async {
    final buf = await File(path).readAsBytes();
    var offset = 0;
    db.clear();
    while (buf[offset] == '+'.codeUnits[0]) {
      offset += 1;
      var iNull = 0;
      while (buf[offset + iNull] != 0) {
        iNull += 1;
      }
      final key = utf8.decoder.convert(buf.sublist(offset, offset + iNull));
      offset += iNull + 1;
      db[key] = <SingleInkData>[];
      db[key].length = ByteData.view(buf.buffer, offset, 4).getUint32(0);
      offset += 4;
      for (var i = 0; i < db[key].length; i++) {
        iNull = 0;
        while (buf[offset + iNull] != 0) {
          iNull += 1;
        }
        final origin =
            utf8.decoder.convert(buf.sublist(offset, offset + iNull));
        offset += iNull + 1;
        iNull = 0;
        while (buf[offset + iNull] != 0) {
          iNull += 1;
        }
        final well = utf8.decoder.convert(buf.sublist(offset, offset + iNull));
        offset += iNull + 1;
        final bb = ByteData.view(buf.buffer, offset, 20);
        offset += 20;
        final strt = bb.getFloat64(0);
        final stop = bb.getFloat64(8);
        final data = List<InkDataOneLineFinal>(bb.getUint32(16));
        final bl = ByteData.view(
            buf.buffer, offset, 8 * data.length * InkDataOneLineFinal.length);
        offset += 8 * data.length * InkDataOneLineFinal.length;
        for (var i = 0; i < data.length; i++) {
          for (var j = 0; j < InkDataOneLineFinal.length; j++) {
            data[i][j] =
                bl.getFloat64(8 * (i * InkDataOneLineFinal.length + j));
          }
        }
        db[key][i] = SingleInkData(origin, well, strt, stop, data);
      }
    }
  }

  /// Добавляет данные INK файла в базу,
  /// если такие данные уже имеются
  /// то функция вернёт `true` иначе `false`
  bool addInkData(final InkData ink) {
    final dat = ink.inkData;
    if (db[dat.well] == null) {
      db[dat.well] = [];
      db[dat.well].add(dat);
      return false;
    } else {
      for (final scdb in db[dat.well]) {
        if (scdb == dat) {
          // Если совпадают
          return true;
        }
      }
      db[dat.well].add(dat);
      return false;
    }
  }
}

/// Данные одной точки инклинометрии (непреобразованный)
class InkDataLine {
  /// Глубина точки (оригинальная запись)
  String depth;

  /// Глубина точки (числовое значение)
  double depthN;

  /// Угол (оригинальная запись)
  String angle;

  /// Угол (числовое значение в градусах)
  double angleN;

  /// Азимут (оригинальная запись)
  String azimuth;

  /// Азимут (числовое значение в градусах)
  double azimuthN;
}

class InkData {
  /// Путь к оригиналу файла
  String origin;

  /// Название скважины
  String well;

  /// Название площади
  String square;

  /// Диаметр скважины
  String diametr;

  /// Глубина башмака
  String depth;

  /// Угол склонения (оригинальная запись)
  String angle;

  /// Флаг оригинальной записи в град'мин
  bool angleM;

  /// Угол склонения, числовое значение (в градусах и долях градуса)
  double angleN;

  set angleTxt(final String txt) {
    angle = txt;
    angleM = parseAngleType(txt);
    if (angleM == null) {
      _logError(KncError.inkUncorrectAngleType, txt);
    } else {
      var i0 = 0;
      i0 = txt.indexOf(' ');
      if (i0 == -1) {
        i0 = txt.indexOf('г');
      }
      if (i0 == -1) {
        angleN = double.tryParse(txt);
      } else {
        angleN = double.tryParse(txt.substring(0, i0));
      }
      if (angleN == null) {
        _logError(KncError.parseNumber, txt);
      }
    }
  }

  /// Альтитуда
  String altitude;

  /// Глубина забоя
  String zaboy;

  /// Список данных инклинометрии
  final data = <InkDataLine>[];

  /// Значение рейтинга кодировок
  Map<String, int> encodesRaiting;

  /// Конечная подобранная кодировка
  String encode;

  /// Номер столбца для глубины точек
  var iDepth = -1;

  /// Номер столбца для угла
  var iAngle = -1;

  /// Номер столбца для азимута
  var iAzimuth = -1;

  /// Флаг записи угла в минутах
  bool bAngleMinuts;

  /// Флаг записи азимута в минутах
  bool bAzimuthMinuts;

  /// Номер обрабатываемой строки
  ///
  /// После обработки:
  /// - для текстового файла хранит количество строк в файле
  var lineNum = 0;

  /// Список ошибок (Если он пуст после разбора, то данные корректны)
  final listOfErrors = <ErrorOnLine>[];

  /// Функция записи ошибки (сохраняет внутри класса)
  void _logError(KncError err, [String txt]) =>
      listOfErrors.add(ErrorOnLine(err, lineNum, txt));

  /// Является ли файл файлом с инклинометрией
  var isInk = 0;

  /// Минимальная длина разделителя таблицы (необходим для текстовых файлов)
  static const tableLineLen = 40;

  double get strt => data.isEmpty ? null : data.first.depthN;
  double get stop => data.isEmpty ? null : data.last.depthN;

  SingleInkData _sid;
  SingleInkData get inkData =>
      _sid ?? (_sid = SingleInkData.getByInkData(this));
  InkData();

  /// Преобразует список данных в заголовке второй таблицы
  /// - `true` - если дальше невозможно разбирать данные
  bool _parseSecondTableTitle(final List<String> tbl2title) {
    for (var i = 0; i < tbl2title.length; i++) {
      if (iDepth == -1 && tbl2title[i].startsWith('Глубина')) {
        iDepth = i;
      } else if (iAngle == -1 && tbl2title[i].startsWith('Угол')) {
        iAngle = i;
        bAngleMinuts = parseAngleType(tbl2title[i]);
        if (bAngleMinuts == null) {
          _logError(KncError.inkUncorrectAngleType, tbl2title[i]);
          return true;
        }
      } else if (iAzimuth == -1 && tbl2title[i].startsWith('Азимут')) {
        iAzimuth = i;
        bAzimuthMinuts = parseAngleType(tbl2title[i]);
        if (bAzimuthMinuts == null) {
          _logError(KncError.inkUncorrectAngleType, tbl2title[i]);
          return true;
        }
      }
    }
    if (iDepth == -1 || iAngle == -1 || iAzimuth == -1) {
      _logError(KncError.inkCantGoToSecondTblData, tbl2title.join(' | '));
      return true;
    }
    return false;
  }

  /// Разбирает строку табличных жанных
  /// - Возвращает `null` если произошла ошибка
  InkDataLine _getDataLine(final List<String> row) {
    var l = InkDataLine();
    l.depth = row[iDepth];
    l.depthN = double.tryParse(l.depth);
    if (l.depthN == null) {
      _logError(KncError.parseNumber);
      return null;
    }
    l.angle = row[iAngle];
    l.angleN = double.tryParse(l.angle);
    if (l.angleN == null) {
      _logError(KncError.parseNumber);
      return null;
    } else if (bAngleMinuts) {
      l.angleN = convertAngleMinuts2Gradus(l.angleN);
    }
    l.azimuth = row[iAzimuth];
    l.azimuthN = double.tryParse(
        l.azimuth[0] == '*' ? l.azimuth.substring(1) : l.azimuth);
    if (l.azimuthN == null) {
      _logError(KncError.parseNumber);
      return null;
    } else {
      if (bAzimuthMinuts) {
        l.azimuthN = convertAngleMinuts2Gradus(l.azimuthN);
      }
    }
    return l;
  }

  /// Разбор данных второй таблицы из docx
  /// - `true` - если дальше невозможно разбирать данные
  bool _parseSecondTblData(final List<List<String>> row) {
    if (listOfErrors.isNotEmpty) {
      return true;
    }
    final iLengthDepth =
        row[iDepth].length - (row[iDepth].last.isEmpty ? 1 : 0);
    final iLengthAngle =
        row[iAngle].length - (row[iAngle].last.isEmpty ? 1 : 0);
    final iLengthAzimuth =
        row[iAzimuth].length - (row[iAzimuth].last.isEmpty ? 1 : 0);
    if (iLengthDepth != iLengthAngle || iLengthDepth != iLengthAzimuth) {
      _logError(KncError.inkTableRowCount,
          '$iLengthDepth | $iLengthAngle | $iLengthAzimuth');
      return true;
    }
    for (var i = 0; i < iLengthDepth; i++) {
      // проходим по всем строкам данных
      lineNum = i + 1;
      var l = _getDataLine(row.map((e) => e[i]).toList(growable: false));
      if (l == null) {
        return true;
      }
      data.add(l);
    }
    return false;
  }

  /// проверка на начальные данные файла инклинометрии
  /// - `true` - если строка подходит
  static bool _preTitleBool(final String line) =>
      line == r'Утверждаю' ||
      line == r'Инклинометрия' ||
      line == r'Замер кривизны' ||
      line.startsWith(r'Главный геолог') ||
      line.startsWith(r'Заказчик');

  /// проверка на переход к обработке общих данныз
  /// - `true` - пора переходить к обработке
  static bool _startDataTitleBool(final String line) =>
      line.startsWith(r'Скважина') ||
      line.startsWith(r'Диаметр') ||
      line.startsWith(r'Угол');

  /// Разбор TXT файла с инклинометрией и преобразование к внутреннему представлению
  /// * [bytes] - данные файла в байтовом представлении
  /// * [charMaps] - доступные кодировки
  InkData.txt(final UnmodifiableUint8ListView bytes,
      final Map<String, List<String>> charMaps) {
    // Подбираем кодировку
    encodesRaiting = getMappingRaitings(charMaps, bytes);
    encode = getMappingMax(encodesRaiting);
    // Преобразуем байты из кодировки в символы
    final buffer = String.fromCharCodes(bytes
        .map((i) => i >= 0x80 ? charMaps[encode][i - 0x80].codeUnitAt(0) : i));

    // Нарезаем на линии
    final lines = LineSplitter.split(buffer);

    bool Function(String) section;

    var tbl2title = <String>[];

    /// Разбор второй таблицы
    bool _parseTable2(final String line) {
      if (line.startsWith(''.padLeft(tableLineLen, '-'))) {
        if (isInk < 20) {
          /// обработка первого разделителя
          isInk = 20;
          return false;
        } else if (isInk < 30) {
          /// обработка второго разделителя
          /// обработка заголовка второй таблицы
          if (_parseSecondTableTitle(tbl2title)) {
            return true;
          }

          isInk = 30;
          return false;
        } else if (isInk < 40) {
          /// третий разделитель
          isInk = 40;
          return false;
        } else {
          _logError(KncError.inkUncorrectSecondTableSeparator);
          return true;
        }
      } else if (isInk == 20) {
        // Первая линия заголовка таблицы
        final s = line.split('|');
        for (var i = 0; i < s.length; i++) {
          s[i] = s[i].trim();
        }
        if (s.last.isEmpty) {
          s.length -= 1;
        }
        tbl2title = s;
        isInk = 21;
        return false;
      } else if (isInk == 21) {
        // Последующие линии заголовка таблицы
        var s = line.split('|');
        for (var i = 0; i < s.length; i++) {
          s[i] = s[i].trim();
        }
        if (s.last.isEmpty) {
          s = s.sublist(0, s.length - 1);
        }
        if (s.length != tbl2title.length) {
          _logError(KncError.inkUncorrectTableColumnCount);
          return true;
        }
        for (var i = 0; i < s.length; i++) {
          if (s[i].isNotEmpty) {
            tbl2title[i] += ' ' + s[i];
          }
        }
      } else if (isInk == 30) {
        // строки данных таблицы
        var s = line.split(' ');
        s.removeWhere((e) => e.isEmpty);
        if (s.length != tbl2title.length) {
          _logError(KncError.inkUncorrectTableColumnCount);
          return true;
        }
        final l = _getDataLine(s);
        if (l == null) {
          return true;
        }
        data.add(l);
      }
      return false;
    }

    var tbl1l = 0;

    /// Разбор первой таблицы
    bool _parseTable1(final String line) {
      if (line.startsWith(''.padLeft(tableLineLen, '-'))) {
        if (isInk < 10) {
          isInk = 10;
          tbl1l = line.length;
          return false;
        }
        if (line.length != tbl1l) {
          section = _parseTable2;
          return section(line);
        }
      }
      return false;
    }

    /// Разбор начальных общих данных
    bool _parseTitle(final String line) {
      if (line.startsWith(r'Скважина')) {
        var i0 = line.indexOf(r'N', 8);
        if (i0 == -1) {
          _logError(KncError.inkTitleWellCantGet, line);
          return true;
        }
        var i1 = line.indexOf(r'Площадь', i0);
        if (i1 == -1) {
          well = line.substring(i0 + 1).trim();
          return false;
        }
        well = line.substring(i0 + 1, i1).trim();
        var i2 = line.indexOf(r':', i1 + 7);
        if (i2 == -1) {
          return false;
        }
        square = line.substring(i2 + 1).trim();
        return false;
      } else if (line.startsWith(r'Диаметр')) {
        var i0 = line.indexOf(r':', 8);
        if (i0 == -1) {
          return false;
        }
        var i1 = line.indexOf(r'Глубина', i0 + 1);
        if (i1 == -1) {
          diametr = line.substring(i0 + 1).trim();
          return false;
        }
        diametr = line.substring(i0 + 1, i1).trim();
        var i2 = line.indexOf(r':', i0 + 1);
        if (i2 == -1) {
          return false;
        }
        depth = line.substring(i2 + 1).trim();
      } else if (line.startsWith(r'Угол')) {
        var i0 = line.indexOf(r':', 8);
        if (i0 == -1) {
          _logError(KncError.inkTitleAngleCantGet, line);
          return true;
        }
        var i1 = line.indexOf(r'Альтитуда', i0 + 1);
        if (i1 == -1) {
          angleTxt = line.substring(i0 + 1).trim();
          if (angleN == null) {
            _logError(KncError.inkTitleAngleCantGet, line);
            return true;
          }
          return false;
        }
        angleTxt = line.substring(i0 + 1, i1).trim();
        if (angleN == null) {
          _logError(KncError.inkTitleAngleCantGet, line);
          return true;
        }
        var i2 = line.indexOf(r':', i0 + 1);
        if (i2 == -1) {
          return false;
        }
        var i3 = line.indexOf(r'Забой', i2 + 1);
        if (i3 == -1) {
          altitude = line.substring(i2 + 1).trim();
          return false;
        }
        altitude = line.substring(i2 + 1, i3).trim();
        var i4 = line.indexOf(r':', i2 + 1);
        if (i4 == -1) {
          return false;
        }
        zaboy = line.substring(i4 + 1).trim();
      } else if (line.startsWith(''.padLeft(tableLineLen, '-'))) {
        section = _parseTable1;
        if (well == null || angle == null) {
          _logError(KncError.inkCantGoToFirstTbl);
          return true;
        }
        return section(line);
      }
      return false;
    }

    /// Разбор начальных данных (проверка на инклинометричность)
    bool _parsePreTitle(final String line) {
      if (_preTitleBool(line)) {
        isInk += 1;
        return false;
      }
      if (isInk >= 3 && line.startsWith(''.padLeft(tableLineLen, '-'))) {
        _logError(KncError.inkTitleEnd);
        return true;
      }
      if (_startDataTitleBool(line)) {
        if (isInk < 3) {
          _logError(KncError.inkTitleEnd);
          return true;
        } else {
          section = _parseTitle;
          return section(line);
        }
      }
      return false;
    }

    section = _parsePreTitle;

    lineLoop:
    for (final lineFull in lines) {
      if (section == null) {
        return;
      }
      lineNum += 1;
      final line = lineFull.trim();
      if (line.isEmpty) {
        // Пустую строку и строк с комментарием пропускаем
        continue lineLoop;
      } else {
        if (section(line)) {
          break lineLoop;
        } else {
          continue lineLoop;
        }
      }
    }
  }

  /// Разбор DOCX файла с инклинометрией и преобразование к внутреннему представлению
  /// * [bytes] - данные файла `docx\word\document.xml` в байтовом представлении
  static Future<InkData> getByDocx(final Stream<List<int>> bytes) async {
    final data = [];
    String paragraph;
    List<List<List<String>>> data_tbl;
    final o = InkData();

    bool Function(String) section;

    bool _prepareForStartList(final dynamic rowIn) {
      if (rowIn is List<String>) {
        if (o._parseSecondTableTitle(rowIn)) {
          return true;
        }
      } else if (rowIn is List<List<String>>) {
        if (o._parseSecondTableTitle(
            rowIn.map((e) => e[0]).toList(growable: false))) {
          return true;
        }
      } else {
        o._logError(KncError.inkArgumentNotTable);
      }
      return false;
    }

    /// Разбор начальных общих данных
    bool _parseTitle(final String line) {
      if (line.startsWith(r'Скважина')) {
        var i0 = line.indexOf(r'N', 8);
        if (i0 == -1) {
          o._logError(KncError.inkTitleWellCantGet, line);
          return true;
        }
        var i1 = line.indexOf(r'Площадь', i0);
        if (i1 == -1) {
          o.well = line.substring(i0 + 1).trim();
          return false;
        }
        o.well = line.substring(i0 + 1, i1).trim();
        var i2 = line.indexOf(r':', i1 + 7);
        if (i2 == -1) {
          return false;
        }
        o.square = line.substring(i2 + 1).trim();
        return false;
      } else if (line.startsWith(r'Диаметр')) {
        var i0 = line.indexOf(r':', 8);
        if (i0 == -1) {
          return false;
        }
        var i1 = line.indexOf(r'Глубина', i0 + 1);
        if (i1 == -1) {
          o.diametr = line.substring(i0 + 1).trim();
          return false;
        }
        o.diametr = line.substring(i0 + 1, i1).trim();
        var i2 = line.indexOf(r':', i0 + 1);
        if (i2 == -1) {
          return false;
        }
        o.depth = line.substring(i2 + 1).trim();
      } else if (line.startsWith(r'Угол')) {
        var i0 = line.indexOf(r':', 8);
        if (i0 == -1) {
          o._logError(KncError.inkTitleAngleCantGet, line);
          return true;
        }
        var i1 = line.indexOf(r'Альтитуда', i0 + 1);
        if (i1 == -1) {
          o.angleTxt = line.substring(i0 + 1).trim();
          if (o.angleN == null) {
            o._logError(KncError.inkTitleAngleCantGet, line);
            return true;
          }
          return false;
        }
        o.angleTxt = line.substring(i0 + 1, i1).trim();
        if (o.angleN == null) {
          o._logError(KncError.inkTitleAngleCantGet, line);
          return true;
        }
        var i2 = line.indexOf(r':', i0 + 1);
        if (i2 == -1) {
          return false;
        }
        var i3 = line.indexOf(r'Забой', i2 + 1);
        if (i3 == -1) {
          o.altitude = line.substring(i2 + 1).trim();
          return false;
        }
        o.altitude = line.substring(i2 + 1, i3).trim();
        var i4 = line.indexOf(r':', i2 + 1);
        if (i4 == -1) {
          return false;
        }
        o.zaboy = line.substring(i4 + 1).trim();
      }
      return false;
    }

    /// Разбор начальных данных (проверка на инклинометричность)
    bool _parsePreTitle(final String line) {
      if (_preTitleBool(line)) {
        o.isInk += 1;
        return false;
      }
      if (o.isInk >= 3 && line.startsWith(''.padLeft(tableLineLen, '-'))) {
        o._logError(KncError.inkTitleEnd);
        return true;
      }
      if (_startDataTitleBool(line)) {
        if (o.isInk < 3) {
          o._logError(KncError.inkTitleEnd);
          return true;
        } else {
          section = _parseTitle;
          return section(line);
        }
      }
      return false;
    }

    section = _parsePreTitle;

    await for (final xmlList in bytes
        .transform(Utf8Decoder(allowMalformed: true))
        .transform(XmlEventDecoder())) {
      for (final event in xmlList) {
        if (event is XmlStartElementEvent) {
          if (event.name == 'w:tbl') {
            data_tbl = <List<List<String>>>[];
            data.add(data_tbl);
            // data_tbl = data.last;
            // Начало таблицы
            if (o.isInk < 10) {
              // первая таблица
              o.isInk = 10;
            } else if (o.isInk == 10) {
              // втораяя таблица
              o.isInk = 20;
            }
          }
          if (data_tbl == null) {
            if (event.name == 'w:p') {
              // начало параграфа вне таблицы
              paragraph = '';
              // paragraph = '^';
              if (event.isSelfClosing) {
                // paragraph += r'$';
                data.add(paragraph);
                paragraph = null;
              }
            }
          } else {
            if (event.name == 'w:tr') {
              // строка в таблице
              data_tbl.add([]);
              if (o.isInk >= 20 && o.isInk < 30) {
                o.isInk += 1;
                // isInk = 21 - первая строка второй таблицы
                // isInk = 22 - вторая строка второй таблицы
              }
            }
            if (event.name == 'w:tc') {
              data_tbl.last.add([]);
            }
            if (event.name == 'w:p') {
              paragraph = '';
              // paragraph = '^';
              if (event.isSelfClosing) {
                // paragraph += r'$';
                data_tbl.last.last.add(paragraph);
                paragraph = null;
              }
            }
          }
        } else if (event is XmlEndElementEvent) {
          if (event.name == 'w:tbl') {
            final tblRowHeight = List.filled(data_tbl.length, 0);
            var cells_max = 0;
            for (var r in data_tbl) {
              if (cells_max < r.length) cells_max = r.length;
            }
            final tblCellWidth = List.filled(cells_max, 0);

            for (var ir = 0; ir < data_tbl.length; ir++) {
              final row = data_tbl[ir];
              for (var ic = 0; ic < row.length; ic++) {
                final cell = row[ic];
                if (tblRowHeight[ir] < cell.length) {
                  tblRowHeight[ir] = cell.length;
                }
                for (final p in cell) {
                  if (tblCellWidth[ic] < p.length) {
                    tblCellWidth[ic] = p.length;
                  }
                }
              }
            }
            data_tbl = null;
          } else if (event.name == 'w:tr') {
            if (o.isInk == 21) {
              // Закончили строку заголовка второй таблицы
              if (_prepareForStartList(data_tbl.last)) {
                return o;
              }
            }
            if (o.isInk == 22) {
              // Закончили строку значений второй таблицы
              if (o._parseSecondTblData(data_tbl.last)) {
                return o;
              }
            }
          }
          if (data_tbl == null) {
            // параграф закрыт вне таблиц
            if (event.name == 'w:p') {
              // paragraph += r'$';
              data.add(paragraph.trim());
              final line = paragraph.trim();
              if (section(line)) {
                return o;
              }
              paragraph = null;
            }
          } else {
            // параграф закрыт внутри таблицы
            if (event.name == 'w:p') {
              // paragraph += r'$';
              data_tbl.last.last.add(paragraph);
              paragraph = null;
            }
          }
        } else if (event is XmlTextEvent) {
          if (paragraph == null) {
            data.add(event.text);
          } else {
            paragraph += event.text;
          }
        }
      }
    }

    return o;
  }

  /// Получает данные из базы данных
  /// * [dbf] - база данных DBF
  /// * [map] (opt) - маппинг данных полей
  ///
  /// (прим: `{'GLUB': ['GLU', 'DEPT']}`, вместо поля `GLUB` так же
  /// могут быть использованны поля `GLU` и `DEPT`)
  /// Если в базе данных нет подходящих данных, то возвращает `null`
  static List<InkData> getByDbf(final DbfFile dbf, [dynamic map]) {
    ///  `GLUB`, `UGOL1` (так как он уже в долях) и `AZIMUT` (а азимут без значений после запятой идет), а номер скважины из колонки `NSKV`
    final fields = dbf.fields;
    var iGlub = -1;
    var iUgol = -1;
    var iUgol1 = -1;
    var iAzimut = -1;
    var iNskv = -1;

    for (var i = 0; i < fields.length; i++) {
      final name = fields[i].name.trim().toUpperCase();
      switch (name) {
        case 'GLUB':
          iGlub = i + 1;
          break;
        case 'UGOL':
          iUgol = i + 1;
          break;
        case 'UGOL1':
          iUgol1 = i + 1;
          break;
        case 'AZIMUT':
          iAzimut = i + 1;
          break;
        case 'NSKV':
          iNskv = i + 1;
          break;
        default:
          if (map != null) {
            if (map['GLUB'] != null && map['GLUB'].contains(name)) {
              iGlub = i + 1;
            } else if (map['UGOL'] != null && map['UGOL'].contains(name)) {
              iUgol = i + 1;
            } else if (map['UGOL1'] != null && map['UGOL1'].contains(name)) {
              iUgol1 = i + 1;
            } else if (map['AZIMUT'] != null && map['AZIMUT'].contains(name)) {
              iAzimut = i + 1;
            } else if (map['NSKV'] != null && map['NSKV'].contains(name)) {
              iNskv = i + 1;
            }
          }
      }
    }

    if (iGlub == -1 ||
        iAzimut == -1 ||
        iNskv == -1 ||
        (iUgol == -1 && iUgol1 == -1)) {
      return null;
    }
    final ol = <InkData>[];

    for (var rec in dbf.records) {
      final well = rec[iNskv].trim();

      var bNotAllowed = true;
      for (var i = 0; i < ol.length && bNotAllowed; i++) {
        if (ol[i].well == well) {
          ol[i].data.add(ol[i]._getDataLine(rec));
          bNotAllowed = false;
        }
      }
      if (bNotAllowed) {
        final ink = InkData();
        ink.origin = dbf.origin;
        ink.well = well;
        ink.isInk = 100;

        ink.iDepth = iGlub;
        ink.iAzimuth = iAzimut;
        ink.bAzimuthMinuts = false;
        if (iUgol1 != -1) {
          ink.iAngle = iUgol1;
          ink.bAngleMinuts = false;
        } else {
          ink.iAngle = iUgol;
          ink.bAngleMinuts = true;
        }
        ink.data.add(ink._getDataLine(rec));
        ol.add(ink);
      }
    }

    return ol;
  }

  /// Получает список данных инклинометрии от файла (любого)
  /// с настоящими настройками
  /// - [entity] - файл
  /// - [ss] - настройки
  /// - [handleErrorCatcher] (opt) - обработчик ошибки от архиватора
  static Future<List<InkData>> loadFile(final File entity, final KncTask ss,
      {final Future Function(dynamic e) handleErrorCatcher}) async {
    final bytes = UnmodifiableUint8ListView(await entity.readAsBytes());
    if (bytes.length <= 128) {
      return null;
    }
    const signatureDoc = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    const signatureZip = [
      [0x50, 0x4B, 0x03, 0x04],
      [0x50, 0x4B, 0x05, 0x06],
      [0x50, 0x4B, 0x07, 0x08]
    ];
    var b = true;
    for (var i = 0; i < signatureDoc.length && b; i++) {
      b = bytes[i] == signatureDoc[i];
    }
    if (b) {
      /// Doc file
      final newPath =
          await ss.newerOutInk.lock(p.basename(entity.path) + '.docx');
      final procRes = await ss.doc2x(entity.path, newPath);
      if (procRes != 0) {
        await ss.newerOutInk.unlock(newPath);
        return null;
      }
      if (await File(newPath).exists()) {
        InkData ink;
        try {
          await ss.unzip(newPath,
              (final FileSystemEntity entity2, final String relPath) async {
            if (entity2 is File &&
                p.dirname(entity2.path) == 'word' &&
                p.basename(entity2.path) == 'document.xml') {
              ink = await getByDocx(entity2.openRead());
            }
          });
        } catch (e) {
          if (handleErrorCatcher != null) {
            await handleErrorCatcher(e);
          }
        }
        try {
          await File(newPath).delete();
        } catch (e) {
          if (handleErrorCatcher != null) {
            await handleErrorCatcher(e);
          }
        }
        await ss.newerOutInk.unlock(newPath);
        if (ink != null) {
          return [ink];
        } else {
          return null;
        }
      }
      await ss.newerOutInk.unlock(newPath);
      return null;
    }

    for (var j = 0; j < signatureZip.length && b; j++) {
      b = true;
      for (var i = 0; i < signatureZip[j].length && b; i++) {
        b = bytes[i] == signatureZip[j][i];
      }
      if (b) {
        // Docx file
        InkData ink;
        try {
          await ss.unzip(entity.path,
              (final FileSystemEntity entity2, final String relPath) async {
            if (entity2 is File &&
                p.dirname(entity2.path) == 'word' &&
                p.basename(entity2.path) == 'document.xml') {
              ink = await getByDocx(entity2.openRead());
            }
          });
        } catch (e) {
          if (handleErrorCatcher != null) {
            await handleErrorCatcher(e);
          }
        }
        if (ink != null) {
          return [ink];
        } else {
          return null;
        }
      }
    }

    if (bytes[0] == 0x03) {
      final dbf = DbfFile();
      if (dbf.loadByByteData(bytes.buffer.asByteData())) {
        // Dbf file
        return getByDbf(dbf, ss.inkDbfMap);
      } else {
        return null;
      }
    }

    return [InkData.txt(bytes, ss.ssCharMaps)];
  }
}

@deprecated
class InkDataOLD {
  /// Путь к оригиналу файла
  String origin;

  /// Название скважины
  String well;

  /// Название площади
  String square;

  /// Диаметр скважины
  String diametr;

  /// Глубина башмака
  String depth;

  /// Угол склонения (оригинальная запись)
  String angle;

  /// Флаг оригинальной записи в град'мин
  bool angleM;

  /// Угол склонения, числовое значение (в градусах и долях градуса)
  double angleN;

  /// Альтитуда
  String altitude;

  /// Глубина забоя
  String zaboy;

  final list = <InkDataLine>[];

  bool bInkFile;

  var iDepth = -1;
  var iAngle = -1;
  bool bAngleMinuts;
  var iAzimuth = -1;
  bool bAzimuthMinuts;
  var iseesoo = 0;

  /// Номер обрабатываемой строки
  ///
  /// После обработки, хранит количество строк в файле
  var lineNum = 0;

  final listOfErrors = <String>[];

  /// Значение рейтинга кодировок (действительно только для текстовых файлов)
  Map<String, int> encodesRaiting;

  /// Конечная подобранная кодировка (действительно только для текстовых файлов)
  String encode;

  Future future;

  void _logErrorOLD(final String txt) {
    listOfErrors.add('Строка:$lineNum\t$txt');
  }

  void _prepareForTable1() {
    if (well != null && angle != null && altitude != null) {
      iseesoo = 10;
    }
  }

  void _prepareForStartList(final dynamic rowIn) {
    if (rowIn is List<String>) {
      final tt = rowIn;
      for (var i = 0; i < tt.length; i++) {
        if (iDepth == -1 && tt[i].startsWith('Глубина')) {
          iDepth = i;
        } else if (iAngle == -1 && tt[i].startsWith('Угол')) {
          iAngle = i;
          var k = tt[i].indexOf("'");
          if (k == -1) {
            _logErrorOLD(
                'Ненайден разделитель для значения градусов/минуты (Угол)');
          } else {
            var m = tt[i][k + 1].toLowerCase();
            switch (m) {
              case 'м':
                bAngleMinuts = true;
                break;
              case 'г':
                bAngleMinuts = false;
                break;
              default:
                _logErrorOLD(
                    'Некорректный тип для значения градусов/минуты (Угол)');
            }
          }
        } else if (iAzimuth == -1 && tt[i].startsWith('Азимут')) {
          iAzimuth = i;
          var k = tt[i].indexOf("'");
          if (k == -1) {
            _logErrorOLD(
                'Ненайден разделитель для значения градусов/минуты (Азимут)');
          } else {
            var m = tt[i][k + 1].toLowerCase();
            switch (m) {
              case 'м':
                bAzimuthMinuts = true;
                break;
              case 'г':
                bAzimuthMinuts = false;
                break;
              default:
                _logErrorOLD(
                    'Некорректный тип для значения градусов/минуты (Азимут)');
            }
          }
        }
      }
    } else if (rowIn is List<List<String>>) {
      final tt = rowIn;
      for (var i = 0; i < tt.length; i++) {
        if (iDepth == -1 && tt[i][0].startsWith('Глубина')) {
          iDepth = i;
        } else if (iAngle == -1 && tt[i][0].startsWith('Угол')) {
          iAngle = i;
          var k = tt[i][0].indexOf("'");
          if (k == -1) {
            _logErrorOLD(
                'Ненайден разделитель для значения градусов/минуты (Угол)');
          } else {
            var m = tt[i][0][k + 1].toLowerCase();
            switch (m) {
              case 'м':
                bAngleMinuts = true;
                break;
              case 'г':
                bAngleMinuts = false;
                break;
              default:
                _logErrorOLD(
                    'Некорректный тип для значения градусов/минуты (Угол)');
            }
          }
        } else if (iAzimuth == -1 && tt[i][0].startsWith('Азимут')) {
          iAzimuth = i;
          var k = tt[i][0].indexOf("'");
          if (k == -1) {
            _logErrorOLD(
                'Ненайден разделитель для значения градусов/минуты (Азимут)');
          } else {
            var m = tt[i][0][k + 1].toLowerCase();
            switch (m) {
              case 'м':
                bAzimuthMinuts = true;
                break;
              case 'г':
                bAzimuthMinuts = false;
                break;
              default:
                _logErrorOLD(
                    'Некорректный тип для значения градусов/минуты (Азимут)');
            }
          }
        }
      }
    } else {
      _logErrorOLD('Неправильный тип аргумента для функции');
    }
    if (iDepth == -1 ||
        iAngle == -1 ||
        iAzimuth == -1 ||
        bAngleMinuts == null ||
        bAzimuthMinuts == null) {
      _logErrorOLD('Не все данные корректны');
      _logErrorOLD('iDepth         = $iDepth');
      _logErrorOLD('iAngle         = $iAngle');
      _logErrorOLD('iAzimuth       = $iAzimuth');
      _logErrorOLD('bAngleMinuts   = $bAngleMinuts');
      _logErrorOLD('bAzimuthMinuts = $bAzimuthMinuts');
    }
  }

  void _parseAngle() {
    // 11.30 град'мин.
    var k = angle.indexOf("'");
    if (k == -1) {
      _logErrorOLD(
          'Ненайден разделитель для значения градусов/минуты (Угол склонения)');
      return;
    }
    switch (angle[k + 1].toLowerCase()) {
      case 'м':
        angleM = true;
        break;
      case 'г':
        angleM = false;
        break;
      default:
        _logErrorOLD(
            'Некорректный тип для значения градусов/минуты (Угол склонения)');
        return;
    }
    angleN = double.tryParse(angle.substring(0, angle.indexOf(' ')));
    if (angleN == null) {
      _logErrorOLD('Невозможно разобрать значение углас клонения: "$angle"');
      return;
    }
    if (angleM) {
      var v = (angleN % 1.0);
      angleN += (v * 10.0 / 6.0) - v;
    }
  }

  /// bytes <- Stream by File.openRead, await future for complete
  InkDataOLD.docx(final Stream<List<int>> bytes) {
    final data = [];
    String paragraph;
    List<List<List<String>>> data_tbl;

    // Скважина N 1240 Площадь Сотниковская Куст - 0
    var reL1 = RegExp(r'Скважина\s+N(.+)Площадь:?(.+)');
    //Диаметр скважины: 0.216 м. Глубина башмака кондуктора: 380.4 м.
    var reL2 = RegExp(
        r'Диаметр\s+скважины:(.+)Глубина\s+башмака(?:\s+кондуктора):?(.+)');
    // Угол склонения: 11.30 град'мин. Альтитуда: 181.96 м. Забой: 1840.0 м.
    var reL3 = RegExp(r'Угол\s+склонения:?(.+)Альтитуда:?(.+)Забой:?(.+)');

    void _parseSecondTblData(final List<List<String>> row) {
      if (listOfErrors.isNotEmpty) {
        return;
      }
      final iLengthDepth =
          row[iDepth].length - (row[iDepth].last.isEmpty ? 1 : 0);
      final iLengthAngle =
          row[iAngle].length - (row[iAngle].last.isEmpty ? 1 : 0);
      final iLengthAzimuth =
          row[iAzimuth].length - (row[iAzimuth].last.isEmpty ? 1 : 0);
      if (iLengthDepth != iLengthAngle || iLengthDepth != iLengthAzimuth) {
        _logErrorOLD('количество строк в колонках таблицы несовпадает');
        return;
      }
      for (var i = 0; i < iLengthDepth; i++) {
        lineNum = i + 1;
        var l = InkDataLine();
        l.depth = row[iDepth][i];
        l.depthN = double.tryParse(l.depth);
        if (l.depthN == null) {
          _logErrorOLD('Невозможно разобрать значение глубины');
        }
        l.angle = row[iAngle][i];
        l.angleN = double.tryParse(l.angle);
        if (l.angleN == null) {
          _logErrorOLD('Невозможно разобрать значение угла');
        } else if (bAngleMinuts) {
          var v = (l.angleN % 1.0);
          l.angleN += (v * 10.0 / 6.0) - v;
        }
        l.azimuth = row[iAzimuth][i];
        l.azimuthN = double.tryParse(
            l.azimuth[0] == '*' ? l.azimuth.substring(1) : l.azimuth);
        if (l.azimuthN == null) {
          _logErrorOLD('Невозможно разобрать значение азимута');
        } else {
          if (bAzimuthMinuts) {
            var v = (l.azimuthN % 1.0);
            l.azimuthN += (v * 10.0 / 6.0) - v;
          }
          l.azimuthN += angleN;
        }
        list.add(l);
      }
    }

    future = bytes
        .transform(Utf8Decoder(allowMalformed: true))
        .transform(XmlEventDecoder())
        .listen((events) {
      for (var event in events) {
        if (event is XmlStartElementEvent) {
          if (event.name == 'w:tbl') {
            data_tbl = <List<List<String>>>[];
            data.add(data_tbl);
            // data_tbl = data.last;

            if (iseesoo == 10) {
              iseesoo = 11;
            }
            if (iseesoo == 12) {
              iseesoo = 20;
            }
          }
          if (data_tbl == null) {
            if (event.name == 'w:p') {
              paragraph = '';
              // paragraph = '^';
              if (event.isSelfClosing) {
                // paragraph += r'$';
                data.add(paragraph);
                paragraph = null;
              }
            }
          } else {
            if (event.name == 'w:tr') {
              data_tbl.add([]);
              if (iseesoo >= 20 && iseesoo < 30) {
                iseesoo += 1;
              }
            }
            if (event.name == 'w:tc') {
              data_tbl.last.add([]);
            }
            if (event.name == 'w:p') {
              paragraph = '';
              // paragraph = '^';
              if (event.isSelfClosing) {
                // paragraph += r'$';
                data_tbl.last.last.add(paragraph);
                paragraph = null;
              }
            }
          }
        } else if (event is XmlEndElementEvent) {
          if (event.name == 'w:tbl') {
            final tblRowHeight = List.filled(data_tbl.length, 0);
            var cells_max = 0;
            for (var r in data_tbl) {
              if (cells_max < r.length) cells_max = r.length;
            }
            final tblCellWidth = List.filled(cells_max, 0);

            for (var ir = 0; ir < data_tbl.length; ir++) {
              final row = data_tbl[ir];
              for (var ic = 0; ic < row.length; ic++) {
                final cell = row[ic];
                if (tblRowHeight[ir] < cell.length) {
                  tblRowHeight[ir] = cell.length;
                }
                for (final p in cell) {
                  if (tblCellWidth[ic] < p.length) {
                    tblCellWidth[ic] = p.length;
                  }
                }
              }
            }
            data_tbl = null;
            if (iseesoo == 11) {
              iseesoo = 12;
            }
            if (iseesoo >= 20 && iseesoo < 30) {
              iseesoo = 30;
            }
          } else if (event.name == 'w:tr') {
            if (iseesoo == 21) {
              // Закончили строку заголовка второй таблицы
              _prepareForStartList(data_tbl.last);
            }
            if (iseesoo == 22) {
              // Закончили строку значений второй таблицы
              _parseSecondTblData(data_tbl.last);
            }
          }
          if (data_tbl == null) {
            if (event.name == 'w:p') {
              // paragraph += r'$';
              data.add(paragraph);
              final line = paragraph.trim();
              if (line == 'Утверждаю' ||
                  line == 'Замер кривизны' ||
                  line.startsWith('Заказчик')) {
                iseesoo += 1;
                bInkFile = iseesoo >= 2;
              } else if (iseesoo >= 2 && iseesoo < 10) {
                if (well == null) {
                  final rem = reL1.firstMatch(line);
                  if (rem != null) {
                    well = rem.group(1).trim();
                    square = rem.group(2).trim();
                    iseesoo += 1;
                    _prepareForTable1();
                  }
                }
                if (diametr == null) {
                  final rem = reL2.firstMatch(line);
                  if (rem != null) {
                    diametr = rem.group(1).trim();
                    depth = rem.group(2).trim();
                    iseesoo += 1;
                    _prepareForTable1();
                  }
                }
                if (angle == null) {
                  final rem = reL3.firstMatch(line);
                  if (rem != null) {
                    angle = rem.group(1).trim();
                    altitude = rem.group(2).trim();
                    zaboy = rem.group(3).trim();
                    _parseAngle();
                    iseesoo += 1;
                    _prepareForTable1();
                  }
                }
              }
              paragraph = null;
            }
          } else {
            if (event.name == 'w:p') {
              // paragraph += r'$';
              data_tbl.last.last.add(paragraph);
              paragraph = null;
            }
          }
        } else if (event is XmlTextEvent) {
          if (paragraph == null) {
            data.add(event.text);
          } else {
            paragraph += event.text;
          }
        }
      }
    }).asFuture(this);
  }

  InkDataOLD.txt(final UnmodifiableUint8ListView bytes,
      final Map<String, List<String>> charMaps) {
    bInkFile = false;
    // Подбираем кодировку
    encodesRaiting = Map.unmodifiable(getMappingRaitings(charMaps, bytes));
    encode = getMappingMax(encodesRaiting);
    // Преобразуем байты из кодировки в символы
    final buffer = String.fromCharCodes(bytes
        .map((i) => i >= 0x80 ? charMaps[encode][i - 0x80].codeUnitAt(0) : i));
    // Нарезаем на линии
    final lines = LineSplitter.split(buffer);

    var tbl1len = 0;
    var tbl2 = <List<String>>[];

    void parseListLine(final List<String> s) {
      var l = InkDataLine();
      l.depth = s[iDepth];
      l.depthN = double.tryParse(l.depth);
      if (l.depthN == null) {
        _logErrorOLD('Невозможно разобрать значение глубины');
      }
      l.angle = s[iAngle];
      l.angleN = double.tryParse(l.angle);
      if (l.angleN == null) {
        _logErrorOLD('Невозможно разобрать значение угла');
      } else if (bAngleMinuts) {
        var v = (l.angleN % 1.0);
        l.angleN += (v * 10.0 / 6.0) - v;
      }
      l.azimuth = s[iAzimuth];
      l.azimuthN = double.tryParse(
          l.azimuth[0] == '*' ? l.azimuth.substring(1) : l.azimuth);
      if (l.azimuthN == null) {
        _logErrorOLD('Невозможно разобрать значение азимута');
      } else {
        if (bAzimuthMinuts) {
          var v = (l.azimuthN % 1.0);
          l.azimuthN += (v * 10.0 / 6.0) - v;
        }
        l.azimuthN += angleN;
      }
      list.add(l);
    }

    var reL1 = RegExp(r'Скважина\s+N(.+)Площадь:(.+)');
    var reL2 = RegExp(r'Диаметр\s+скважины:(.+)Глубина\s+башмака:(.+)');
    var reL3 = RegExp(r'Угол\s+склонения:(.+)Альтитуда:(.+)Забой:(.+)');

    lineLoop:
    for (final lineFull in lines) {
      lineNum += 1;
      final line = lineFull.trim();
      if (line.isEmpty) {
        // Пустую строку и строк с комментарием пропускаем
        continue lineLoop;
      } else if (line == 'Утверждаю' ||
          line == 'Замер кривизны' ||
          line.startsWith('Заказчик')) {
        iseesoo += 1;
        bInkFile = iseesoo >= 2;
        continue lineLoop;
      } else if (iseesoo >= 2 && iseesoo < 10) {
        if (well == null) {
          final rem = reL1.firstMatch(line);
          if (rem != null) {
            well = rem.group(1).trim();
            square = rem.group(2).trim();
            iseesoo += 1;
            _prepareForTable1();
            continue lineLoop;
          }
        }
        if (diametr == null) {
          final rem = reL2.firstMatch(line);
          if (rem != null) {
            diametr = rem.group(1).trim();
            depth = rem.group(2).trim();
            iseesoo += 1;
            _prepareForTable1();
            continue lineLoop;
          }
        }
        if (angle == null) {
          final rem = reL3.firstMatch(line);
          if (rem != null) {
            angle = rem.group(1).trim();
            altitude = rem.group(2).trim();
            zaboy = rem.group(3).trim();
            _parseAngle();
            iseesoo += 1;
            _prepareForTable1();
            continue lineLoop;
          }
        }
      } else if (iseesoo == 10) {
        if (line.startsWith('----')) {
          tbl1len = line.length;
          iseesoo = 11;
          continue lineLoop;
        }
        continue lineLoop;
      } else if (iseesoo >= 11 && iseesoo < 20) {
        if (line.startsWith('----')) {
          if (tbl1len == line.length) {
            iseesoo += 1;
            continue lineLoop;
          } else {
            iseesoo = 20;
            continue lineLoop;
          }
        }
        continue lineLoop;
      } else if (iseesoo >= 20) {
        if (iseesoo == 20) {
          var s = line.split('|');
          for (var i = 0; i < s.length; i++) {
            s[i] = s[i].trim();
          }
          if (s.last.isEmpty) {
            s = s.sublist(0, s.length - 1);
          }
          tbl2.add(s);
          iseesoo += 1;
          continue lineLoop;
        } else if (iseesoo == 21) {
          if (line.startsWith('----')) {
            iseesoo += 1;
            _prepareForStartList(tbl2[0]);
            if (listOfErrors.isNotEmpty) {
              break lineLoop;
            }
            continue lineLoop;
          } else {
            var s = line.split('|');
            for (var i = 0; i < s.length; i++) {
              s[i] = s[i].trim();
            }
            if (s.last.isEmpty) {
              s = s.sublist(0, s.length - 1);
            }
            if (s.length != tbl2[0].length) {
              _logErrorOLD('Несовпадает количество столбцов');
              break lineLoop;
            }
            for (var i = 0; i < s.length; i++) {
              var v = s[i].trim();
              if (v.isNotEmpty) {
                tbl2[0][i] += ' ' + v;
              }
            }
            continue lineLoop;
          }
        } else if (iseesoo == 22) {
          if (line.startsWith('----')) {
            iseesoo = 30;
            break lineLoop;
          } else {
            var s = line.split(' ');
            s.removeWhere((e) => e.isEmpty);
            if (s.length != tbl2[0].length) {
              _logErrorOLD('Несовпадает количество столбцов');
              break lineLoop;
            }
            tbl2.add(s);
            parseListLine(s);
            continue lineLoop;
          }
        }
        continue lineLoop;
      } else {
        continue lineLoop;
      }
    }
  }
}