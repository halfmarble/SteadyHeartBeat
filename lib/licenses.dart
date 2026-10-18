import 'package:flutter/foundation.dart';

/// Notices that Flutter's license page cannot collect on its own. Dart package
/// and engine licenses are registered automatically; these two are not
/// packages: the voice clips are audio rendered offline, and the Material Icons
/// font is bundled from the Flutter SDK without a notice.
bool _registered = false;

void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() => Stream.fromIterable(const [
        LicenseEntryWithLineBreaks(['Kokoro-82M'], '''
Kokoro-82M by hexgrad, licensed under the Apache License 2.0
(http://www.apache.org/licenses/LICENSE-2.0).
Source: https://huggingface.co/hexgrad/Kokoro-82M

Built on StyleTTS 2 (Li et al., MIT License,
https://github.com/yl4579/StyleTTS2).

The app's voice is audio clips produced by this model, rendered offline. The
app does not include or run the model.'''),
        LicenseEntryWithLineBreaks(['Material Icons'], '''
Material Icons font by Google, as distributed with the Flutter SDK, licensed
under the Creative Commons Attribution 4.0 International License
(https://creativecommons.org/licenses/by/4.0/).

This app includes a subset of the font, reduced to the icons it uses.'''),
      ]));
}
