import 'dart:io';
import 'dart:isolate';

import 'package:knc/async.dart';
import 'package:knc/converters.dart';
import 'package:knc/knc.dart';
import 'package:knc/web.dart';
import 'package:knc/www.dart';

class KncSettingsOnMain extends KncSettingsInternal {
  /// Изолят выоплнения задачи
  Isolate isolate;

  SendPort sendPort;

  final wsList = <WebSocket>[];

  final wsMsgs = <String>[];

  void sendMsg(String txt) {
    lastWsMsg = txt;
    wsMsgs.add(txt);
    for (final ws in wsList) {
      ws.add(txt);
    }
  }

  KncSettingsOnMain(KncSettingsInternal ss) {
    uID = ss.uID;
    ssTaskName = ss.ssTaskName;
    ssPathOut = ss.ssPathOut;
    ssFileExtAr = [];
    ssFileExtAr.addAll(ss.ssFileExtAr);
    ssFileExtLas = [];
    ssFileExtLas.addAll(ss.ssFileExtLas);
    ssFileExtInk = [];
    ssFileExtInk.addAll(ss.ssFileExtInk);
    pathInList = [];
    pathInList.addAll(ss.pathInList);
    ssArMaxSize = ss.ssArMaxSize;
    ssArMaxDepth = ss.ssArMaxDepth;
  }
}

void nullProc(obj) => null;

