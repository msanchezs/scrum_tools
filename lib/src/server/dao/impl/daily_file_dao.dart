import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:scrum_tools/src/daily/daily_entities.dart';
import 'package:scrum_tools/src/server/dao/daily_dao.dart';
import 'package:scrum_tools/src/utils/helpers.dart';

const int _maxBackupAttempts = 200;
const int _maxLastAttempts = 40;
const Duration _oneDay = const Duration(days: 1);

Logger _log = new Logger('daily_file_dao');

String _home = Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'];

typedef T _builderFromMap<T>(Map<String, dynamic> map);

typedef T _transformer<T>(T value);

int compareEntryLogically(DailyEntry entry1, DailyEntry entry2) {
  if (entry1 == entry2) return 0;
  if (entry1 != null && entry2 == null) return 1;
  if (entry1 == null && entry2 != null) return -1;

  if (entry1.scope != entry2.scope) return entry1.scope.compareTo(entry2.scope);

  if (hasValue(entry1.workItemCode) && !hasValue(entry2.workItemCode))
    return 1;

  if (!hasValue(entry1.workItemCode) && hasValue(entry2.workItemCode))
    return -1;

  if (entry1.workItemCode != entry2.workItemCode)
    return entry1.workItemCode.compareTo(entry2.workItemCode);

  if (entry1.process != entry2.process)
    return entry1.process.compareTo(entry2.process);

  if (entry1.teamMemberCode != entry2.teamMemberCode)
    return entry1.teamMemberCode.compareTo(entry2.teamMemberCode);

  return 0;
}

Future _createDirs(List<Directory> dirs) async {
  for (Directory dir in dirs) {
    await _createDir(dir);
  }
}

Future _createDir(Directory dir) async {
  dir.exists().then((bool exists) {
    if (!exists) dir.createSync(recursive: true);
  });
}

/*
File _getGreatest(Directory directory) {
  File file = null;
  directory.listSync(followLinks: false).forEach((FileSystemEntity fse) {
    file = fse is File && (file == null || file.path.compareTo(fse.path) < 0)
        ? fse
        : file;
  });
  return file;
}
*/
String _dateBasedName(DateTime date) {
  String month = _2Digits(date.month);
  String day = _2Digits(date.day);
  return '${date.year}-$month-$day';
}

String _2Digits(int value) {
  String val = value.toString();
  return val.length < 2 ? '0$val' : val;
}


//========================================================================

class _DateBasedRepo<T extends MappableWithDate> {

  Directory _dataDir;
  Directory _backupDir;
  JsonEncoder jsonEncoder = new JsonEncoder.withIndent('  ');
  _builderFromMap<T> _objectBuilder;

  _DateBasedRepo(String rootDir, this._objectBuilder) {
    _dataDir = new Directory(rootDir);
    _backupDir = new Directory('$rootDir${Platform.pathSeparator}backup');
    _createDirs([_dataDir, _backupDir]);
  }

  void _save(T value) {
    if (value != null && value.date != null) {
      Map<String, dynamic> map = value.toMap();
      String json = jsonEncoder.convert(map);
      String name = _dateBasedName(value.date);
      File file = _getClearFile(name);
      file.writeAsStringSync(json, flush: true);
    } else {
      throw 'Cannot save a null value or a value w/o date.';
    }
  }

  String _getContent(DateTime date) {
    File file = _getFile(date);
    return file != null ? file.readAsStringSync() : null;
  }

  T _getObject(DateTime date) {
    String content = _getContent(date);
    if (content != null) {
      T obj = _objectBuilder(JSON.decode(content));
      return obj;
    }
    return null;
  }

  File _getFile(DateTime date) {
    String name = _dateBasedName(date);
    File file = new File(
        '${_dataDir.path}${Platform.pathSeparator}${name}.json');
    return file.existsSync() ? file : null;
  }

