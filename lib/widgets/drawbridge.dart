import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../api/core.dart';
import '../generated/l10n/zulip_localizations.dart';
import '../log.dart';
import '../model/binding.dart';
import '../model/store.dart';
import 'app.dart';
import 'dialog.dart';
import 'page.dart';

/// The callback [ZulipApp] uses as [drawbridgeSignIn].
///
/// With `promptFirst`, asks the user whether to sign in
/// before showing [DrawbridgeLoginPage].
Future<String?> showDrawbridgeSignIn(Uri realmUrl, Uri loginUrl, {
  required bool promptFirst,
}) async {
  final navigator = ZulipApp.navigatorKey.currentState;
  if (navigator == null) return null;

  if (promptFirst) {
    final zulipLocalizations = ZulipLocalizations.of(navigator.context);
    final dialog = showSuggestedActionDialog(context: navigator.context,
      title: zulipLocalizations.drawbridgeSessionExpiredTitle,
      message: zulipLocalizations.drawbridgeSessionExpiredMessage(
        realmUrl.toString()),
      actionButtonText: zulipLocalizations.drawbridgeSignInButton);
    if (await dialog.result != true) return null;
  }

  return await navigator.push(DrawbridgeLoginPage.buildRoute(
    realmUrl: realmUrl, loginUrl: loginUrl));
}

/// A page showing the login page of a Drawbridge proxy in a WebView,
/// where the user signs in with a passkey.
///
/// The route completes with the new session cookie value,
/// or null if the user leaves without signing in.
///
/// For passkeys to reach the web page,
/// the WebView needs WebAuthn support in its "browser" mode,
/// so that the passkey is asserted for the page's own origin,
/// as Drawbridge requires.
/// (In "app" mode, the origin would identify the app instead.)
/// That mode requires Android 14+,
/// and the CREDENTIAL_MANAGER_SET_ORIGIN permission in our manifest.
/// The passkey provider (e.g. Bitwarden)
/// may ask the user once whether to trust this app as a browser.
/// See: https://developer.android.com/reference/androidx/webkit/WebSettingsCompat#setWebAuthenticationSupport(android.webkit.WebSettings,int)
///
/// See also [DrawbridgeAuthRequiredException].
class DrawbridgeLoginPage extends StatefulWidget {
  const DrawbridgeLoginPage({
    super.key,
    required this.realmUrl,
    required this.loginUrl,
  });

  static Route<String> buildRoute({required Uri realmUrl, required Uri loginUrl}) {
    return MaterialWidgetRoute(
      page: DrawbridgeLoginPage(realmUrl: realmUrl, loginUrl: loginUrl));
  }

  final Uri realmUrl;
  final Uri loginUrl;

  @override
  State<DrawbridgeLoginPage> createState() => _DrawbridgeLoginPageState();
}

class _DrawbridgeLoginPageState extends State<DrawbridgeLoginPage> {
  WebViewController? _controller;
  bool _passkeysUnsupported = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    final controller = WebViewController();
    if (!await _enablePasskeys(controller)) {
      if (!mounted) return;
      setState(() {
        _passkeysUnsupported = true;
      });
      return;
    }
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: _handleNavigationRequest));
    await controller.loadRequest(widget.loginUrl);
    if (!mounted) return;
    setState(() {
      _controller = controller;
    });
  }

  Future<bool> _enablePasskeys(WebViewController controller) async {
    if (controller.platform case AndroidWebViewController platform) {
      if (ZulipBinding.instance.syncDeviceInfo
            case AndroidDeviceInfo(:final sdkInt) when sdkInt < 34) {
        return false;
      }
      if (!await platform.isWebViewFeatureSupported(
            WebViewFeatureType.webAuthentication)) {
        return false;
      }
      await platform.setWebAuthenticationSupport(
        WebAuthenticationSupport.forBrowser);
      return true;
    }
    // TODO(ios) iOS allows passkeys in a WKWebView only for
    //   the app's associated domains.
    return false;
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null || !url.isScheme('https')) {
      return NavigationDecision.prevent;
    }
    if (url.origin == widget.loginUrl.origin) {
      return NavigationDecision.navigate;
    }
    if (url.origin == widget.realmUrl.origin) {
      // After signing in, Drawbridge sends the page on to the realm,
      // per the `next` parameter in the login URL.
      unawaited(_finish());
    }
    return NavigationDecision.prevent;
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    String? cookie;
    try {
      cookie = await ZulipBinding.instance.getWebViewCookie(
        widget.realmUrl, kDrawbridgeSessionCookieName);
    } catch (e) {
      assert(debugLog('Error reading WebView cookies: $e')); // TODO(log)
    }
    if (!mounted) return;
    // Not [Navigator.pop], which would pop whatever route is on top,
    // like another realm's sign-in page.
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    Navigator.of(context).removeRoute(route, cookie);
  }

  @override
  Widget build(BuildContext context) {
    final zulipLocalizations = ZulipLocalizations.of(context);
    final controller = _controller;

    final Widget body;
    if (_passkeysUnsupported) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Text(zulipLocalizations.drawbridgeErrorPasskeysUnsupported));
    } else if (controller == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = WebViewWidget(controller: controller);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(zulipLocalizations.drawbridgeLoginPageTitle(
          widget.loginUrl.host))),
      body: SafeArea(top: false, child: body));
  }
}
