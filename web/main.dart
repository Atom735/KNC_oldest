import 'dart:html';

import 'package:mdc_web/mdc_web.dart';

import 'src/App.dart';
import 'src/CardAddTask.dart';
import 'src/CardTask.dart';
import 'src/DialogAddTask.dart';
import 'src/DialogLogin.dart';
import 'src/DialogRegistration.dart';
import 'src/DialogUser.dart';

/// webdev serve --auto refresh --debug --launch-in-chrome --log-requests
void main() async {
  autoInit();
  await Future.wait([
    App.init(),
    CardAddTask.init(),
    CardTask.init(),
    DialogAddTask.init(),
    DialogLogin.init(),
    DialogRegistration.init(),
    DialogUser.init()
  ]);
  document.querySelectorAll('.mdc-icon-button').forEach((element) {
    MDCRipple(element).unbounded = true;
  });
  App();
}