  List<String> _getLastContent(DateTime date, int number) {
    if (date == null || number == null) return null;
    List<String> contents = [];
    int attemtps = 0;
    DateTime d = date;
    while (attemtps++ < _maxLastAttempts && contents.length < number) {
      File file = _getFile(d);
      if (file != null) contents.add(file.readAsStringSync());
      if (contents.length == 1 && number == 0) break;
      d = number > 0 ? d.subtract(_oneDay) : d.add(_oneDay);
    }
    if (attemtps >= _maxLastAttempts) _log.warning(
        '_maxLastAttemtps [${_maxLastAttempts}] reached.');
    return contents.length == 0 ? null : contents;
  }

  List<T> _getLastObjects(DateTime date, int number,
      {_transformer transformer}) {
    List<String> contents = _getLastContent(date, number);
    if (contents != null && contents.isNotEmpty) {
      List<T> objects = [];
      contents.forEach((String content) {
        T obj = _objectBuilder(JSON.decode(content));
        if (transformer != null) obj = transformer(obj);
        if (obj != null) objects.add(obj);
      });
      return hasValue(objects) ? objects : null;
    }
    return null;
  }

  /*String _getLast() {
    File file = _getGreatest(_dataDir);
    return file == null ? null : file.readAsStringSync();
  }*/

  File _getClearFile(String name) {
    File file = new File(
        '${_dataDir.path}${Platform.pathSeparator}${name}.json');
    if (file.existsSync()) {
      for (int i = 1; i <= _maxBackupAttempts; i++) {
        String backupPath = '${_backupDir.path}${Platform
            .pathSeparator}${name}_$i.json';
        File backupFile = new File(backupPath);
        if (!backupFile.existsSync()) {
          file.renameSync(backupPath);
          break;
        }
        if (i == _maxBackupAttempts) throw 'Too many attempts to bakup [${file
            .path}].';
      }
    }
    return file;
  }
}

//========================================================================

class DailyFileDAO implements DailyDAO {

  _DateBasedRepo<DailyReport> _dailyRepo;
  _DateBasedRepo<TimeReport>_timeRepo;

  DailyFileDAO([String rootDirectory]) {
    String _root = rootDirectory ??
        '${_home}${Platform.pathSeparator}scrum_repo${Platform
            .pathSeparator}dailies';
    _dailyRepo = new _DateBasedRepo(
        '${_root}${Platform.pathSeparator}daily', DailyReport.buildFromMap);
    _timeRepo = new _DateBasedRepo(
        '${_root}${Platform.pathSeparator}time', TimeReport.buildFromMap);
  }

  @override
  Future saveDailyReport(DailyReport report) {
    if (report != null) {
      report.date ?? new DateTime.now();
      _dailyRepo._save(report);
      return new Future.value(true);
    }
    return new Future.error("'null' DailyReport.");
  }

  @override
  Future saveTimeReport(TimeReport report) {
    if (report != null) {
      report.date ?? new DateTime.now();
      _timeRepo._save(report);
      return new Future.value(true);
    }
    return new Future.error("'null' TimeReport.");
  }

  @override
  Future<DailyReport> getDailyReport(DateTime date) {
    DailyReport report = _dailyRepo._getObject(date);
    return new Future.value(report);
  }

  @override
  Future<List<DailyReport>> getLastDailyReports(
      {DateTime dateReference, int number: 1}) {
    List<DailyReport> list = _dailyRepo._getLastObjects(
        dateReference ?? new DateTime.now(), number,
        transformer: (DailyReport report) {
          //report.sortEntries(compareEntryLogically);
          return report;
        });
    return new Future.value(list);
  }

  @override
  Future<List<String>> getLastDailyReportsAsJson(
      {DateTime dateReference, int number: 1}) {
    return new Future.value(_dailyRepo._getLastContent(
        dateReference ?? new DateTime.now(), number));
  }

/*
  Future getLastDailyReport() {
    return new Future.value(_dailyRepo._getLast());
  }

  Future getLastDailyReports(int number) {
    throw 'Unsupported operation';
  }
  */

}