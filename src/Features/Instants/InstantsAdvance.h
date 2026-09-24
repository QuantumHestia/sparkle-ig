#import <UIKit/UIKit.h>

/// Moves the Instants viewer forward by exactly one snap, the way a tap on the snap does.
///
/// The viewer's forward tap is handled by its tap controller's
/// `didPressWithGestureRecognizer:`, which reads the press phase and location off the
/// recognizer it is handed. There is no ObjC entry point that advances on its own (the
/// right-margin tap handler fires on a real tap too, but moves nothing when called alone), so
/// the press is replayed: began, changed, ended, a few tens of milliseconds apart, with a
/// detached recognizer that reports that phase and the centre of the snap stack. Instagram's own
/// recognizer is never touched. Going through the real tap path keeps everything downstream
/// intact, including the service update that tells the resolver which snap is on screen.
///
/// On the last snap this behaves exactly like tapping it by hand.
///
/// `hint` is any view in the viewer's window, used to find the snap stack without searching
/// every window. Returns NO when there is no visible snap stack to advance.
FOUNDATION_EXPORT BOOL SPKInstantsAdvanceViewer(UIView *hint);
