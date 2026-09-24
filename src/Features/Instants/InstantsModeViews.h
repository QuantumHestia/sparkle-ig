#import <UIKit/UIKit.h>

/// Which Instants page a window is showing, answered without walking the view tree.
///
/// The header's `layoutSubviews` runs many times a second while the viewer animates, and three
/// buttons (action, mark seen, gallery upload) each need to know whether the window shows a
/// snap being consumed or the creation camera. Walking the whole window for that on every pass
/// was the dominant steady-state cost of the Instants header. Instead, the three view classes
/// that answer the question are recorded as they enter a window, and a query only checks those
/// few live instances.
///
/// Every feature that decides who owns the header's right-hand slot must ask through here, so
/// the answers can never diverge between them (divergence is what drew two buttons on top of
/// each other before).

/// The single visibility test for mode detection: the view itself is on a window, not hidden,
/// not faded out, and not collapsed.
FOUNDATION_EXPORT BOOL SPKInstantsModeViewIsVisible(UIView *view);

/// YES when a snap view (`IGQuickSnapImmersiveViewerSingleSnapView`) is visible in `window`.
FOUNDATION_EXPORT BOOL SPKInstantsWindowShowsSnapView(UIWindow *window);

/// YES when the creation camera view (`IGQuickSnapCreationView`) is visible in `window`.
FOUNDATION_EXPORT BOOL SPKInstantsWindowShowsCreationView(UIWindow *window);

/// The visible Instants header button view in `window`, or nil.
FOUNDATION_EXPORT UIView *SPKInstantsVisibleHeaderInWindow(UIWindow *window);

/// Installs the window-entry hooks that keep the registry current. Idempotent; call it from every
/// installer that queries the functions above, before the first query.
FOUNDATION_EXPORT void SPKInstallInstantsModeViewHooks(void);
