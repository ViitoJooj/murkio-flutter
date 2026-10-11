/// Murkio identity for Flutter.
///
/// Initialize once with the publishable key, then use the canvas or the
/// standalone widgets:
///
/// ```dart
/// await Murkio.initialize(publishableKey: 'pk_...');
/// ```
library;

export 'src/api.dart'
    show ApiClient, MfaEnrollment, MfaEnrollmentResult, defaultApiUrl;
export 'src/canvas/layout.dart'
    show CanvasLayoutName, CanvasPlacement, CanvasRect, chooseLayout, place;
export 'src/canvas/model.dart';
export 'src/canvas/validate.dart'
    show SanitizeResult, defaultCanvas, pickCanvas, sanitizeDocument;
export 'src/errors.dart';
export 'src/flow.dart';
export 'src/i18n.dart' show murkioString;
export 'src/models.dart'
    show
        AccessClaims,
        ClientBootstrap,
        LoginMfa,
        LoginResult,
        LoginSession,
        MfaChallenge,
        MurkioUser,
        PublicConfig,
        TokenPair;
export 'src/murkio.dart' show Murkio, MurkioHttpClient, MurkioUrlOpener;
export 'src/session.dart' show MurkioSession, SessionManager;
export 'src/storage.dart';
export 'src/widgets/canvas.dart' show MurkioIdentityCanvas, MurkioScreen;
export 'src/widgets/fields.dart'
    show
        MurkioAuthBuilder,
        MurkioButtonBuilder,
        MurkioFormController,
        MurkioIdentityEmailInput,
        MurkioIdentityError,
        MurkioIdentityForm,
        MurkioIdentityKeepLogged,
        MurkioIdentityLoginButton,
        MurkioIdentityPasswordInput,
        MurkioIdentityRegisterButton;
