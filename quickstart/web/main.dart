import 'package:m4d_core/m4d_ioc.dart' as ioc;
import 'package:m4d_components/m4d_components.dart';

Future main() async {
  ioc.Container.bindModules([CoreComponentsModule()]);
  await componentHandler().upgrade();
}