Future main(List<String> args) async {
  const printDebug = nullProc;

  /// Настройки работы
  final ss = KncSettingsInternal();

  /// Поднятый сервер
  final server = MyServer(Directory(r'web'));

  /// Порт прослушиваемый главным изолятом
  final receivePort = ReceivePort();

  /// Список запущенных задач
  final listOfTasks = <KncSettingsOnMain>[];

  /// Уникальный номер задачи
  var newTaskUID = 1;

  /// Очередь выполнения субпроцессов
  final queueProc = AsyncTaskQueue(8, false);

  /// Конвертер WordConv и архивтор 7zip
  final converters = await MyConverters.init(queueProc);
  await converters.clear();

  /// - in 0`{task.uID}` -
  /// Уникальный номер изолята
  ///
  /// - in 1`{SendPort}` -
  /// Порт для общения с субизолятом с номером uID
  /// - in 1`unzip`, 2`{unzip.uID}`, 3`{pathToArchive}` -
  /// Просьба разархивировать от субизолята
  /// - in 1`zip`, 2`{zip.uID}`, 3`{pathToData}`, 4`{pathToOutput}` -
  /// Просьба запаковать данные в Zip
  /// - in 1`doc2x`, 2`{doc2x.uID}`, 3`{path2doc}`, 4`{path2out}` -
  /// Просьба переконвертировать doc в docx
  /// - in 1`ssPathOut`, 2`{ssPathOut.uID}`, 3`{ssPathOut}` -
  /// Просьба обновить конечный путь
  ///
  /// - out 0`unzip`, 1`{unzip.uID}`, 2`{outputString}` -
  /// Ответ на прозьбу распаковки
  /// - out 0`zip`, 1`{zip.uID}`, 2`{outputString}` -
  /// Ответ на прозьбу запаковать
  /// - out 0`doc2x`, 1`{doc2x.uID}`, 2`{exitCode}` -
  /// Ответ на прозьбу запаковать
  /// - out 0`charMaps`, 1`{ssCharMaps}` -
  /// Данные о кодировках
  /// - out 0`ssPathOut`, 2`{ssPathOut.uID}` -
  /// Ответ на обновление конечного пути
  ///
  /// - in 1`#...` -
  /// Сообщение передаваемое сокету
  ///
  receivePort.listen((final data) async {
    if (data is List && data[0] is int) {
      final uID = data[0] as int;
      var task = listOfTasks.singleWhere((element) => element.uID == uID);
      if (data[1] is SendPort) {
        printDebug('<<<msg[$uID]: SendPort');
        task.sendPort = data[1];
        task.iState = KncTaskState.work;
        server.sendMsgToAll(task.wsUpdateState);
        task.sendPort.send(['charMaps', converters.ssCharMaps]);
        return;
      } else if (data[1] is String) {
        final String dataStr = data[1];
        switch (dataStr) {
          case 'unzip':
            if (data[2] is int) {
              printDebug('<<<msg[$uID]: ${dataStr}(${data[2]}): ${data[3]}');
              final err =
                  await converters.unzip(data[3], null, converters.ssCharMaps);
              task.sendPort.send([dataStr, data[2], err]);
              printDebug('>>>msg[$uID]: ${dataStr}(${data[2]}): $err');
              return;
            }
            break;
          case 'zip':
            if (data[2] is int) {
              printDebug(
                  '<<<msg[$uID]: ${dataStr}(${data[2]}): ${data[3]} => ${data[4]}');
              final err =
                  await converters.zip(data[3], data[4], converters.ssCharMaps);
              task.sendPort.send([dataStr, data[2], err]);
              printDebug('>>>msg[$uID]: ${dataStr}(${data[2]}): $err');
              return;
            }
            break;
          case 'doc2x':
            if (data[2] is int) {
              printDebug(
                  '<<<msg[$uID]: ${dataStr}(${data[2]}): ${data[3]} => ${data[4]}');
              final err = await converters.doc2x(data[3], data[4]);
              task.sendPort.send([dataStr, data[2], err]);
              printDebug('>>>msg[$uID]: ${dataStr}(${data[2]}): $err');
              return;
            }
            break;
          case 'ssPathOut':
            if (data[2] is int) {
              printDebug('<<<msg[$uID]: ${dataStr}(${data[2]}): ${data[3]}');
              task.ssPathOut = data[3];
              task.sendPort.send([dataStr, data[2]]);
              printDebug('>>>msg[$uID]: ${dataStr}(${data[2]})');
              return;
            }
            break;
          default:
            if (dataStr[0] == '#') {
              if (dataStr.startsWith(wwwKncTaskUpdateState)) {
                task.iState = KncTaskState.values[int.tryParse(
                    dataStr.substring(wwwKncTaskUpdateState.length))];
                server.sendMsgToAll(
                    '$wwwKncTaskUpdateState${uID}:${task.iState}');
                return;
              } else if (dataStr.startsWith(wwwKncTaskUpdateXlsTable)) {
                task.pathToTable =
                    dataStr.substring(wwwKncTaskUpdateXlsTable.length);

                task.sendMsg(dataStr);
                server.sendMsgToAll(
                    '$wwwKncTaskUpdateXlsTable${uID}:${wwwPathToTasks}${uID}/${task.pathToTable.substring(task.ssPathOut.length)}');
                return;
              } else {
                task.sendMsg(dataStr);
                server.sendMsgToAll('$wwwKncTaskLastMsg${uID}:${dataStr}');
                printDebug('>>>msg[All]: ^${uID}${dataStr}');
                return;
              }
            }
        }
      }
    }
    print('main: recieved unknown msg {$data}');
  });

  /// Обработка новых подключений ВебСокета
  server.handleWebSocketNew = (final WebSocket socket, final MyServer serv) {
    for (final ss in listOfTasks) {
      socket.add('${wwwKncTaskAdd}${ss.json}');
    }
  };

  server.handleCloseWS = (final WebSocket socket, final MyServer serv) {
    for (final task in listOfTasks) {
      task.wsList.remove(socket);
    }
  };

  server.handleRequestWS =
      (final WebSocket socket, final String msg, final MyServer serv) async {
    if (msg[0] == '^') {
      final uri = Uri.parse(msg, 1);
      final ps = uri.pathSegments;
      if (ps.isEmpty || ps.first != wwwPathToTasks.replaceAll('/', '')) {
        return;
      }
      final n = ps.last;
      final uID = int.tryParse(n);
      if (uID == null || listOfTasks.isEmpty) {
        return;
      }

      final task = listOfTasks.singleWhere((e) => e.uID == uID);
      if (task == null) {
        return;
      }
      task.wsList.add(socket);
      for (var msg in task.wsMsgs) {
        socket.add(msg);
      }
    }
  };

  server.handleRequest =
      (HttpRequest req, String content, MyServer serv) async {
    Future<bool> _sendSettings() async {
      final response = req.response;
      response.headers.contentType = ContentType.html;
      response.statusCode = HttpStatus.ok;
      response.write(ss
          .updateBufferByThis(await File(r'web/index.html').readAsString())
          .replaceAll(r'${{!uniqFormPost}}', '$wwwPathToTasks$newTaskUID'));
      await response.flush();
      await response.close();
      return true;
    }

    if (req.uri.path == '/') {
      return _sendSettings();
    } else if (req.uri.path.startsWith(wwwPathToTasks)) {
      final uri = Uri.tryParse(req.uri.path, wwwPathToTasks.length);
      if (uri == null) {
        return false;
      }
      final ps = uri.pathSegments;
      if (ps.isEmpty) {
        return false;
      }
      final taskUID = int.tryParse(ps.first);
      KncSettingsOnMain task;
      if (taskUID != null) {
        var bNew = true;
        for (var task1 in listOfTasks) {
          if (task1.uID == taskUID) {
            bNew = false;
            task = task1;
            break;
          }
        }
        if (bNew) {
          if (content.isNotEmpty) {
            ss.updateByMultiPartFormData(parseMultiPartFormData(content));
            ss.uID = taskUID;
            final newTask = KncSettingsOnMain(ss);
            listOfTasks.add(newTask);
            newTaskUID += 1;
            final newTaskSettigs = KncTask.fromSettings(ss);
            newTaskSettigs.sendPort = receivePort.sendPort;
            newTask.isolate = await Isolate.spawn(
                KncTask.isolateEntryPoint, newTaskSettigs,
                debugName:
                    'task[${newTaskSettigs.uID}]: "${newTaskSettigs.ssTaskName}"');
            for (final socket in serv.ws) {
              socket.add('${wwwKncTaskAdd}${newTask.json}');
            }
          } else {
            return _sendSettings();
          }
        }
        if (ps.length == 1) {
          final response = req.response;
          response.headers.contentType = ContentType.html;
          response.statusCode = HttpStatus.ok;
          await response.addStream(File(r'web/action.html').openRead());
          await response.flush();
          await response.close();
          return true;
        } else {
          return await server.serveFile(
              File('${task.ssPathOut}/${ps.sublist(1).join('/')}'),
              req.response);
        }
      }
    } else if (req.uri.path == '/lib/www.dart') {
      final response = req.response;
      response.headers.contentType = ct_Dart;
      response.statusCode = HttpStatus.ok;

      await response.addStream(File('lib/www.dart').openRead());
      await response.flush();
      await response.close();
      return true;
    }
    return false;
  };

  await server.bind(80);
}
