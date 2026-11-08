import 'package:web/web.dart' as web;

void enterBrowserFullscreen() {
  web.document.documentElement?.requestFullscreen();
}

void exitBrowserFullscreen() {
  if (web.document.fullscreenElement != null) web.document.exitFullscreen();
}
