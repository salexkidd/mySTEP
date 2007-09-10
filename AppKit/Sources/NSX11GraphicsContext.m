/* 
 NSX11GraphicsContext.m
 
 X11 Backend Graphics Context class.  Conceptually, instances of 
 this subclass encapsulate a connection to an X display (X server).
 
 Copyright (C) 1998 Free Software Foundation, Inc.
 
 Author:	Felipe A. Rodriguez <far@pcmagic.net>
 Date:		November 1998
 
 Author:	H. N. Schaller <hns@computer.org>
 Date:		Jan 2006 - completely reworked

 Useful Manuals:
	http://tronche.com/gui/x/xlib											Xlib - basic X11 calls
    http://freetype.sourceforge.net/freetype2/docs/reference/ft2-toc.html	libFreetype2 - API
	http://freetype.sourceforge.net/freetype2/docs/tutorial/step1.html		tutorial
(	http://netmirror.org/mirror/xfree86.org/4.4.0/doc/HTML/Xft.3.html		Xft - freetype glue)
(	http://netmirror.org/mirror/xfree86.org/4.4.0/doc/HTML/Xrandr.3.html	XResize - rotate extension)
	http://netmirror.org/mirror/xfree86.org/4.4.0/doc/HTML/Xrender.3.html	XRender - antialiased, alpha, subpixel rendering
 
 This file is part of the mySTEP Library and is provided
 under the terms of the GNU Library General Public License.
 */ 

/* Notes when dealing with X11:
  - if we need to check that an object is not rotated, check that ctm transformStruct.m12 and .m21 both are 0.0
  - we can't handle any rotation for text drawing (yet)
  - we can't rotatate windows by angles not multiples of 90 degrees
  - note that X11 coordinates are flipped. This is taken into account by the _screen2X11 CTM.
  - But: for NSSizes you have to use -height because of that
  - finally, drawing into a window is relative to the origin
*/

#import "NSX11GraphicsContext.h"

// load full headers (to expand @class forward references)

#import "NSAppKitPrivate.h"
#import "NSApplication.h"
#import "NSAttributedString.h"
#import "NSBezierPath.h"
#import "NSColor.h"
#import "NSCursor.h"
#import "NSFont.h"
#import "NSGraphics.h"
#import "NSGraphicsContext.h"
#import "NSImage.h"
#import "NSScreen.h"
#import "NSWindow.h"
#import "NSPasteboard.h"

#if 1	// all windows are borderless, i.e. the frontend draws the title bar and manages windows directly
#define WINDOW_MANAGER_TITLE_HEIGHT 0
#else
#define WINDOW_MANAGER_TITLE_HEIGHT 23	// number of pixels added by window manager - the content view is moved down by that amount
#endif

#if __linux__	// this is needed for Sharp Zaurus (only) to detect the hinge status
#include <sys/ioctl.h>
#define SCRCTL_GET_ROTATION 0x413c
#endif

typedef struct
{ // WindowMaker window manager support
    CARD32 flags;
    CARD32 window_style;
    CARD32 window_level;
    CARD32 reserved;
    Pixmap miniaturize_pixmap;			// pixmap for miniaturize button 
    Pixmap close_pixmap;				// pixmap for close button 
    Pixmap miniaturize_mask;			// miniaturize pixmap mask 
    Pixmap close_mask;					// close pixmap mask 
    CARD32 extra_flags;
} GSAttributes;

#define GSWindowStyleAttr 					(1<<0)
#define GSWindowLevelAttr 					(1<<1)
#define GSMiniaturizePixmapAttr				(1<<3)
#define GSClosePixmapAttr					(1<<4)
#define GSMiniaturizeMaskAttr				(1<<5)
#define GSCloseMaskAttr						(1<<6)
#define GSExtraFlagsAttr       				(1<<7)

#define GSDocumentEditedFlag				(1<<0)			// extra flags
#define GSWindowWillResizeNotificationsFlag (1<<1)
#define GSWindowWillMoveNotificationsFlag 	(1<<2)
#define GSNoApplicationIconFlag				(1<<5)

#define WMFHideOtherApplications			10
#define WMFHideApplication					12

//
// Class variables
//

static Display *_display;		// we can currently manage only one Display - but several Screens

static Atom _stateAtom;
static Atom _protocolsAtom;
static Atom _deleteWindowAtom;
static Atom _windowDecorAtom;

static NSArray *_XRunloopModes;	// runloop modes to handle X11 events

#if OLD
Window __xKeyWindowNeedsFocus = None;			// xWindow waiting to be focusd
extern Window __xAppTileWindow;
#endif

#if 1	// DEPRECATED - only used in XRView to modify dragging operations - should be handled through the backend interface
unsigned int __modFlags = 0;		// current global modifier flags - updated every keyDown/keyUp event
#endif

static NSMapTable *__WindowNumToNSWindow = NULL;	// map Window to NSWindow

//
//  Private functions
//

static unsigned int xKeyModifierFlags(unsigned int state);
static unsigned short xKeyCode(XEvent *xEvent, KeySym keysym, unsigned int *eventModFlags);
extern void xHandleSelectionRequest(XSelectionRequestEvent *xe);

static XChar2b *XChar2bFromString(NSString *str, BOOL remote)
{ // convert to XChar2b (note that this might be 4 bytes per character although advertized as 2)
	unsigned i, length=[str length];
	static XChar2b *buf;
	static unsigned buflen;	// how much is allocated
	SEL cai=@selector(characterAtIndex:);
	typedef unichar (*CAI)(id self, SEL _cmd, int i);
	CAI imp=(CAI)[str methodForSelector:cai];	// don't try to cache this! Different strings may have different implementations
#if 0
	NSLog(@"sizeof(unichar)=%d sizeof(XChar2b)=%d", sizeof(unichar), sizeof(XChar2b));
#endif
	if(buflen < sizeof(buf[0])*length)
		buf=(XChar2b *) objc_realloc(buf, buflen+=sizeof(buf[0])*(length+20));	// increase buffer size
	if(sizeof(XChar2b) != 2 && remote)
		{ // fix subtle bug when struct alignment rules of the compiler make XChar2b larger than 2 bytes
		for(i=0; i<length; i++)
			{
			unichar c=(*imp)(str, cai,i);
			((XChar2b *) (((short *)buf)+i))->byte1=c>>8;
			((XChar2b *) (((short *)buf)+i))->byte2=c;
			}
		}
	else
		{
		for(i=0; i<length; i++)
			{
			unichar c=(*imp)(str, cai,i);
			buf[i].byte1=c>>8;
			buf[i].byte2=c;
			}
		}
#if 0
	NSLog(@"buf=%@", [NSData dataWithBytesNoCopy:buf length:sizeof(buf[0])*length freeWhenDone:NO]);
#endif
	return buf;
}

// A filter pipeline has some resemblance to the concept of Core Image but runs completely on the CPU

struct pipeline
{ // a filter chain element
	struct pipeline *source;					// filter source (could also be an id)
	struct RGBA8 (*method)(float x, float y);	// get pixel after processing
};

@interface _NSGraphicsPipeline : NSObject
{
	id source;		// source image or _NSGraphicsPipeline subclass
	id parameter;	// a second parameter (other image source, NSAffineTransform etc.)
	@public	// allows us to use (pointer->method)(x, y)
		struct RGBA8 (*method)(float x, float y);	// get pixel after processing
}
@end

/*
 basically, we need the following filter pipeline nodes:
 - sample into RGBA8 (from a given bitmap or XImage)
 - transform (rotate/scale/flip) by CTM
 - clip
 
 - composite (with a second source)
 - interpolate (with adjacent pixels)
 - convert RGBA8 to RGB24 or RGB16
 - store into XImage
 */

static NSString *NSStringFromXRect(XRectangle rect)
{
	return [NSString stringWithFormat:
		@"{%d, %d}, {%u, %u}",
		rect.x,
		rect.y,
		rect.width,
		rect.height];
}

@implementation _NSX11GraphicsContext

// FIXME:

#define _setDirty(rect)	(_dirty=NSUnionRect(_dirty,(rect)))	// enlarge dirty area for double buffer
#define _isDoubleBuffered (((Window) _graphicsPort) != _frontWindow)	

- (void) _setSizeHints;
{
	XSizeHints size_hints;		// also specified as a hint
	size_hints.x=_xRect.x;
	size_hints.y=_xRect.y;
	size_hints.flags = PPosition | USPosition;		
	XSetNormalHints(_display, ((Window) _graphicsPort), &size_hints);
}

- (id) _initWithAttributes:(NSDictionary *) attributes;
{
	NSWindow *window;
	Window win;
	unsigned long valuemask = 0;
	XSetWindowAttributes winattrs;
	XWMHints *wm_hints;
	GSAttributes attrs;
	NSRect frame;
	int styleMask;
	NSBackingStoreType backingType;
	_compositingOperation = NSCompositeCopy;	// this is because we don't call [super _initWithAttributes]
#if 0
	NSLog(@"_NSX11GraphicsContext _initWithAttributes:%@", attributes);
#endif
	window=[attributes objectForKey:NSGraphicsContextDestinationAttributeName];
	frame=[window frame];	// window frame in screen coordinates
#if 0
	NSLog(@"window frame=%@", NSStringFromRect(frame));
#endif
	styleMask=[window styleMask];
	backingType=[window backingType];
	_nsscreen=(_NSX11Screen *) [window screen];	// we know that we only have _NSX11Screen instances
	if(![window isKindOfClass:[NSWindow class]])
		{ [self release]; return nil; }	// must provide a NSWindow
	// check that there isn't a non-rectangular rotation!
	_windowRect.origin=[(NSAffineTransform *) (_nsscreen->_screen2X11) transformPoint:frame.origin];
	_windowRect.size=[(NSAffineTransform *) (_nsscreen->_screen2X11) transformSize:frame.size];
#if 0
	NSLog(@"transformed window frame=%@", NSStringFromRect(frame));
#endif
	if(!(wm_hints = XAllocWMHints())) 
		[NSException raise:NSMallocException format:@"XAllocWMHints() failed"];
#if (WINDOW_MANAGER_TITLE_HEIGHT==0)	// always hide from window manager
	winattrs.override_redirect = True;
	valuemask |= CWOverrideRedirect;
#else
	// FIXME: should be for all windows
	if((styleMask&GSAllWindowMask) == NSBorderlessWindowMask)
		{ // set X override if borderless
		valuemask |= CWOverrideRedirect;
		winattrs.override_redirect = True;
		valuemask |= CWSaveUnder;
		winattrs.save_under = True;
		}
	else
		_windowRect.origin.y -= WINDOW_MANAGER_TITLE_HEIGHT;   // if window manager moves window down by that amount!
#endif
#if 1
	_windowRect.size.height=-_windowRect.size.height;
	NSLog(@"_windowRect %@", NSStringFromRect(_windowRect));	// _windowRect.size.heigh is negative
	_windowRect.size.height=-_windowRect.size.height;
#endif
	_xRect.x=NSMinX(_windowRect);
	_xRect.y=NSMaxY(_windowRect);
	_xRect.width=NSWidth(_windowRect);
	_xRect.height=NSMinY(_windowRect)-NSMaxY(_windowRect);	// _windowRect.size.heigh is negative (!)
	if(_xRect.width == 0) _xRect.width=48;
	if(_xRect.height == 0) _xRect.height=49;
#if 1
	NSLog(@"XCreateWindow(%@)", NSStringFromXRect(_xRect));	// _windowRect.size.heigh is negative
#endif
	win=XCreateWindow(_display,
					  RootWindowOfScreen(_nsscreen->_screen),		// create an X window on the screen defined by RootWindow
					  _xRect.x,
					  _xRect.y,
					  _xRect.width,
					  _xRect.height,
					  0,
					  CopyFromParent,
					  CopyFromParent,
					  CopyFromParent,
					  valuemask,
					  &winattrs);
	if(!win)
		NSLog(@"did not create Window");
	if(!__WindowNumToNSWindow)
		__WindowNumToNSWindow=NSCreateMapTable(NSIntMapKeyCallBacks,
											   NSNonRetainedObjectMapValueCallBacks, 20);
	NSMapInsert(__WindowNumToNSWindow, (void *) win, window);		// X11 Window to NSWindow
#if 0
	NSLog(@"NSWindow number=%lu", win);
	NSLog(@"Window list: %@", NSAllMapTableValues(__WindowNumToNSWindow));
#endif
	self=[self _initWithGraphicsPort:(void *) win];
	if(backingType ==  NSBackingStoreBuffered && 1 /* not disabled by -NSNotDubleBuffered or similar */)
		{
		// allocate pixmap for background buffer
		}
	if(styleMask&NSUnscaledWindowMask)
		{ // set 1:1 transform (here or in NSWindow???)
		}
	[self _setSizeHints];
	wm_hints->initial_state = NormalState;			// set window manager hints
	wm_hints->input = True;								
	wm_hints->flags = StateHint | InputHint;		// WindowMaker ignores the
	XSetWMHints(_display, ((Window) _graphicsPort), wm_hints);		// frame origin unless it's also specified as a hint 
	if((styleMask & NSClosableWindowMask))			// if window has close, button inform WM 
		XSetWMProtocols(_display, ((Window) _graphicsPort), &_deleteWindowAtom, 1);
	attrs.window_level = [window level];
	attrs.flags = GSWindowStyleAttr|GSWindowLevelAttr;
	attrs.window_style = (styleMask & GSAllWindowMask);		// set WindowMaker WM
	XChangeProperty(_display, ((Window) _graphicsPort), _windowDecorAtom, _windowDecorAtom,		// window style hints
					32, PropModeReplace, (unsigned char *)&attrs,
					sizeof(GSAttributes)/sizeof(CARD32));
	XFree(wm_hints);
	return self;
}

- (id) _initWithGraphicsPort:(void *) port;
{ // port should be the X11 Window *
#if 0
	NSLog(@"_NSX11GraphicsContext _initWithGraphicsPort:%@", attributes);
#endif
#if FIXME
	// get NSScreen/screen from port (Window *)
	_nsscreen=[window screen];
	// FIXME: read window size from screen!
	//	_windowRect=frame;
	// e.g. get size hints
#endif
	_graphicsPort=port;	// _window is a typed alias for _graphicsPort
	_frontWindow=(Window) port;	// default is unbuffered
	_windowNum=(int) (_graphicsPort);	// we should get a system-wide unique integer (slot #) from the window list/level manager
	_scale=_nsscreen->_screenScale; 
	[self saveGraphicsState];	// initialize graphics state with transformations, GC etc. - don't use anything which depends on graphics state before here!
	XSelectInput(_display, ((Window) _graphicsPort),
				 ExposureMask | KeyPressMask | 
				 KeyReleaseMask | ButtonPressMask | 
				 ButtonReleaseMask | ButtonMotionMask | 
				 StructureNotifyMask | PointerMotionMask | 
				 EnterWindowMask | LeaveWindowMask | 
				 FocusChangeMask | PropertyChangeMask | 
				 ColormapChangeMask | KeymapStateMask | 
				 VisibilityChangeMask);
	// query server for extensions
	return self;
}

- (void) dealloc
{
#if 1
	NSLog(@"NSWindow dealloc in backend: %@", self);
#endif
	if(_isDoubleBuffered)
		/* XFreePixmap(_display, _backWindow) */
		;
	if(((Window) _graphicsPort))
		{
		NSMapRemove(__WindowNumToNSWindow, (void *) _windowNum);	// Remove X11 Window to NSWindows mapping
		XDestroyWindow(_display, ((Window) _graphicsPort));							// Destroy the X Window
		XFlush(_display);
		}
	// here we could check if we were the last window and XDestroyWindow(_display, xAppRootWindow); XCloseDisplay(_display);
	[super dealloc];
}

- (BOOL) isDrawingToScreen	{ return YES; }

// NSBackend interface

- (void) _setColor:(NSColor *) color;
{
	unsigned long pixel=[(_NSX11Color *)color _pixelForScreen:_nsscreen->_screen];
#if 0
	NSLog(@"_setColor -> pixel=%08x", pixel);
#endif
	XSetBackground(_display, _state->_gc, pixel);
	XSetForeground(_display, _state->_gc, pixel);
}

- (void) _setFillColor:(NSColor *) color;
{
	unsigned long pixel=[(_NSX11Color *)color _pixelForScreen:_nsscreen->_screen];
#if 0
	NSLog(@"_setColor -> pixel=%08x", pixel);
#endif
	XSetBackground(_display, _state->_gc, pixel);
	// FIXME: X11 uses the foreground color for filling!
	XSetForeground(_display, _state->_gc, pixel);
}

- (void) _setStrokeColor:(NSColor *) color;
{
	unsigned long pixel=[(_NSX11Color *)color _pixelForScreen:_nsscreen->_screen];
#if 0
	NSLog(@"_setColor -> pixel=%08x", pixel);
#endif
	XSetForeground(_display, _state->_gc, pixel);
}

- (void) _setCTM:(NSAffineTransform *) atm;
{ // we must also translate window base coordinates to window-relative X11 coordinates
	// NOTE: we could also cache this window relative transformation!
	[_state->_ctm release];
	_state->_ctm=[(NSAffineTransform *) (_nsscreen->_screen2X11) copy];									// this translates to screen coordinates
	if(_scale == 1.0)
		[_state->_ctm translateXBy:0.0 yBy:(HeightOfScreen(_nsscreen->_screen)-_xRect.height)];		// X11 uses window relative coordinates for all drawing
	else
		[_state->_ctm translateXBy:0.0 yBy:(HeightOfScreen(_nsscreen->_screen)-_xRect.height)/_scale];		// X11 uses window relative coordinates for all drawing
	[_state->_ctm prependTransform:atm];
#if 0
	NSLog(@"_setCTM -> %@", _state->_ctm);
#endif
}

- (void) _concatCTM:(NSAffineTransform *) atm;
{
	[_state->_ctm prependTransform:atm];
#if 0
	NSLog(@"_concatCTM -> %@", _state->_ctm);
#endif
}

- (void) _setCompositing
{
	XGCValues values;
	switch(_compositingOperation)
		{
		/* try to translate to
		GXclear				0x0	0
		GXand				0x1	src AND dst
		GXandReverse		0x2	src AND NOT dst
		GXcopy				0x3	src
		GXandInverted		0x4	(NOT src) AND dst
		GXnoop				0x5	dst
		GXxor				0x6	src XOR dst
		GXor				0x7	src OR dst
		GXnor				0x8	(NOT src) AND (NOT dst)
		GXequiv				0x9	(NOT src) XOR dst
		GXinvert			0xa	NOT dst
		GXorReverse			0xb	src OR (NOT dst)
		GXcopyInverted		0xc	NOT src
		GXorInverted		0xd	(NOT src) OR dst
		GXnand				0xe	(NOT src) OR (NOT dst)
		GXset				0xf	1
		*/
		case NSCompositeClear:
			values.function=GXclear;
			break;
		case NSCompositeCopy:
			values.function=GXcopy;
			break;
		case NSCompositeSourceOver:
			values.function=GXor;
			break;
		case NSCompositeXOR:
			values.function=GXxor;
			break;
		default:
			NSLog(@"can't draw using compositingOperation %d", _compositingOperation);
			values.function=GXcopy;
			break;
		}
	XChangeGC(_display, _state->_gc, GCFunction, &values);
}

static int _capStyles[]=
{ // translate cap styles
	CapButt,	// NSButtLineCapStyle
	CapRound,	// NSRoundLineCapStyle
	CapProjecting,	// NSSquareLineCapStyle
	CapNotLast	// undefined
};

static int _joinStyles[]=
{ // translate join style
	JoinMiter,	// NSMiterLineJoinStyle
	JoinRound,	// NSRoundLineJoinStyle
	JoinBevel,	// NSBevelLineJoinStyle
	JoinBevel	// undefined
};

typedef struct _PointsForPathState
{
	NSBezierPath *path;
	unsigned element;	// current element being expanded
	unsigned elements;	// number of elements in path
	XPoint *points;		// points array
	XPoint lastpoint;
	int npoints;		// number of entries in array
	unsigned capacity;	// how many elements are allocated
} PointsForPathState;

static inline void addPoint(PointsForPathState *state, NSPoint point)
{
	XPoint pnt;
	if(state->npoints >= state->capacity)
		state->points=(XPoint *) objc_realloc(state->points, sizeof(state->points[0])*(state->capacity=2*state->capacity+5));	// make more room
	pnt.x=point.x;		// convert to integer
	pnt.y=point.y;
	if(state->npoints == 0 || pnt.x != state->lastpoint.x || pnt.y != state->lastpoint.y)
		{ // first or really different
		state->lastpoint=pnt;
		state->points[state->npoints++]=pnt;	// store point
		}
#if 0
	else
		NSLog(@"addPoint duplicate ignored:(%d, %d)", pnt.x, pnt.y);
#endif
#if 0
	NSLog(@"addPoint:(%d, %d)", (int) point.x, (int) point.y);
#endif
}

// CHECKME if this is really triggered by rectangle primitives and e.g. NSSegmentedCell

- (BOOL) _rectForPath:(PointsForPathState *) state rect:(XRectangle *) rect;
{ // check if points[] describe a simple Rectangle (clockwise orientation)
	if(state->npoints != 5)
		return NO;
	if((state->points[0].x == state->points[1].x) &&
	   (state->points[1].y == state->points[2].y) &&
	   (state->points[2].x == state->points[3].x) &&
	   (state->points[3].y == state->points[4].y))
		{
		rect->x=state->points[0].x;
		rect->y=state->points[0].y;
		if(state->points[3].x < state->points[0].x || state->points[1].y < state->points[0].y)
			return NO;
		rect->width=state->points[3].x-state->points[0].x;
		rect->height=state->points[1].y-state->points[0].y;
		return YES;
		}
	return NO;
}

- (BOOL) _pointsForPath:(PointsForPathState *) state;
{ // process next part - return YES if anything found
	NSPoint points[3];
	NSPoint first, current, next;
	if(state->element == 0)
		state->elements=[state->path elementCount];	// initialize
	if(state->element >= state->elements)
		{
		if(state->points)
			objc_free(state->points);	// release buffer
		return NO;	// all done
		}
	state->npoints=0;
	while(state->element < state->elements)
		{
		// (re)alloc points array as needed
		switch([state->path elementAtIndex:state->element associatedPoints:points])
			{
			case NSMoveToBezierPathElement:
				current=first=[_state->_ctm transformPoint:points[0]];
				addPoint(state, current);
				break;
			case NSLineToBezierPathElement:
				next=[_state->_ctm transformPoint:points[0]];
				addPoint(state, next);
				current=next;
				break;
			case NSCurveToBezierPathElement:
				{

				// should better create path by algorithm like the following:
				
				// http://www.niksula.cs.hut.fi/~hkankaan/Homepages/bezierfast.html
				// or http://www.antigrain.com/research/adaptive_bezier/
				
				// but: there might even be a better algorithm that resembles Bresenham or CORDIC that
				//
				// - works with integer values
				// - moves one pixel per step either in x or y direction
				// - is not based on a predefined number of steps
				// - uses screen resolution as the smoothness limit
				//
				NSPoint p0=current;
				NSPoint p1=[_state->_ctm transformPoint:points[0]];
				NSPoint p2=[_state->_ctm transformPoint:points[1]];
				NSPoint p3=[_state->_ctm transformPoint:points[2]];
				float t;
#if 0
				NSLog(@"pointsForPath: curved element");
#endif
				// FIXME: we should adjust the step size to the size of the path
				for(t=0.1; t<=0.9; t+=0.1)
					{ // very simple and slow approximation
					float t1=(1.0-t);
					float t12=t1*t1;
					float t13=t1*t12;
					float t2=t*t;
					float t3=t*t2;
					NSPoint pnt;
					pnt.x=p0.x*t13+3.0*(p1.x*t*t12+p2.x*t2*t1)+p3.x*t3;
					pnt.y=p0.y*t13+3.0*(p1.y*t*t12+p2.y*t2*t1)+p3.y*t3;
					addPoint(state, pnt);
					}
				addPoint(state, next=p3);	// move to final point (if not already there)
				current=next;
				break;
				}
			case NSClosePathBezierPathElement:
				addPoint(state, first);
				break;
			}
		state->element++;
		}	
	return YES;
}

- (void) _stroke:(NSBezierPath *) path;
{
	PointsForPathState state={ path };
	float *pattern=NULL;	// FIXME: who is owner of this data? and who takes care not to overflow?
	int count;
	float phase;
	int width=(_scale != 1.0)?[path lineWidth]*_scale:[path lineWidth];	// multiply with userSpaceScale factor of current NSScreen!
	if(width < 1)
		width=1;	// default width
#if 0
	NSLog(@"_stroke");
#endif
	[self _setCompositing];
	[path getLineDash:pattern count:&count phase:&phase];
	XSetLineAttributes(_display, _state->_gc,
					   width,
					   count == 0 ? LineSolid : LineOnOffDash,
					   _capStyles[[path lineCapStyle]&0x03],
					   _joinStyles[[path lineJoinStyle]&0x03]
					   );
	if(count)
		{
		char dash_list[count];	// FIXME: this can overflow stack! => security risk by bad PDF files
		int i;
		for(i = 0; i < count; i++)
			dash_list[i] = (char) pattern[i];		
		XSetDashes(_display, _state->_gc, phase, dash_list, count);
		}
	while([self _pointsForPath:&state])
		XDrawLines(_display, ((Window) _graphicsPort), _state->_gc, state.points, state.npoints, CoordModeOrigin);
}

- (void) _fill:(NSBezierPath *) path;
{
	PointsForPathState state={ path };
	XGCValues values;	// FIXME: we have to temporarily swap background & foreground colors since X11 uses the FG color to fill!
#if 0
	NSLog(@"_fill");
#endif
	[self _setCompositing];
	XGetGCValues(_display, _state->_gc, GCForeground | GCBackground, &values);
	XSetForeground(_display, _state->_gc, values.background);	// set the fill color
	XSetFillStyle(_display, _state->_gc, FillSolid);
	XSetFillRule(_display, _state->_gc, [path windingRule] == NSNonZeroWindingRule?WindingRule:EvenOddRule);
	while([self _pointsForPath:&state])
		{
		XRectangle rect;
		if([self _rectForPath:&state rect:&rect])
			XFillRectangles(_display, ((Window) _graphicsPort), _state->_gc, &rect, 1);
		else
			XFillPolygon(_display, ((Window) _graphicsPort), _state->_gc, state.points, state.npoints, Complex, CoordModeOrigin);
		}
	XSetForeground(_display, _state->_gc, values.foreground);	// restore
}

- (Region) _regionFromPath:(NSBezierPath *) path
{ // get region from path
	PointsForPathState state={ path };
	Region region=NULL;
	while([self _pointsForPath:&state])
		{
		if(!region)
			{
			if(state.npoints < 2)
				region=XCreateRegion();	// create empty region
			else
				region=XPolygonRegion(state.points, state.npoints, [path windingRule] == NSNonZeroWindingRule?WindingRule:EvenOddRule);
			}
		else
			; // else  FIXME: build the Union or intersection of both (depending on winding rule)
		}
	return region;
}

- (void) _setClip:(NSBezierPath *) path;
{
#if 0
	NSLog(@"_setClip");
#endif
	if(_state->_clip)
		XDestroyRegion(_state->_clip);	// delete previous
	_state->_clip=[self _regionFromPath:path];
	// check for Rect region
	XSetRegion(_display, _state->_gc, _state->_clip);
#if 0
	{
		XRectangle box;
		XClipBox(_state->_clip, &box);
		NSLog(@"_setClip box=((%d,%d),(%d,%d))", box.x, box.y, box.width, box.height);
	}
#endif
}

- (void) _addClip:(NSBezierPath *) path;
{
	Region r;
#if 0
	NSLog(@"_addClip");
#endif
	r=[self _regionFromPath:path];
	if(_state->_clip)
		{
#if 0
		{
			XRectangle box;
			XClipBox(r, &box);
			NSLog(@"_addClip box=%@", NSStringFromXRect(box));
			XClipBox(_state->_clip, &box);
			NSLog(@"      to box=%@", NSStringFromXRect(box));
		}
#endif
		XIntersectRegion(_state->_clip, r, _state->_clip);
		XDestroyRegion(r);	// no longer needed
		}
	else
		_state->_clip=r;	// first call
	XSetRegion(_display, _state->_gc, _state->_clip);
#if 0
	{
		XRectangle box;
		XClipBox(_state->_clip, &box);
		NSLog(@"         box=%@", NSStringFromXRect(box));
	}
#endif
}

#if OLD
- (NSRect) _clipBox;
{
	// could use XClipBox(_state->_clip, rect clip) -- to determine where to really draw/fill
	return NSZeroRect;
}
#endif

- (void) _setShadow:(NSShadow *) shadow;
{ // we can't draw shadows without alpha
	NIMP;
}

// FIXME: replace this with a binary alpha-plane

- (void) _setShape:(NSBezierPath *) path;
{ // set window shape - the filled path defines the non-transparent area (needs Xext)
	Region region=[self _regionFromPath:path];
#if 0
	NSLog(@"_setShape: %@", self);
#endif
#if 0
	{ // check the result...
		Bool bounding_shaped, clip_shaped;
		int x_bounding, y_bounding, x_clip, y_clip;
		unsigned int w_bounding, h_bounding, w_clip, h_clip;
		XShapeQueryExtents(_display, ((Window) _graphicsPort), 
						   &bounding_shaped, 
						   &x_bounding, &y_bounding,
						   &w_bounding, &h_bounding,
						   &clip_shaped, 
						   &x_clip, &y_clip, &w_clip, &h_clip);
		NSLog(@"before %@%@ b:(%d, %d, %u, %u) clip:(%d, %d, %u, %u)",
			  bounding_shaped?@"bounding shaped ":@"", 
			  clip_shaped?@"bounding shaped ":@"", 
			  x_bounding, y_bounding, w_bounding, h_bounding,
			  x_clip, y_clip, w_clip, h_clip);
	}
#endif
	XShapeCombineRegion(_display, ((Window) _graphicsPort),
						ShapeClip,
						0, 0,
						region,
						ShapeSet);
	XShapeCombineRegion(_display, ((Window) _graphicsPort),
						ShapeBounding,
						0, 0,
						region,
						ShapeSet);
	XDestroyRegion(region);
	// ...inking also needs an overlaid InputOnly window to receive events at all pixels
#if 0
	{ // check the result...
		Bool bounding_shaped, clip_shaped;
		int x_bounding, y_bounding, x_clip, y_clip;
		unsigned int w_bounding, h_bounding, w_clip, h_clip;
		XShapeQueryExtents(_display, ((Window) _graphicsPort), 
						   &bounding_shaped, 
						   &x_bounding, &y_bounding,
						   &w_bounding, &h_bounding,
						   &clip_shaped, 
						   &x_clip, &y_clip, &w_clip, &h_clip);
		NSLog(@"after %@%@ b:(%d, %d, %u, %u) clip:(%d, %d, %u, %u)",
			  bounding_shaped?@"bounding shaped ":@"", 
			  clip_shaped?@"clip shaped ":@"", 
			  x_bounding, y_bounding, w_bounding, h_bounding,
			  x_clip, y_clip, w_clip, h_clip);
	}
#endif
}

- (void) _setFont:(NSFont *) font;
{
	if(font == _state->_font)
		return;	// change only if needed since it is quite expensive
	[_state->_font release];
	_state->_font=[font retain];
}

- (void) _beginText;
{
	// FIXME: we could postpone the CTM until we really draw text
	_cursor=[_state->_ctm transformPoint:NSZeroPoint];	// start at (0,0)
	_baseline=0;
}

- (void) _endText; { return; }

- (void) _setTextPosition:(NSPoint) pos;
{ // PDF: x y Td
  // FIXME: we could postpone the CTM until we really draw text
	_cursor=[_state->_ctm transformPoint:pos];
#if 0
	NSLog(@"_setTextPosition %@ -> %@", NSStringFromPoint(pos), NSStringFromPoint(_cursor));
#endif
}

- (void) _setLeading:(float) lead;
{ // PDF: x TL
	NIMP;
}

// FIXME: this does not properly handle rotated coords and newline

- (void) _newLine;
{ // PDF: T*
	NIMP;
}

// we need a command to set x-pos (only)

- (void) _setBaseline:(float) val;
{
	_baseline=val;
}

- (void) _string:(NSString *) string;
{ // draw string fragment -  PDF: (string) Tj
	unsigned length=[string length];
//	static unichar *buf;
//	static unsigned buflen;	// how much is allocated
#if 0
	if(draw)
		NSLog(@"NSString: _string:%@ withAttributes:%@ at {%f,%f}", string, attr, _cursor.x, _cursor.y);
#endif
//	if(buflen < sizeof(buf[0])*length)
//		buf=(unichar *) objc_realloc(buf, buflen+=sizeof(buf[0])*(length+20));	// increase buffer size
//	[string getCharacters:buf];
//	if(NSHostByteOrder() == NS_LittleEndian)
//		{ // we need to swap all bytes
//		int i;
//		for(i=0; i<length; i++)
//			buf[i]=NSSwapShort(buf[i]);
//		}
	[self _setCompositing];
	[_state->_font _setScale:_scale];
	XSetFont(_display, _state->_gc, [_state->_font _font]->fid);	// set font-ID in GC
	// set any other attributes
#if 0
		{
			XRectangle box;
			XClipBox(_state->_clip, &box);
			NSLog(@"draw string %@ at (%d,%d) box=%@", string, (int)_cursor.x, (int)(_cursor.y-baseline+[_state->_font _font]->ascent+1), NSStringFromXRect(box));
		}
#endif
	XDrawString16(_display, ((Window) _graphicsPort),
							_state->_gc, 
				  _cursor.x, (int)(_cursor.y-_baseline+[_state->_font _font]->ascent+1),	// X11 defines y as the character baseline
				  // NOTE:
				  // XChar2b is a struct which may be 4 bytes locally depending on struct alignment rules!
				  // But here it appears to work since Xlib appears to assume that there are 2*length bytes to send to the server
							XChar2bFromString(string, YES), // (XChar2b *) buf,
							length);		// Unicode drawing
//	_cursor.x+=size.width;	// advance cursor accordingly
}

- (void) _setFraction:(float) fraction;
{
	if(fraction > 1.0)
		_fraction=1.0;
	else if(fraction < 0.0)
		_fraction=0.0;
	else
		_fraction=fraction;	// save compositing fraction - fixme: convert to 0..256-integer
}

static void XIntersect(XRectangle *result, XRectangle *with)
{
	if(with->x > result->x+result->width)
		result->width=0;	// second box is completely to the right
	else if(with->x > result->x)
		result->width-=(with->x-result->x), result->x=with->x;	// new left border
	if(with->x+with->width < result->x)
		result->width=0;	// second box is completely to the left
	else if(with->x+with->width < result->x+result->width)
		result->width=with->x+with->width-result->x;	// new right border
	if(with->y > result->y+result->height)
		result->height=0;
	else if(with->y > result->y)
		result->height-=(with->y-result->y), result->y=with->y;
	if(with->y+with->height < result->y)
		result->height=0;	// empty
	else if(with->y+with->height < result->y+result->height)
		result->height=with->y+with->height-result->y;
}

static void XUnion(XRectangle *result, XRectangle *with)
{
	// extend result if needed
}

struct RGBA8
{ // 8 bit per channel RGBA
	unsigned char R, G, B, A;
};

// this is the bitmap sampler

inline static struct RGBA8 getPixel(int x, int y,
							int pixelsWide,
							int pixelsHigh,
							/*
							 int bitsPerSample,
							 int samplesPerPixel,
							 int bitsPerPixel,
							 */
							int bytesPerRow,
							BOOL isPlanar,
							BOOL hasAlpha, 
							unsigned char *data[5])
{ // extract RGBA8 value of given pixel from bitmap
	int offset;
	struct RGBA8 src;
	if(x < 0 || y < 0 || x >= pixelsWide || y >= pixelsHigh)
		{ // outside - transparent
		src.R=0;
		src.G=0;
		src.B=0;
		src.A=0;
		}
	else if(isPlanar)
		{ // planar
		offset=x+bytesPerRow*y;
		src.R=data[0][offset];
		src.G=data[1][offset];
		src.B=data[2][offset];
		if(hasAlpha)
			src.A=data[3][offset];
		else
			src.A=255;	// opaque
		}
	else
		{ // meshed
		offset=(hasAlpha?4:3)*x + bytesPerRow*y;
		src.R=data[0][offset+0];	// compiler should be able to optimize constant expression data[0][offset]
		src.G=data[0][offset+1];
		src.B=data[0][offset+2];
		if(hasAlpha)
			src.A=data[0][offset+3];
		else
			src.A=255;	// opaque
		}
	return src;
}

// this is the XImage sampler

inline static struct RGBA8 XGetRGBA8(XImage *img, int x, int y)
{ // get RGBA8
	unsigned int pixel=XGetPixel(img, x, y);
	struct RGBA8 dest;
	switch(img->depth)
		{
		case 24:
			{
				dest.R=(pixel>>16);
				dest.G=(pixel>>8);
				dest.B=(pixel>>0);
				break;
			}
		case 16:
			{ // scale 0..31 to 0..255
				// a better? algorithm could be val8bit=(val5bit<<3)+(val5bit>>2), i.e. fill the less significant bits with a copy of the more significant
				unsigned char tab5[]={ 
					( 0*255)/31,( 1*255)/31,( 2*255)/31,( 3*255)/31,( 4*255)/31,( 5*255)/31,( 6*255)/31,( 7*255)/31,
					( 8*255)/31,( 9*255)/31,(10*255)/31,(11*255)/31,(12*255)/31,(13*255)/31,(14*255)/31,(15*255)/31,
					(16*255)/31,(17*255)/31,(18*255)/31,(19*255)/31,(20*255)/31,(21*255)/31,(22*255)/31,(23*255)/31,
					(24*255)/31,(25*255)/31,(26*255)/31,(27*255)/31,(28*255)/31,(29*255)/31,(30*255)/31,(31*255)/31 };
				unsigned char tab6[]={
					( 0*255)/63,( 1*255)/63,( 2*255)/63,( 3*255)/63,( 4*255)/63,( 5*255)/63,( 6*255)/63,( 7*255)/63,
					( 8*255)/63,( 9*255)/63,(10*255)/63,(11*255)/63,(12*255)/63,(13*255)/63,(14*255)/63,(15*255)/63,
					(16*255)/63,(17*255)/63,(18*255)/63,(19*255)/63,(20*255)/63,(21*255)/63,(22*255)/63,(23*255)/63,
					(24*255)/63,(25*255)/63,(26*255)/63,(27*255)/63,(28*255)/63,(29*255)/63,(30*255)/63,(31*255)/63,
					(32*255)/63,(33*255)/63,(34*255)/63,(35*255)/63,(36*255)/63,(37*255)/63,(38*255)/63,(39*255)/63,
					(40*255)/63,(41*255)/63,(42*255)/63,(43*255)/63,(44*255)/63,(45*255)/63,(46*255)/63,(47*255)/63,
					(48*255)/63,(49*255)/63,(50*255)/63,(51*255)/63,(52*255)/63,(53*255)/63,(54*255)/63,(55*255)/63,
					(56*255)/63,(57*255)/63,(58*255)/63,(59*255)/63,(60*255)/63,(61*255)/63,(62*255)/63,(63*255)/63 };
				dest.R=tab5[(pixel>>11)&0x1f];	// highest 5 bit
				dest.G=tab6[(pixel>>5)&0x3f];	// middle 6 bit
				dest.B=tab5[pixel&0x1f];		// lowest 5 bit
			}
		}
	dest.A=255;
	return dest;
}

/* idea for sort of core-image extension
 *
 * struct filter { struct RGBA8 (*filter)(float x, float y); struct filter *input; other paramters }; describes a generic filter node
 * 
 * now, build a chain of filter modules, i.e.
 * 0. scanline RGBA to output image
 * 1. composite with a second image (i.e. the image fetched from screen)
 * 2. rotate&scale coordinates
 * 3. sample/interpolate
 * 4. fetch as RGBA from given bitmap
 * could add color space transforms etc.
 *
 */

- (BOOL) _draw:(NSImageRep *) rep;
{ // composite into unit square using current CTM, current compositingOp & fraction etc.

/* here we know:
- source bitmap: rep
- source rect: defined indirectly by clipping path
- clipping path (we only need to scan-line and interpolate visible pixels): _state->_clip
- compositing operation: _compositingOperation
- compositing fraction: _fraction
- interpolation algorithm: _imageInterpolation
- CTM (scales, rotates and translates): _state->_ctm
-- how do we know if we should really rotate or not? we don't need to know.
*/
	static NSRect unitSquare={{ 0.0, 0.0 }, { 1.0, 1.0 }};
	NSString *csp;
	int bytesPerRow;
	BOOL hasAlpha;
	BOOL isPlanar;
	float width, height;	// source image width&height
	unsigned char *imagePlanes[5];
	NSPoint origin;
	XRectangle box;			// relevant subarea to draw to
	NSRect scanRect;		// dest on screen in X11 coords
	BOOL isFlipped;
	NSAffineTransform *atm;	// projection from X11 window-relative to bitmap coordinates
	NSAffineTransformStruct atms;
	XRectangle xScanRect;	// on X11 where XImage is coming from
	XImage *img;
	int x, y;				// current position within XImage
	NSPoint pnt;			// current pixel in bitmap
	unsigned short fract=256.0*_fraction+0.5;
	if(fract > 256)
		fract=256;	// limit
	/*
	 * check if we can draw
	 */
	if(!rep)	// could check for NSBitmapImageRep
		{
		NSLog(@"_draw: nil representation!");
		// raise exception
		return NO;
		}
	csp=[rep colorSpaceName];
	if(![csp isEqualToString:NSCalibratedRGBColorSpace] && ![csp isEqualToString:NSDeviceRGBColorSpace])
		{
		NSLog(@"_draw: colorSpace %@ not supported!", csp);
		// raise exception?
		return NO;
		}
	/*
	 * locate where to draw in X11 coordinates
	 */
	isFlipped=[self isFlipped];
	origin=[_state->_ctm transformPoint:NSZeroPoint];	// determine real drawing origin in X11 coordinates
	scanRect=[_state->_ctm _boundingRectForTransformedRect:unitSquare];	// get bounding box for transformed unit square
#if 0
	NSLog(@"scan rect=%@", NSStringFromRect(scanRect));
#endif
	xScanRect.width=scanRect.size.width;
	xScanRect.height=scanRect.size.height;
	xScanRect.x=scanRect.origin.x;
	xScanRect.y=scanRect.origin.y;	// X11 specifies upper left corner
#if 0
	NSLog(@"  scan box=%@", NSStringFromXRect(xScanRect));
#endif
	/*
	 * clip to visible area (by clipping box, window and screen
	 */
	XClipBox(_state->_clip, &box);
#if 0
	NSLog(@"  clip box=%@", NSStringFromXRect(box));
#endif
	XIntersect(&xScanRect, &box);
#if 0
	NSLog(@"  intersected scan box=%@", NSStringFromXRect(xScanRect));
#endif
	// FIXME: clip by screen rect (if window is partially offscreen)
	if(xScanRect.width == 0 || xScanRect.height == 0)
		return YES;	// empty
	/*
	 * calculate reverse projection from XImage pixel coordinate to bitmap coordinate
	 */
	atm=[NSAffineTransform transform];
	[atm translateXBy:-origin.x yBy:-origin.y];		// we will scan through XImage which is thought to be relative to the drawing origin
	[atm prependTransform:_state->_ctm];
	[atm invert];				// get reverse mapping (XImage coordinates to unit square)
	width=[rep pixelsWide];
	height=[rep pixelsHigh];
	if(isFlipped)
		[atm scaleXBy:width yBy:height];	// and directly map to pixel coordinates
	else
		[atm scaleXBy:width yBy:-height];	// and directly map to flipped pixel coordinates
	atms=[atm transformStruct];	// extract raw coordinate transform
	/*
	 * get current screen image for compositing
	 */
	hasAlpha=[rep hasAlpha];
	if(atms.m11 != 1.0 || atms.m22 != 1.0 || atms.m12 != 0.0 || atms.m21 != 0.0 ||
	   hasAlpha && (_compositingOperation != NSCompositeClear && _compositingOperation != NSCompositeCopy &&
					_compositingOperation != NSCompositeSourceIn && _compositingOperation != NSCompositeSourceOut))
		{ // if rotated or any alpha blending, we must really fetch the current image from our context
		  //		NS_DURING
		{
			img=XGetImage(_display, ((Window) _graphicsPort),
						  xScanRect.x, xScanRect.y, xScanRect.width, xScanRect.height,
						  0x00ffffff, ZPixmap);
		}
		//		NS_HANDLER
		//			NSLog(@"_composite: could not fetch current screen contents due to %@", [localException reason]);
		//			img=nil;	// ignore for now
		//		NS_ENDHANDLER
		}
	else
		{ // we can simply create a new rectangular image and don't use anything existing
		int screen_number=XScreenNumberOfScreen(_nsscreen->_screen);
		img=XCreateImage(_display, DefaultVisual(_display, screen_number), DefaultDepth(_display, screen_number),
						 ZPixmap, 0, NULL,
						 xScanRect.width, xScanRect.height,
						 8, 0);
		if(img && !(img->data = objc_malloc(img->bytes_per_line*img->height)))
			{ // we failed to allocate a data area
			XDestroyImage(img);
			img=NULL;
			}
		}
	if(!img)
		{
		NSLog(@"could not XGetImage or XCreateImage");
		return NO;
		}
#if 0
	{
		int redshift;
		int greenshift;
		int blueshift;
		NSLog(@"width=%d height=%d", img->width, img->height);
		NSLog(@"xoffset=%d", img->xoffset);
		NSLog(@"format=%d", img->format);
		NSLog(@"byte_order=%d", img->byte_order);
		NSLog(@"bitmap_unit=%d", img->bitmap_unit);
		NSLog(@"bitmap_bit_order=%d", img->bitmap_bit_order);
		NSLog(@"bitmap_pad=%d", img->bitmap_pad);
		NSLog(@"depth=%d", img->depth);
		NSLog(@"bytes_per_line=%d", img->bytes_per_line);
		NSLog(@"bits_per_pixel=%d", img->bits_per_pixel);
		for(redshift=0; ((1<<redshift)&img->red_mask) == 0; redshift++);
		for(greenshift=0; ((1<<greenshift)&img->green_mask) == 0; greenshift++);
		for(blueshift=0; ((1<<blueshift)&img->blue_mask) == 0; blueshift++);
		NSLog(@"red_mask=%lu", img->red_mask);
		NSLog(@"green_mask=%lu", img->green_mask);
		NSLog(@"blue_mask=%lu", img->blue_mask);
		NSLog(@"redshift=%d", redshift);
		NSLog(@"greenshift=%d", greenshift);
		NSLog(@"blueshift=%d", blueshift);
	}
#endif
#if 0
	[[NSColor redColor] set];	// will set _gc
	XFillRectangle(_display, ((Window) _graphicsPort), _state->_gc, xScanRect.x, xScanRect.y, xScanRect.width, xScanRect.height);
#endif
	/*
	 * get direct access to the bitmap planes
	 */
	isPlanar=[(NSBitmapImageRep *) rep isPlanar];
	bytesPerRow=[(NSBitmapImageRep *) rep bytesPerRow];
	[(NSBitmapImageRep *) rep getBitmapDataPlanes:imagePlanes];
	/*
	 * draw by scanning lines
	 */
	for(y=0; y<img->height; y++)
		{
		struct RGBA8 src={0,0,0,255}, dest={0,0,0,255};	// initialize
		// FIXME: we must adjust x&y if we have clipped to the window, i.e. x&y are not aligned with the dest origin
		pnt.x=/*atms.m11*(0)+*/ -atms.m12*(y)+atms.tX;	// first point of this scan line
		pnt.y=/*atms.m21*(0)+*/ atms.m22*(y)+atms.tY;
		for(x=0; x<img->width; x++, pnt.x+=atms.m11, pnt.y-=atms.m21)
			{
			unsigned short F, G;
			if(_compositingOperation != NSCompositeClear)
				{ // get smoothed RGBA from bitmap
				if(_compositingOperation != NSCompositeCopy)
					dest=XGetRGBA8(img, x, y);	// get current image value
				// we should pipeline this through core-image like filter modules
				switch(_imageInterpolation)
					{
					case NSImageInterpolationDefault:	// default is same as low
					case NSImageInterpolationLow:
						// FIXME: here we should inter/extrapolate several source points
					case NSImageInterpolationHigh:
						// FIXME: here we should inter/extrapolate more source points
					case NSImageInterpolationNone:
						{
						src=getPixel((int) pnt.x, (int) pnt.y, width, height,
									 /*
									  int bitsPerSample,
									  int samplesPerPixel,
									  int bitsPerPixel,
									  */
									 bytesPerRow,
									 isPlanar, hasAlpha,
									 imagePlanes);
						if(fract != 256)
							{ // dim source image
							src.R=(fract*src.R)>>8;
							src.G=(fract*src.G)>>8;
							src.B=(fract*src.B)>>8;
							src.A=(fract*src.A)>>8;
							}
						}
					}
				}
			// FIXME: speed optimization: handle by table of functions, i.e. CompositeClear(struct RGBA *dest, struct RGBA *src) { dest->r=0; dest->g=(255*src->g+(255-src->a)*dest->g)>>8; ... }
			switch(_compositingOperation)
				{ // based on http://www.cs.wisc.edu/~schenney/courses/cs559-s2001/lectures/lecture-8-online.ppt
				case NSCompositeClear:				F=0, G=0; break;
				default:
				case NSCompositeCopy:				F=255, G=0; break;
				case NSCompositeHighlight:			// deprecated and mapped to NSCompositeSourceOver
				case NSCompositeSourceOver:			F=255, G=255-src.A; break;
				case NSCompositeSourceIn:			F=dest.A, G=0; break;
				case NSCompositeSourceOut:			F=255-dest.A, G=0; break;
				case NSCompositeSourceAtop:			F=dest.A, G=255-src.A; break;
				case NSCompositeDestinationOver:	F=255-dest.A, G=255; break;
				case NSCompositeDestinationIn:		F=0, G=src.A; break;
				case NSCompositeDestinationOut:		F=0, G=255-src.A; break;
				case NSCompositeDestinationAtop:	F=255-dest.A, G=src.A; break;
				case NSCompositePlusDarker:			F=255-25, G=255-25; break;		// FIXME: should not influence alpha of result!
				case NSCompositePlusLighter:		F=255+25, G=255+25; break;
				case NSCompositeXOR:				F=255-dest.A, G=255-src.A; break;
				}
			// FIXME: (255*255>>8) => 254???
			// FIXME: using Highlight etc. must be limited to pixel value 0/255
			// we must divide by 255 and not 256 - or adjust F&G scaling
			if(G == 0)
				{ // calculation is done with 'int' precision; stores only 8 bit
				dest.R=(F*src.R)>>8;
				dest.G=(F*src.G)>>8;
				dest.B=(F*src.B)>>8;
				dest.A=(F*src.A)>>8;
				}
			else if(F == 0)
				{
				dest.R=(G*dest.R)>>8;
				dest.G=(G*dest.G)>>8;
				dest.B=(G*dest.B)>>8;
				dest.A=(G*dest.A)>>8;
				}
			else
				{
				dest.R=(F*src.R+G*dest.R)>>8;
				dest.G=(F*src.G+G*dest.G)>>8;
				dest.B=(F*src.B+G*dest.B)>>8;
				dest.A=(F*src.A+G*dest.A)>>8;
				}
/* FIXME
			if(dest.R > 255) dest.R=255;
			if(dest.G > 255) dest.G=255;
			if(dest.B > 255) dest.B=255;
			if(dest.A > 255) dest.A=255;
*/
			if(img->depth == 24)
				XPutPixel(img, x, y, (dest.R<<16)+(dest.G<<8)+(dest.B<<0));
			else if(img->depth==16)
				XPutPixel(img, x, y, ((dest.R<<8)&0xf800)+((dest.G<<3)&0x07e0)+((dest.B>>3)&0x1f));	// 5/6/5 bit
			}
		}
	/*
	 * draw to screen
	 */
	XPutImage(_display, ((Window) _graphicsPort), _state->_gc, img, 0, 0, xScanRect.x, xScanRect.y, xScanRect.width, xScanRect.height);
	XDestroyImage(img);
#if 0
	[[NSColor redColor] set];	// will change _gc
	XDrawRectangle(_display, ((Window) _graphicsPort), _state->_gc, xScanRect.x, xScanRect.y, xScanRect.width, xScanRect.height);
#endif
	return YES;
}

- (void) _copyBits:(void *) srcGstate fromRect:(NSRect) srcRect toPoint:(NSPoint) destPoint;
{ // copy srcRect using CTM from (_NSX11GraphicsState *) srcGstate to destPoint transformed by current CTM
	srcRect.origin=[((_NSX11GraphicsState *) srcGstate)->_ctm transformPoint:srcRect.origin];
	srcRect.size=[((_NSX11GraphicsState *) srcGstate)->_ctm transformSize:srcRect.size];
	destPoint=[_state->_ctm transformPoint:destPoint];
#if 1
	NSLog(@"_copyBits");
#endif
	XCopyArea(_display,
			  (Window) (((_NSGraphicsState *) srcGstate)->_context->_graphicsPort),	// source window
			  ((Window) _graphicsPort), _state->_gc,
			  srcRect.origin.x, srcRect.origin.y,
			  srcRect.size.width, /*-*/srcRect.size.height,
			  destPoint.x, destPoint.y);
}

- (void) _setCursor:(NSCursor *) cursor;
{
#if 0
	NSLog(@"_setCursor:%@", cursor);
#endif
	XDefineCursor(_display, ((Window) _graphicsPort), [(_NSX11Cursor *) cursor _cursor]);
}

- (int) _windowNumber; { return _windowNum; }

// FIXME: NSWindow frontend should identify the otherWin from the global window list

- (void) _orderWindow:(NSWindowOrderingMode) place relativeTo:(int) otherWin;
{
	XWindowChanges values;
#if 0
	NSLog(@"_orderWindow:%02x relativeTo:%d", place, otherWin);
#endif
	if([[NSWindow _windowForNumber:_windowNum] isMiniaturized])	// FIXME: used as special trick not to really map the window during init
		return;
	switch(place)
		{
		case NSWindowOut:
			XUnmapWindow(_display, ((Window) _graphicsPort));
			break;
		case NSWindowAbove:
			XMapWindow(_display, ((Window) _graphicsPort));	// if not yet
			values.sibling=otherWin;		// 0 will order front
			values.stack_mode=Above;
			XConfigureWindow(_display, ((Window) _graphicsPort), CWStackMode, &values);
			break;
		case NSWindowBelow:
			XMapWindow(_display, ((Window) _graphicsPort));	// if not yet
			values.sibling=otherWin;		// 0 will order back
			values.stack_mode=Below;
			XConfigureWindow(_display, ((Window) _graphicsPort), CWStackMode, &values);
			break;
		}
	// save (new) level so that we can order other windows accordingly
	// maybe we should use a window property to store the level?
	}

- (void) _miniaturize;
{
	NSLog(@"_miniaturize");
//	Status XIconifyWindow(_display, ((Window) _graphicsPort), _screen_number)
}

- (void) _setOrigin:(NSPoint) point;
{ // note: it is the optimization task of NSWindow to call this only if setFrame really changes the origin
#if 0
	NSLog(@"_setOrigin:%@", NSStringFromPoint(point));
#endif
	_windowRect.origin=[(NSAffineTransform *)(_nsscreen->_screen2X11) transformPoint:point];
	_xRect.x=NSMinX(_windowRect);
	_xRect.y=NSMaxY(_windowRect)+WINDOW_MANAGER_TITLE_HEIGHT;
	XMoveWindow(_display, ((Window) _graphicsPort),
				_xRect.x,
				_xRect.y);
	[self _setSizeHints];
}

- (void) _setOriginAndSize:(NSRect) frame;
{ // note: it is the optimization task of NSWindow to call this only if setFrame really changes the size
#if 0
	NSLog(@"_setOriginAndSize:%@", NSStringFromRect(frame));
#endif
	_windowRect.origin=[(NSAffineTransform *)(_nsscreen->_screen2X11) transformPoint:frame.origin];
	_windowRect.size=[(NSAffineTransform *)(_nsscreen->_screen2X11) transformSize:frame.size];
	_xRect.x=NSMinX(_windowRect);
	_xRect.y=NSMaxY(_windowRect)+WINDOW_MANAGER_TITLE_HEIGHT;
	_xRect.width=NSWidth(_windowRect);
	_xRect.height=NSMinY(_windowRect)-NSMaxY(_windowRect);	// _windowRect.size.heigh is negative
	if(_xRect.width == 0) _xRect.width=48;
	if(_xRect.height == 0) _xRect.height=49;
	XMoveResizeWindow(_display, ((Window) _graphicsPort), 
					  _xRect.x,
					  _xRect.y,
					  _xRect.width,
					  _xRect.height);
	[self _setSizeHints];
}

- (void) _setTitle:(NSString *) string;
{ // note: it is the task of NSWindow to call this only if setTitle really changes the title
	XTextProperty windowName;
	const char *newTitle = [string cString];	// UTF8String??
	XStringListToTextProperty((char**) &newTitle, 1, &windowName);
	XSetWMName(_display, ((Window) _graphicsPort), &windowName);
	XSetWMIconName(_display, ((Window) _graphicsPort), &windowName);
}

- (void) _setLevel:(int) level;
{ // note: it is the task of NSWindow to call this only if setLevel really changes the level
#if 1
	NSLog(@"setLevel of window %d", level);
#endif
	/*
	attrs.window_level = [window level];
	attrs.flags = GSWindowStyleAttr|GSWindowLevelAttr;
	attrs.window_style = (styleMask & GSAllWindowMask);
	XChangeProperty(_display, ((Window) _graphicsPort), _windowDecorAtom, _windowDecorAtom,		// window style hints
					32, PropModeReplace, (unsigned char *)&attrs,
					sizeof(GSAttributes)/sizeof(CARD32));
*/
}

- (void) _makeKeyWindow;
{
	XSetInputFocus(_display, ((Window) _graphicsPort), RevertToNone, CurrentTime);
}

- (BOOL) _isKeyWindow;
{
	Window focus_return;
	int revert_to_return;
	XGetInputFocus(_display, &focus_return, &revert_to_return);
	return focus_return == ((Window) _graphicsPort);	// check if we are the key window
}

- (NSRect) _frame;
{ // get current frame as on screen (might have been moved by window manager)
	int x, y;
	unsigned width, height;
	NSAffineTransform *ictm=[_nsscreen _X112screen];
	XGetGeometry(_display, ((Window) _graphicsPort), NULL, &x, &y, &width, &height, NULL, NULL);
	return (NSRect){[ictm transformPoint:NSMakePoint(x, y)], [ictm transformSize:NSMakeSize(width, -height)]};	// translate to screen coordinates!
}

- (void) _setDocumentEdited:(BOOL)flag					// mark doc as edited
{ 
	GSAttributes attrs;
    memset(&attrs, 0, sizeof(GSAttributes));
	attrs.extra_flags = (flag) ? GSDocumentEditedFlag : 0;
	attrs.flags = GSExtraFlagsAttr;						// set WindowMaker WM window style hints
	XChangeProperty(_display, ((Window) _graphicsPort),
					_windowDecorAtom, _windowDecorAtom, 
					32, PropModeReplace, (unsigned char *)&attrs, 
					sizeof(GSAttributes)/sizeof(CARD32));
}

- (void) _beginPage:(NSString *) title;
{ // can we (mis-)use that as setTitle???
	return;
}

- (void) _endPage; { return; }

- (_NSGraphicsState *) _copyGraphicsState:(_NSGraphicsState *) state;
{ 
	XGCValues values;
	_NSX11GraphicsState *new=(_NSX11GraphicsState *) objc_malloc(sizeof(*new));
	new->_gc=XCreateGC(_display, ((Window) _graphicsPort), 0l, &values);	// create a fresh GC without values
	if(state)
		{ // copy
		new->_font=[((_NSX11GraphicsState *) state)->_font retain];
		new->_ctm=[((_NSX11GraphicsState *) state)->_ctm copyWithZone:NSDefaultMallocZone()];
		XCopyGC(_display, ((_NSX11GraphicsState *) state)->_gc, 
				GCFunction |
				GCPlaneMask |
				GCForeground |
				GCBackground |
				GCLineWidth	|
				GCLineStyle	|
				GCCapStyle |
				GCJoinStyle	|
				GCFillStyle	|
				// GCFillRule
				// GCTile
				// GCStipple
				// GCTileStipXOrigin
				// GCTileStipYOrigin
				GCFont |
				GCSubwindowMode	|
				GCGraphicsExposures	|
				GCClipXOrigin |
				GCClipYOrigin |
				GCClipMask
				// GCDashOffset
				// GCDashList
				// GCArcMode
				, new->_gc);	// copy from existing
		if(((_NSX11GraphicsState *) state)->_clip)
			{
			new->_clip=XCreateRegion();	// create new region
			XUnionRegion(((_NSX11GraphicsState *) state)->_clip, ((_NSX11GraphicsState *) state)->_clip, new->_clip);	// copy clipping region
#if 0
			{
				XRectangle box;
				XClipBox(_state->_clip, &box);
				NSLog(@"copy clip box=%@", NSStringFromXRect(box));
			}
#endif
			}
		else
			new->_clip=NULL;	// not clipped
		}
	else
		{ // alloc
		new->_ctm=nil;		// no initial screen transformation (set by first lockFocus)
		new->_clip=NULL;	// not clipped
		new->_font=nil;
		}
	return (_NSGraphicsState *) new;
}

- (void) restoreGraphicsState;
{
	if(!_graphicsState)
		return;
	if(_state->_ctm)
		[_state->_ctm release];
	if(_state->_clip)
		XDestroyRegion(_state->_clip);
	if(_state->_gc)
		XFreeGC(_display, _state->_gc);
	if(_state->_font)
		[_state->_font release];
	[super restoreGraphicsState];
#if 0
	{
		XRectangle box;
		if(_state && _state->_clip)
			{
			XClipBox(_state->_clip, &box);
			NSLog(@"clip     box=%@", NSStringFromXRect(box));
			}
		else
			NSLog(@"no clip");
	}
#endif
}

- (NSColor *) _readPixel:(NSPoint) location;
{
	XImage *img;
	struct RGBA8 pix;
	NSColor *c;
	location=[_state->_ctm transformPoint:location];
	img=XGetImage(_display, ((Window) _graphicsPort),
				  location.x, location.y, 1, 1,
				  0x00ffffff, ZPixmap);
	pix=XGetRGBA8(img, 0, 0);
	XDestroyImage(img);
	c=[NSColor colorWithDeviceRed:pix.R/255.0 green:pix.G/255.0 blue:pix.B/255.0 alpha:pix.A/255.0];	// convert pixel to NSColor
	return c;
}

-  (void) _initBitmap:(NSBitmapImageRep *) bitmap withFocusedViewRect:(NSRect) rect;
{
	XImage *img;
	rect.origin=[_state->_ctm transformPoint:rect.origin];
	rect.size=[_state->_ctm transformSize:rect.size];
	img=XGetImage(_display, ((Window) _graphicsPort),
				  rect.origin.x, rect.origin.y, rect.size.width, -rect.size.height,
				  0x00ffffff, ZPixmap);
	// copy pixels to bitmap
	XDestroyImage(img);
}

- (void) flushGraphics;
{
#if 0
	NSLog(@"X11 flushGraphics");
#endif
	if(_isDoubleBuffered)
		{
		// copy dirty area (if any) from back to front buffer and clear dirty area
		_dirty=(XRectangle){ 0, 0, 0, 0 };	// clear
		}
	XFlush(_display);
}

- (NSPoint) _mouseLocationOutsideOfEventStream;
{ // Return mouse location in receiver's base coords ignoring the event loop
	Window root, child;
	int root_x, root_y, window_x, window_y;
	unsigned int mask;	// modifier and mouse keys
	if(!XQueryPointer(_display, ((Window) _graphicsPort), &root, &child, &root_x, &root_y, &window_x, &window_y, &mask))
		return NSZeroPoint;
	if(_scale != 1.0)
		return NSMakePoint(window_x/_scale, (_xRect.height-window_y)/_scale);
	return NSMakePoint(window_x, _xRect.height-window_y);
}

- (int) _keyModfierFlags;
{
	return __modFlags;
}

@end /* XRGraphicsContext */

static unsigned short xKeyCode(XEvent *xEvent, KeySym keysym, unsigned int *eventModFlags)
{ // translate key code
	unsigned short keyCode = 0;
	
	switch(keysym)
		{
		case XK_Return:
		case XK_KP_Enter:
		case XK_Linefeed:
			return '\r';
		case XK_Tab:
			return '\t';
		case XK_space:
			return ' ';
		}
	if ((keysym >= XK_F1) && (keysym <= XK_F35)) 			// if a function
		{													// key was pressed
		*eventModFlags |= NSFunctionKeyMask; 
		
		switch(xEvent->xkey.keycode)	// FIXME: why not use keysym here??
			{
			case XK_F1:  keyCode = NSF1FunctionKey;  break;
			case XK_F2:  keyCode = NSF2FunctionKey;  break;
			case XK_F3:  keyCode = NSF3FunctionKey;  break;
			case XK_F4:  keyCode = NSF4FunctionKey;  break;
			case XK_F5:  keyCode = NSF5FunctionKey;  break;
			case XK_F6:  keyCode = NSF6FunctionKey;  break;
			case XK_F7:  keyCode = NSF7FunctionKey;  break;
			case XK_F8:  keyCode = NSF8FunctionKey;  break;
			case XK_F9:  keyCode = NSF9FunctionKey;  break;
			case XK_F10: keyCode = NSF10FunctionKey; break;
			case XK_F11: keyCode = NSF11FunctionKey; break;
			case XK_F12: keyCode = NSF12FunctionKey; break;
			case XK_F13: keyCode = NSF13FunctionKey; break;
			case XK_F14: keyCode = NSF14FunctionKey; break;
			case XK_F15: keyCode = NSF15FunctionKey; break;
			case XK_F16: keyCode = NSF16FunctionKey; break;
			case XK_F17: keyCode = NSF17FunctionKey; break;
			case XK_F18: keyCode = NSF18FunctionKey; break;
			case XK_F19: keyCode = NSF19FunctionKey; break;
			case XK_F20: keyCode = NSF20FunctionKey; break;
			case XK_F21: keyCode = NSF21FunctionKey; break;
			case XK_F22: keyCode = NSF22FunctionKey; break;
			case XK_F23: keyCode = NSF23FunctionKey; break;
			case XK_F24: keyCode = NSF24FunctionKey; break;
			case XK_F25: keyCode = NSF25FunctionKey; break;
			case XK_F26: keyCode = NSF26FunctionKey; break;
			case XK_F27: keyCode = NSF27FunctionKey; break;
			case XK_F28: keyCode = NSF28FunctionKey; break;
			case XK_F29: keyCode = NSF29FunctionKey; break;
			case XK_F30: keyCode = NSF30FunctionKey; break;
			case XK_F31: keyCode = NSF31FunctionKey; break;
			case XK_F32: keyCode = NSF32FunctionKey; break;
			case XK_F33: keyCode = NSF33FunctionKey; break;
			case XK_F34: keyCode = NSF34FunctionKey; break;
			case XK_F35: keyCode = NSF35FunctionKey; break;
			default:								 break;
			}	}
	else 
		{
		switch(keysym) 
			{
			case XK_BackSpace:  keyCode = NSBackspaceKey;			break;
			case XK_Delete: 	keyCode = NSDeleteFunctionKey;		break;
			case XK_Home:		keyCode = NSHomeFunctionKey;		break;
			case XK_Left:		keyCode = NSLeftArrowFunctionKey;	break;
			case XK_Up:  		keyCode = NSUpArrowFunctionKey;		break;
			case XK_Right:		keyCode = NSRightArrowFunctionKey;	break;
			case XK_Down:		keyCode = NSDownArrowFunctionKey;	break;
			case XK_Prior:		keyCode = NSPrevFunctionKey;		break;
			case XK_Next:  		keyCode = NSNextFunctionKey;		break;
			case XK_End:  		keyCode = NSEndFunctionKey;			break;
			case XK_Begin:  	keyCode = NSBeginFunctionKey;		break;
			case XK_Select:		keyCode = NSSelectFunctionKey;		break;
			case XK_Print:  	keyCode = NSPrintScreenFunctionKey;	break;
			case XK_Execute:  	keyCode = NSExecuteFunctionKey;		break;
			case XK_Insert:  	keyCode = NSInsertFunctionKey;		break;
			case XK_Undo: 		keyCode = NSUndoFunctionKey;		break;
			case XK_Redo:		keyCode = NSRedoFunctionKey;		break;
			case XK_Menu:		keyCode = NSMenuFunctionKey;		break;
			case XK_Find:  		keyCode = NSFindFunctionKey;		break;
			case XK_Help:		keyCode = NSHelpFunctionKey;		break;
			case XK_Break:  	keyCode = NSBreakFunctionKey;		break;
			case XK_Mode_switch:keyCode = NSModeSwitchFunctionKey;	break;
			case XK_Sys_Req:	keyCode = NSSysReqFunctionKey;		break;
			case XK_Scroll_Lock:keyCode = NSScrollLockFunctionKey;	break;
			case XK_Pause:  	keyCode = NSPauseFunctionKey;		break;
			case XK_Clear:		keyCode = NSClearDisplayFunctionKey;break;
				// NSPageUpFunctionKey
				// NSPageDownFunctionKey
				// NSResetFunctionKey
				// NSStopFunctionKey
				// NSUserFunctionKey
				// and others
			default:												break;
			}
		
		if(keyCode)
			*eventModFlags |= NSFunctionKeyMask;
		else
			{ // other keys to handle
			if ((keysym == XK_Shift_L) || (keysym == XK_Shift_R))
				*eventModFlags |= NSFunctionKeyMask | NSShiftKeyMask; 
			else if ((keysym == XK_Control_L) || (keysym == XK_Control_R))
				*eventModFlags |= NSFunctionKeyMask | NSControlKeyMask; 
			else if ((keysym == XK_Alt_R) || (keysym == XK_Meta_R))
				*eventModFlags |= NSAlternateKeyMask;
			else if ((keysym == XK_Alt_L) || (keysym == XK_Meta_L))
				*eventModFlags |= NSCommandKeyMask | NSAlternateKeyMask; 
			}
		}
	
	if ((keysym > XK_KP_Space) && (keysym < XK_KP_9)) 		// If the key press
		{													// originated from
		*eventModFlags |= NSNumericPadKeyMask;				// the key pad
		
		switch(keysym) 
			{
			case XK_KP_F1:        keyCode = NSF1FunctionKey;         break;
			case XK_KP_F2:        keyCode = NSF2FunctionKey;         break;
			case XK_KP_F3:        keyCode = NSF3FunctionKey;         break;
			case XK_KP_F4:        keyCode = NSF4FunctionKey;         break;
			case XK_KP_Home:      keyCode = NSHomeFunctionKey;       break;
			case XK_KP_Left:      keyCode = NSLeftArrowFunctionKey;  break;
			case XK_KP_Up:        keyCode = NSUpArrowFunctionKey;    break;
			case XK_KP_Right:     keyCode = NSRightArrowFunctionKey; break;
			case XK_KP_Down:      keyCode = NSDownArrowFunctionKey;  break;
			case XK_KP_Page_Up:   keyCode = NSPageUpFunctionKey;     break;
			case XK_KP_Page_Down: keyCode = NSPageDownFunctionKey;   break;
			case XK_KP_End:       keyCode = NSEndFunctionKey;        break;
			case XK_KP_Begin:     keyCode = NSBeginFunctionKey;      break;
			case XK_KP_Insert:    keyCode = NSInsertFunctionKey;     break;
			case XK_KP_Delete:    keyCode = NSDeleteFunctionKey;     break;
			default:												 break;
			}
		}
	
	if (((keysym > XK_KP_Space) && (keysym <= XK_KP_9)) ||
		((keysym > XK_space) && (keysym <= XK_asciitilde)))
		{
		// Not processed
		} 
	
	return keyCode;
}

// determine which modifier
// keys (Command, Control,
// Shift, etc..) were held down
// while the event occured.

static unsigned int	xKeyModifierFlags(unsigned int state)
{
	unsigned int flags = 0; 
	
	if (state & ControlMask)
		flags |= NSControlKeyMask;
	
	if (state & ShiftMask)
		flags |= NSShiftKeyMask;
	
	if (state & Mod1Mask)
		flags |= NSAlternateKeyMask;	// not recognized??
	
	if (state & Mod2Mask) 
		flags |= NSCommandKeyMask; 
	
	if (state & Mod3Mask) 
		flags |= NSAlphaShiftKeyMask;
	
	if (state & Mod4Mask) 
		flags |= NSHelpKeyMask; 
	
	if (state & Mod5Mask) 
		flags |= NSControlKeyMask; 
	// we don't handle the NSNumericPadKeyMask and NSFunctionKeyMask here
#if 0
	NSLog(@"state=%x flags=%x", state, flags);
#endif
	return flags;
}

static void X11ErrorHandler(Display *display, XErrorEvent *error_event)
{
	static struct { char *name; int major; } requests[]={
		{ "CreateWindow", 1 }, 
		{ "ChangeWindowAttributes", 2 }, 
		{ "GetWindowAttributes", 3 },
		{ "DestroyWindow", 4 },
		{ "DestroySubwindows", 5 },
		{ "ChangeSaveSet", 6 },
		{ "ReparentWindow", 7 },
		{ "MapWindow", 8 },
		{ "MapSubwindows", 9 },
		{ "UnmapWindow", 10 },
		{ "UnmapSubwindows", 11 },
		{ "ConfigureWindow", 12 },
		{ "CirculateWindow", 13 },
		{ "GetGeometry", 14 },
		{ "QueryTree", 15 },
		{ "InternAtom", 16 },
		{ "GetAtomName", 17 },
		{ "ChangeProperty", 18 }, 
		{ "DeleteProperty", 19 },
		{ "GetProperty", 20 },
		{ "ListProperties", 21 },
		{ "SetSelectionOwner", 22 },    
		{ "GetSelectionOwner", 23 },
		{ "ConvertSelection", 24 }, 
		{ "SendEvent", 25 },
		{ "GrabPointer", 26 },
		{ "UngrabPointer", 27 },
		{ "GrabButton", 28 },
		{ "UngrabButton", 29 },
		{ "ChangeActivePointerGrab", 30 },
		{ "GrabKeyboard", 31 },
		{ "UngrabKeyboard", 32 }, 
		{ "GrabKey", 33 },
		{ "UngrabKey", 34 },
		{ "AllowEvents", 35 },       
		{ "GrabServer", 36 },    
		{ "UngrabServer", 37 }, 
		{ "QueryPointer", 38 }, 
		{ "GetMotionEvents", 39 },
		{ "TranslateCoords", 40 }, 
		{ "WarpPointer", 41 },       
		{ "SetInputFocus", 42 }, 
		{ "GetInputFocus", 43 }, 
		{ "QueryKeymap", 44 },      
		{ "OpenFont", 45 },
		{ "CloseFont", 46 },     
		{ "QueryFont", 47 },
		{ "QueryTextExtents", 48 },     
		{ "ListFonts", 49 },
		{ "ListFontsWithInfo", 50 }, 
		{ "SetFontPath", 51 },
		{ "GetFontPath", 52 },
		{ "CreatePixmap", 53 }, 
		{ "FreePixmap", 54 },    
		{ "CreateGC", 55 },
		{ "ChangeGC", 56 },   
		{ "CopyGC", 57 },
		{ "SetDashes", 58 },     
		{ "SetClipRectangles", 59 }, 
		{ "FreeGC", 60 },
		{ "ClearArea", 61 }, 
		{ "CopyArea", 62 },    
		{ "CopyPlane", 63 },     
		{ "PolyPoint", 64 },     
		{ "PolyLine", 65 },    
		{ "PolySegment", 66 },       
		{ "PolyRectangle", 67 }, 
		{ "PolyArc", 68 },
		{ "FillPoly", 69 },    
		{ "PolyFillRectangle", 70 }, 
		{ "PolyFillArc", 71 },       
		{ "PutImage", 72 },
		{ "GetImage", 73 },
		{ "PolyText8", 74 },     
		{ "PolyText16", 75 },      
		{ "ImageText8", 76 },      
		{ "ImageText16", 77 },       
		{ "CreateColormap", 78 }, 
		{ "FreeColormap", 79 }, 
		{ "CopyColormapAndFree", 80 }, 
		{ "InstallColormap", 81 }, 
		{ "UninstallColormap", 82 }, 
		{ "ListInstalledColormaps", 83 }, 
		{ "AllocColor", 84 },
		{ "AllocNamedColor", 85 }, 
		{ "AllocColorCells", 86 }, 
		{ "AllocColorPlanes", 87 }, 
		{ "FreeColors", 88 },     
		{ "StoreColors", 89 },       
		{ "StoreNamedColor", 90 }, 
		{ "QueryColors", 91 },  
		{ "LookupColor", 92 },
		{ "CreateCursor", 93 }, 
		{ "CreateGlyphCursor", 94 }, 
		{ "FreeCursor", 95 },    
		{ "RecolorCursor", 96 }, 
		{ "QueryBestSize", 97 }, 
		{ "QueryExtension", 98 }, 
		{ "ListExtensions", 99 }, 
		{ "ChangeKeyboardMapping", 100 },
		{ "GetKeyboardMapping", 101 },
		{ "ChangeKeyboardControl", 102 }, 
		{ "GetKeyboardControl", 103 }, 
		{ "Bell", 104 },
		{ "ChangePointerControl", 105 },
		{ "GetPointerControl", 106 },
		{ "SetScreenSaver", 107 }, 
		{ "GetScreenSaver", 108 }, 
		{ "ChangeHosts", 109 },    
		{ "ListHosts", 110 },
		{ "SetAccessControl", 111 }, 
		{ "SetCloseDownMode", 112 },
		{ "KillClient", 113 },
		{ "RotateProperties", 114 },
		{ "ForceScreenSaver", 115 },
		{ "SetPointerMapping", 116 },
		{ "GetPointerMapping", 117 },
		{ "SetModifierMapping", 118 },
		{ "GetModifierMapping", 119 },
		{ "NoOperation", 127 },
		{ NULL} };
	char string[1025];
	int i;
    XGetErrorText(display, error_event->error_code, string, sizeof(string)-1);
	string[sizeof(string)-1]=0;
    NSLog(@"X Error: %s", string);
    NSLog(@"  code: %u", error_event->error_code);
    NSLog(@"  display: %s", DisplayString(display));
	for(i=0; requests[i].name; i++)
		if(requests[i].major == error_event->request_code)
			break;
	if(requests[i].name)
		NSLog(@"  request: %s(%u).%u", requests[i].name, error_event->request_code, error_event->minor_code);
	else
		NSLog(@"  request: %u.%u", error_event->request_code, error_event->minor_code);
    NSLog(@"  resource: %lu", error_event->resourceid);
	if(error_event->request_code == 73)
		return;
#if 1
	*((long *) 1)=0;	// force SEGFAULT to ease debugging by writing a core dump
	abort();
#endif
	[NSException raise:NSGenericException format:@"X11 Internal Error"];	
}  /* X11ErrorHandler */

@implementation NSGraphicsContext (NSBackendOverride)

+ (NSGraphicsContext *) graphicsContextWithGraphicsPort:(void *) port flipped:(BOOL) flipped;
{
	NSGraphicsContext *gc=[[(_NSX11GraphicsContext *)NSAllocateObject([_NSX11GraphicsContext class], 0, NSDefaultMallocZone()) _initWithGraphicsPort:port] autorelease];
	if(gc)
		gc->_isFlipped=flipped;
	return gc;
}

+ (NSGraphicsContext *) graphicsContextWithWindow:(NSWindow *) window
{
	return [_NSX11GraphicsContext graphicsContextWithAttributes:
		[NSDictionary dictionaryWithObject:window forKey:NSGraphicsContextDestinationAttributeName]];
}

@end

@implementation NSWindow (NSBackendOverride)

+ (int) _getLevelOfWindowNumber:(int) windowNum;
{ // even if it is not a NSWindow
	Atom actual_type_return;
	int actual_format_return;
	unsigned long nitems_return;
	unsigned long bytes_after_return;
	unsigned char *prop_return;
	int level;
	Display *_display;
#if 1
	NSLog(@"getLevel of window %d", windowNum);
#endif
	
	return 0;
	
	if(!XGetWindowProperty(_display, (Window) windowNum, _windowDecorAtom, 0, 0, False, _windowDecorAtom, 
						   &actual_type_return, &actual_format_return, &nitems_return, &bytes_after_return, &prop_return))
		return 0;
	level=((GSAttributes *) prop_return)->window_level;
	XFree(prop_return);
#if 1
	NSLog(@"  = %d", level);
#endif
	return level;
}

+ (NSWindow *) _windowForNumber:(int) windowNum;
{
#if 0
	NSLog(@"_windowForNumber %d -> %@", windowNum, NSMapGet(__WindowNumToNSWindow, (void *) windowNum));
#endif
	return NSMapGet(__WindowNumToNSWindow, (void *) windowNum);
}

+ (NSArray *) _windowList;
{ // get all NSWindows of this application
#if COMPLEX
	int count;
	int context=getpid();	// filter only our windows!
	NSCountWindowsForContext(context, &count);
	if(count)
		{
		int list[count];	// get window numbers
		NSMutableArray *a=[NSMutableArray arrayWithCapacity:count];
		NSWindowList(context, count, list);
		for(i=0; i<count; i++)
			[a addObject:NSMapGet(__WindowNumToNSWindow, (void *) list[i]);	// translate to NSWindows
		return a;
		}
	return nil;
#endif
	if(__WindowNumToNSWindow)
		return NSAllMapTableValues(__WindowNumToNSWindow);		// all windows we currently know by window number
	return nil;
}

@end

@implementation NSScreen (NSBackendOverride)

+ (void) initialize;	// called when looking at the first screen
{
	[_NSX11Screen class];
}

+ (NSArray *) screens
{
	static NSMutableArray *screens;
	if(!screens)
		{ // create screens list
		int i;
		screens=[[NSMutableArray alloc] initWithCapacity:ScreenCount(_display)];
		for(i=0; i<ScreenCount(_display); i++)
			{
			_NSX11Screen *s=[[_NSX11Screen alloc] init];	// create screen object
			s->_screen=XScreenOfDisplay(_display, i);	// Screen
			if(s->_screen)
				{
				if(i == XDefaultScreen(_display))
					[screens insertObject:s atIndex:0];	// make it the first screen
				else
					[screens addObject:s];
				}
			[s release];	// retained by array
			}
#if 0
		NSLog(@"screens=%@", screens);
#endif
		}
	return screens;
}

+ (int) _windowListForContext:(int) context size:(int) size list:(int *) list;	// list may be NULL, return # of entries copied
{ // get window numbers from front to back
	int i, j, s;
	Window *children;	// list of children
	unsigned int nchildren;
	// this mus be a) fast, b) front2back, c) allow for easy access to the window level, d) returns internal window numbers and not NSWindows e) for potentially ALL applications
	// where can we get that from? a) from the Xserver, b) from a local shared file (per NSScreen), c) from a property attached to the Sceen and/or the Windows (WM_HINTS?)
#if OLD
	///
	/// the task is to fill with up to size window number (front to back)
	/// and filtered by context (pid?) if that is != 0
	///
	/*
	 or do we use a shared file to store window levels and stacking order?
	 struct XLevel {
		 unsigned long nextToBack;
		 long context;	// pid()
		 long level;
		 Window window;
	 };
	 
	 XQueryTree approach must fail since it does not return appropriate stacking order for child windows with different parent!!!
	 
	 */
#endif
	for(s=0; s<ScreenCount(_display); s++)
		{
#if 1
		NSLog(@"XQueryTree");
#endif
		if(!XQueryTree(_display, RootWindowOfScreen(XScreenOfDisplay(_display, s)), NULL, NULL, &children, &nchildren))
			return 0;	// failed
#if 1
		NSLog(@"  nchildren= %d", nchildren);
#endif
		for(i=nchildren-1, j=0; i>0; i--)
			{
			if(context != 0 && 0 /* not equal */)
				{
				// what is context? A client ID? A process ID?
				continue;	// skip since it is owned by a different application
				}
			if(list)
				{
				if(j >= size)
					break;	// done
				list[j++]=(int) children[i];	// get windows in front2back order (i.e. reverse) and translate to window numbers
				}
			}
		XFree(children);
		}
	return i;
}

@end

@implementation _NSX11Screen

static NSDictionary *_x11settings;

+ (void) initialize;	// called when looking at the first screen
{ // initialize backend
	static char *atomNames[] =
	{
		"WM_STATE",
		"WM_PROTOCOLS",
		"WM_DELETE_WINDOW",
		"_GNUSTEP_WM_ATTR"
	};
	Atom atoms[sizeof(atomNames)/sizeof(atomNames[0])];
	NSFileHandle *fh;
	NSUserDefaults *def=[[[NSUserDefaults alloc] initWithUser:@"root"] autorelease];
	_x11settings=[[def persistentDomainForName:@"com.quantumstep.X11"] retain];
#if 1
	NSLog(@"NSScreen backend +initialize");
	//	system("export;/usr/X11R6/bin/xeyes&");
#endif
#if 0
	XInitThreads();	// make us thread-safe
#endif
	if((_display=XOpenDisplay(NULL)) == NULL) 		// connect to X server based on DISPLAY variable
		[NSException raise:NSGenericException format:@"Unable to connect to X server"];
	XSetErrorHandler((XErrorHandler)X11ErrorHandler);
	fh=[[NSFileHandle alloc] initWithFileDescriptor:XConnectionNumber(_display)];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(_X11EventNotification:)
												 name:NSFileHandleDataAvailableNotification
											   object:fh];
	_XRunloopModes=[[NSArray alloc] initWithObjects:
		NSDefaultRunLoopMode,
#if 1
		// CHECKME:
		// do we really have to handle NSConnectionReplyMode?
		// Well, this keeps the UI responsive if DO is multi-threaded but might als lead to strange synchronization issues (nested runloops)
		NSConnectionReplyMode,
#endif
		NSModalPanelRunLoopMode,
		NSEventTrackingRunLoopMode,
		nil];
	[fh waitForDataInBackgroundAndNotifyForModes:_XRunloopModes];
    if(XInternAtoms(_display, atomNames, sizeof(atomNames)/sizeof(atomNames[0]), False, atoms) == 0)
		[NSException raise: NSGenericException format:@"XInternAtoms()"];
    _stateAtom = atoms[0];
    _protocolsAtom = atoms[1];
    _deleteWindowAtom = atoms[2];
    _windowDecorAtom = atoms[3];
}

+ (void) _X11EventNotification:(NSNotification *) n;
{
#if 0
	NSLog(@"X11 notification");
#endif
	[self _handleNewEvents];
#if 0
	NSLog(@"  X11 notification done");
#endif
	[[n object] waitForDataInBackgroundAndNotifyForModes:_XRunloopModes];
}

- (float) userSpaceScaleFactor;
{ // get dots per point	
	static float factor;
	if(factor <= 0.01)
		{
		factor=[[_x11settings objectForKey:@"userSpaceScaleFactor"] floatValue];
		if(factor <= 0.01) factor=1.0;
		}
	return factor;	// read from user settings
#if 0	
	NSSize dpi=[[[self deviceDescription] objectForKey:NSDeviceResolution] sizeValue];
	return (dpi.width+dpi.height)/144;	// take average for 72dpi
#endif
}

- (NSDictionary *) deviceDescription;
{
	if(!_device)
		{ // (re)load resolution
		BOOL changed=NO;
		NSSize size, resolution;
		_screenScale=[[_x11settings objectForKey:@"systemSpaceScaleFactor"] floatValue];
		if(_screenScale <= 0.01) _screenScale=1.0;
		_xRect.width=WidthOfScreen(_screen);			// screen width in pixels
		_xRect.height=HeightOfScreen(_screen);			// screen height in pixels
		size.width=_xRect.width/_screenScale;					// screen width in 1/72 points
		size.height=_xRect.height/_screenScale;					// screen height in 1/72 points
		resolution.width=(25.4*size.width)/WidthMMOfScreen(_screen);	// returns size in mm -> translate to DPI
		resolution.height=(25.4*size.height)/HeightMMOfScreen(_screen);
		[(NSAffineTransform *) _screen2X11 release];
		_screen2X11=[[NSAffineTransform alloc] init];
		[(NSAffineTransform *) _screen2X11 scaleXBy:_screenScale yBy:-_screenScale];	// flip Y axis and scale
		// FIXME: do we have to divide the 0.5 by scale as well???
		[(NSAffineTransform *) _screen2X11 translateXBy:0.5 yBy:-0.5-size.height];		// adjust for real screen height and proper rounding
#if __APPLE__
		size.height-=[self _windowTitleHeight]/_screenScale;	// subtract menu bar of X11 server from frame
#endif
#if 0
		NSLog(@"_screen2X11=%@", (NSAffineTransform *) _screen2X11);
#endif
#if __linux__
		if(XDisplayString(_display)[0] == ':' ||
		   strncmp(XDisplayString(_display), "localhost:", 10) == 0)
			{ // local server
			static int fd=-1;
			int r;
			if(fd < 0)
				fd=open("/dev/apm_bios", O_RDWR|O_NONBLOCK);
			if(fd < 0)
				NSLog(@"Failed to get hinge state from /dev/apm_bios");
			else
				{
				r=ioctl(fd, SCRCTL_GET_ROTATION);
#if 1
				NSLog(@"hinge state=%d", r);
#endif
				switch(r)
					{
					default:
						NSLog(@"unknown hinge state %d", r);
						break;
					case 3:	// Case Closed
						break;
					case 2:	// Case open & portrait
						{ // swap x and y
							// what if we need to apply a different scaling factor?
							unsigned xh;
							float h;
							xh=_xRect.width; _xRect.width=_xRect.height; _xRect.height=h;
							h=size.height; size.height=size.width; size.width=h;
							h=resolution.height; resolution.height=resolution.width; resolution.width=h;
							[(NSAffineTransform *) _screen2X11 rotateByDegrees:90.0];
							break;
						}
					case 0:	// Case open & landscape
						break;
					}
				}
			// setup a timer to verify/update the deviceDescription every now and then
			}
		else
			{
			size.height-=[self _windowTitleHeight]/_screenScale;	// subtract menu bar of X11 server from frame
			}
#endif
		_device=[[NSMutableDictionary alloc] initWithObjectsAndKeys:
			[NSNumber numberWithInt:PlanesOfScreen(_screen)], NSDeviceBitsPerSample,
			@"DeviceRGBColorSpace", NSDeviceColorSpaceName,
			@"NO", NSDeviceIsPrinter,
			@"YES", NSDeviceIsScreen,
			[NSValue valueWithSize:resolution], NSDeviceResolution,
			[NSValue valueWithSize:size], NSDeviceSize,
			[NSNumber numberWithInt:XScreenNumberOfScreen(_screen)], @"NSScreenNumber",
			nil];
#if 1
		NSLog(@"deviceDescription=%@", _device);
		NSLog(@"  resolution=%@", NSStringFromSize(resolution));
		NSLog(@"  size=%@", NSStringFromSize(size));
#endif
		if(changed)
			{
			[[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification
																object:NSApp];
			}
		}
	return _device;
}

- (NSWindowDepth) depth
{
	int BpS=PlanesOfScreen(_screen);
	return WindowDepth(BpS, BpS/3, YES, NSRGBColorSpaceModel);
}

- (const NSWindowDepth *) supportedWindowDepths;
{
	/*
	int *XListDepths(display, screen_number, count_return)
	Display *display;
	int screen_number;
	int *count_return;
	 
	 and translate

	 */
	NIMP; return NULL; 
}

- (NSAffineTransform *) _X112screen;
{
	if(!_X112screen)
		{ // calculate and cache
		_X112screen=[(NSAffineTransform *)_screen2X11 copy];
		[_X112screen invert];
		}
	return _X112screen;
}

- (BOOL) _hasWindowManager;
{ // check if there is a window manager so we should not add _NSWindowTitleView
	return YES;
}

- (int) _windowTitleHeight;
{ // amount added by window manager for window title
	return 22;
}

// FIXME: should translate mouse locations by CTM to account for screen rotation through CTM!

#define X11toScreen(record) NSMakePoint(record.x/windowScale, (windowHeight-record.y)/windowScale)
#define X11toTimestamp(record) ((NSTimeInterval)(record.time*0.001))

+ (void) _handleNewEvents;
{
	int count;
	while((count = XPending(_display)) > 0)		// while X events are pending
		{
#if 0
		fprintf(stderr,"_NSX11GraphicsContext ((XPending count = %d): \n", count);
#endif
		while(count-- > 0)
			{	// loop and grab all events
			static Window lastXWin=None;		// last window (cache key)
			static int windowNumber;			// number of lastXWin
			static unsigned int windowHeight;	// attributes of lastXWin
			static float windowScale;			// scaling factor
			static NSWindow *window=nil;		// associated NSWindow of lastXWin
			static NSEvent *lastMotionEvent=nil;
			static Time timeOfLastClick = 0;
			static int clickCount = 1;
			NSEventType type;
			Window thisXWin;				// window of this event
			XEvent xe;
			NSEvent *e = nil;	// resulting event
			XNextEvent(_display, &xe);
			switch(xe.type)
				{ // extract window from event
				case ButtonPress:
				case ButtonRelease:
					thisXWin=xe.xbutton.window;
					break;
				case MotionNotify:
					thisXWin=xe.xmotion.window;
					if(thisXWin != lastXWin)						
						lastMotionEvent=nil;	// window has changed - we need a new event
					break;
				case ReparentNotify:
					thisXWin=xe.xreparent.window;
					break;
				case Expose:
					thisXWin=xe.xexpose.window;
					break;
				case ClientMessage:
					thisXWin=xe.xclient.window;
					break;
				case ConfigureNotify:					// window has been resized
					thisXWin=xe.xconfigure.window;
					break;
				case FocusIn:
				case FocusOut:							// keyboard focus left
					thisXWin=xe.xfocus.window;
					break;
				case KeyPress:							// a key has been pressed
				case KeyRelease:						// a key has been released
					thisXWin=xe.xkey.window;
					break;
				case MapNotify:							// when a window changes
				case UnmapNotify:
					thisXWin=xe.xmap.window;
					break;
				case PropertyNotify:
					thisXWin=xe.xproperty.window;
					break;
				default:
					thisXWin=lastXWin;	// assume unchanged
				}
			if(thisXWin != lastXWin)						
				{ // update cached references to window and prepare for translation
				window=NSMapGet(__WindowNumToNSWindow, (void *) thisXWin);
				if(!window)
					{ // FIXME: if a window is closed, it might be removed from this list but events might be pending!
					NSLog(@"*** event from unknown Window (%d). Ignored.", (long) thisXWin);
					NSLog(@"Window list: %@", NSAllMapTableValues(__WindowNumToNSWindow));
					continue;	// ignore events
					}
				else
					{
					_NSX11GraphicsContext *ctxt=(_NSX11GraphicsContext *)[window graphicsContext];
					windowNumber=[window windowNumber];
					windowHeight=ctxt->_xRect.height;
					windowScale=ctxt->_scale;
					}
				lastXWin=thisXWin;
				}
			// we could post the raw X-event as an NSNotification so that we could build a window manager...
			switch(xe.type)
				{										// mouse button events
				case ButtonPress:
					{
						float pressure=0.0;
						NSDebugLog(@"ButtonPress: X11 time %u timeOfLastClick %u \n", 
								   xe.xbutton.time, timeOfLastClick);
						// hardwired test for a double click
						// default of 300 should be user set;
						// under NS the windowserver does this
						if(xe.xbutton.time < (unsigned long)(timeOfLastClick+300))
							clickCount++;
						else
							clickCount = 1;							// reset click cnt
						timeOfLastClick = xe.xbutton.time;
						switch (xe.xbutton.button)
							{
							case Button4:
								type = NSScrollWheel;
								pressure = (float)clickCount;
								break;								
							case Button5:
								type = NSScrollWheel;
								pressure = -(float)clickCount;
								break;
							case Button1:	type = NSLeftMouseDown;		break;
							case Button3:	type = NSRightMouseDown;	break;
							default:		type = NSOtherMouseDown;	break;
							}
						e = [NSEvent mouseEventWithType:type		// create NSEvent	
											   location:X11toScreen(xe.xbutton)
										  modifierFlags:__modFlags
											  timestamp:X11toTimestamp(xe.xbutton)
										   windowNumber:windowNumber
												context:self
											eventNumber:xe.xbutton.serial
											 clickCount:clickCount
											   pressure:pressure];
						break;
					}					
				case ButtonRelease:
					{
						NSDebugLog(@"ButtonRelease");
						if(xe.xbutton.button == Button1)
							type=NSLeftMouseUp;
						else if(xe.xbutton.button == Button3)
							type=NSRightMouseUp;
						else
							type=NSOtherMouseUp;
						e = [NSEvent mouseEventWithType:type		// create NSEvent	
											   location:X11toScreen(xe.xbutton)
										  modifierFlags:__modFlags
											  timestamp:X11toTimestamp(xe.xbutton)
										   windowNumber:windowNumber
												context:self
											eventNumber:xe.xbutton.serial
											 clickCount:clickCount
											   pressure:1.0];
						break;
					}
				case CirculateNotify:	// a change to the stacking order
					NSDebugLog(@"CirculateNotify\n");
					break;					
				case CirculateRequest:
					NSDebugLog(@"CirculateRequest");
					break;
				case ClientMessage:								// client events
					NSDebugLog(@"ClientMessage\n");
					if(xe.xclient.message_type == _protocolsAtom &&
					   xe.xclient.data.l[0] == _deleteWindowAtom) 
						{ // WM is asking us to close
						[window performClose:self];
						}									// to close window
#if DND
					else
						XRProcessXDND(_display, &xe);		// handle X DND
#endif
					break;
				case ColormapNotify:					// colormap attribute chg
					NSDebugLog(@"ColormapNotify\n");
					break;
				case ConfigureNotify:					// window has been moved or resized by window manager
					NSDebugLog(@"ConfigureNotify\n");
#if FIXME
					if(!xe.xconfigure.override_redirect || 
						xe.xconfigure.window == _wAppTileWindow)
						{
						NSRect f = (NSRect){{(float)xe.xconfigure.x,
							(float)xe.xconfigure.y},
							{(float)xe.xconfigure.width,
								(float)xe.xconfigure.height}};	// get frame rect
						if(!(w = XRWindowWithXWindow(xe.xconfigure.window)) && xe.xconfigure.window == _wAppTileWindow)
							w = XRWindowWithXWindow(__xAppTileWindow);
						if(xe.xconfigure.above == 0)
							f.origin = [w xFrame].origin;
						//					if(!xe.xconfigure.override_redirect && xe.xconfigure.send_event == 0)
						f.origin.y += WINDOW_MANAGER_TITLE_HEIGHT;		// adjust for title bar offset
						NSDebugLog(@"New frame %f %f %f %f\n", 
								   f.origin.x, f.origin.y,
								   f.size.width, f.size.height);
						// FIXME: shouldn't this be an NSNotification that a window can catch?
						[window _setFrame:f];
						}
					if(xe.xconfigure.window == lastXWin)
						{
						// xFrame = [w xFrame];
						xFrame = (NSRect){{(float)xe.xconfigure.x,
								(float)xe.xconfigure.y},
								{(float)xe.xconfigure.width,
									(float)xe.xconfigure.height}};
						}
					break;								
#endif
				case ConfigureRequest:					// same as ConfigureNotify but we get this event
					NSDebugLog(@"ConfigureRequest\n");	// before the change has 
					break;								// actually occurred 					
				case CreateNotify:						// a window has been
					NSDebugLog(@"CreateNotify\n");		// created
					break;
				case DestroyNotify:						// a window has been
					NSLog(@"DestroyNotify\n");			// Destroyed
					break;
				case EnterNotify:						// when the pointer
					NSDebugLog(@"EnterNotify\n");		// enters a window
					break;					
				case LeaveNotify:						// when the pointer 
					NSDebugLog(@"LeaveNotify\n");		// leaves a window
					break;
				case Expose:
					{
						if(/* window isDoubleBuffered */ 0)
							{ // copy from backing store
							}
						else
							{
							NSRect r;
							r.origin=X11toScreen(xe.xexpose);		// top left corner
							r.size=NSMakeSize(xe.xexpose.width/windowScale, xe.xexpose.height/windowScale);
							r.origin.y-=r.size.height;	// AppKit assumes that we specify the bottom left corner
#if 0
							NSLog(@"expose %@ %@ -> %@", window,
								  NSStringFromXRect(xe.xexpose),
								  NSStringFromRect(r));
#endif
							// shouldn't we post the event to the start of the queue to sync with runloop actions?
							[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidExposeNotification
																				object:window
																			  userInfo:[NSDictionary dictionaryWithObject:[NSValue valueWithRect:r]
																												   forKey:@"NSExposedRect"]];
							}
						break;
					}
				case FocusIn:							
					{ // keyboard focus entered one of our windows - take this a a hint from the WindowManager to bring us to the front
					NSLog(@"FocusIn 1: %d\n", xe.xfocus.detail);
#if OLD
					// NotifyAncestor			0
					// NotifyVirtual			1
					// NotifyInferior			2
					// NotifyNonlinear			3
					// NotifyNonlinearVirtual	4
					// NotifyPointer			5
					// NotifyPointerRoot		6
					// NotifyDetailNone			7
					[NSApp activateIgnoringOtherApps:YES];	// user has clicked: bring our application windows and menus to front
					[window makeKey];
					if(xe.xfocus.detail == NotifyAncestor)
						{
						//				if (![[[NSApp mainMenu] _menuWindow] isVisible])
						//					[[NSApp mainMenu] display];
						}
					else if(xe.xfocus.detail == NotifyNonlinear
							&& __xKeyWindowNeedsFocus == None)
						{ // create fake mouse dn
						NSLog(@"FocusIn 2");
						// FIXME: shouldn't we better use data1 and data2 to specify that we are having focus-events??
						e = [NSEvent otherEventWithType:NSAppKitDefined
											   location:NSZeroPoint
										  modifierFlags:0
											  timestamp:(NSTimeInterval)0
										   windowNumber:windowNumber
												context:self
												subtype:xe.xfocus.serial
												  data1:0
												  data2:0];
						}
#endif
					break;
					}
				case FocusOut:
					{ // keyboard focus has left one of our windows
					NSDebugLog(@"FocusOut");
					e = [NSEvent otherEventWithType:NSSystemDefined
										   location:NSZeroPoint
									  modifierFlags:0
										  timestamp:(NSTimeInterval)0
									   windowNumber:windowNumber
											context:self
											subtype:xe.xfocus.serial
											  data1:0
											  data2:0];
#if FIXME
					if(xe.xfocus.detail == NotifyAncestor)	// what does this mean?
						{
						NSLog(@"FocusOut 1");
						[w xFrame];
						XFlush(_display);
						if([w xGrabMouse] == GrabSuccess)
							[w xReleaseMouse];
						else
							{
							NSWindow *k = [NSApp keyWindow];
							
							if((w == k && [k isVisible]) || !k)
								[[NSApp mainMenu] close];	// parent titlebar is moving the window
							}
						}
					else
						{
						Window xfw;
						int r;
						// check if focus is in one of our windows
						XGetInputFocus(_display, &xfw, &r);
						if(!(w = XRWindowWithXWindow(xfw)))
							{
							NSLog(@"FocusOut 3");
							//							[NSApp deactivate];
							}
						}
					if(__xKeyWindowNeedsFocus == xe.xfocus.window)
						__xKeyWindowNeedsFocus = None;
#endif
					break;
					}
				case GraphicsExpose:
					NSDebugLog(@"GraphicsExpose\n");
					break;
				case NoExpose:
					NSDebugLog(@"NoExpose\n");
					break;
				case GravityNotify:						// window is moved because
					NSDebugLog(@"GravityNotify\n");		// of a change in the size
					break;								// of its parent
				case KeyPress:							// a key has been pressed
				case KeyRelease:						// a key has been released
#if 0
					NSLog(@"Process key event");
#endif
					{
						NSEventType eventType=(xe.type == KeyPress)?NSKeyDown:NSKeyUp;
						char buf[256];
						XComposeStatus cs;
						KeySym ksym;
						NSString *keys = @"";
						unsigned short keyCode = 0;
						unsigned mflags, _modFlags;
						unsigned int count = XLookupString(&xe.xkey, buf, 256, &ksym, &cs);
						
						
						buf[MIN(count, 255)] = '\0'; // Terminate string properly
#if 0
						NSLog(@"xKeyEvent: xkey.state=%d", xe.xkey.state);
#endif						
						_modFlags = mflags = xKeyModifierFlags(xe.xkey.state);		// decode modifier flags
						if((keyCode = xKeyCode(&xe, ksym, &_modFlags)) != 0 || count != 0)
							keys = [NSString stringWithCString:buf];	// key has a code
						else
							{ // if we have neither a keyCode nor characters we have just changed a modifier Key
							if(eventType == NSKeyUp)
								_modFlags &= ~mflags;	// just reset flags by this key
							eventType=NSFlagsChanged;
							}
						__modFlags=_modFlags;	// if modified
						e= [NSEvent keyEventWithType:eventType
											location:NSZeroPoint
									   modifierFlags:__modFlags
										   timestamp:X11toTimestamp(xe.xkey)
										windowNumber:windowNumber
											 context:self
										  characters:keys
						 charactersIgnoringModifiers:[keys lowercaseString]		// FIX ME?
										   isARepeat:NO	// any idea how to FIXME?
											 keyCode:keyCode];
#if 0
						NSLog(@"xKeyEvent: %@", e);
#endif
						break;
					}
					
				case KeymapNotify:						// reports the state of the
					NSDebugLog(@"KeymapNotify");		// keyboard when pointer or
					break;								// focus enters a window
					
				case MapNotify:							// when a window changes
					NSDebugLog(@"MapNotify");			// state from ummapped to
														// mapped or vice versa
					[window _setIsVisible:YES];
					break;								 
					
				case UnmapNotify:						// find the NSWindow and
					NSDebugLog(@"UnmapNotify\n");		// inform it that it is no
														// longer visible
					[window _setIsVisible:NO];
					break;
					
				case MapRequest:						// like MapNotify but
					NSDebugLog(@"MapRequest\n");		// occurs before the
					break;								// request is carried out
					
				case MappingNotify:						// keyboard or mouse   
					NSDebugLog(@"MappingNotify\n");		// mapping has been changed
					break;								// by another client
					
				case MotionNotify:
					{ // the mouse has moved
					NSDebugLog(@"MotionNotify");
					if(xe.xmotion.state & Button1Mask)		
						type = NSLeftMouseDragged;	
					else if(xe.xmotion.state & Button3Mask)		
						type = NSRightMouseDragged;	
					else if(xe.xmotion.state & Button2Mask)		
						type = NSOtherMouseDragged;	
					else
						type = NSMouseMoved;	// not pressed
#if 0
					if(lastMotionEvent &&
					   [NSApp _eventIsQueued:lastMotionEvent])
						{
						NSLog(@"motion event still in queue: %@", lastMotionEvent);
						}
#endif
					if(lastMotionEvent &&
					   [NSApp _eventIsQueued:lastMotionEvent] &&	// must come first because event may already have been relesed/deallocated
					   [lastMotionEvent type] == type)
						{ // replace/update if last motion event is still unprocessed in queue
						typedef struct _NSEvent_t { @defs(NSEvent) } _NSEvent;
						_NSEvent *a = (_NSEvent *)lastMotionEvent;	// this allows to access iVars directly
#if 0
						NSLog(@"update last motion event");
#endif
						a->location_point=X11toScreen(xe.xmotion);
						a->modifier_flags=__modFlags;
						a->event_time=X11toTimestamp(xe.xmotion);
						a->event_data.mouse.event_num=xe.xmotion.serial;
						break;
						}
					e = [NSEvent mouseEventWithType:type		// create NSEvent
										   location:X11toScreen(xe.xmotion)
									  modifierFlags:__modFlags
										  timestamp:X11toTimestamp(xe.xmotion)
									   windowNumber:windowNumber
											context:self
										eventNumber:xe.xmotion.serial
										 clickCount:1
										   pressure:1.0];
					lastMotionEvent = e;
#if 0
					NSLog(@"MotionNotify e=%@", e);
#endif
					break;
					}
				case PropertyNotify:
					{ // a window property has changed or been deleted
					NSDebugLog(@"PropertyNotify");
					if(_stateAtom == xe.xproperty.atom)
						{
						Atom target;
						unsigned long number_items, bytes_remaining;
						unsigned char *data;
						int status, format;						
						status = XGetWindowProperty(_display,
													xe.xproperty.window, 
													xe.xproperty.atom, 
													0, 1, False, _stateAtom,
													&target, &format, 
													&number_items,&bytes_remaining,
													(unsigned char **)&data);
						if(status != Success || !data) 
							break;
						if(*data == IconicState)
							[window miniaturize:self];
						else if(*data == NormalState)
							[window deminiaturize:self];
						if(number_items > 0)
							XFree(data);
						}
#if 1	// debug
					if(_stateAtom == xe.xproperty.atom)
						{
						char *data = XGetAtomName(_display, xe.xproperty.atom);
						NSLog(@"PropertyNotify: Atom name is '%s' \n", data);
						XFree(data);
						}
#endif
					break;
					}
				case ReparentNotify:					// a client successfully
					NSDebugLog(@"ReparentNotify\n");	// reparents a window
#if FIXME
					if(__xAppTileWindow == xe.xreparent.window)
						{ // WM reparenting appicon
						_wAppTileWindow = xe.xreparent.parent;
					//	[window xSetFrameFromXContentRect: [window xFrame]];
						XSelectInput(_display, _wAppTileWindow, StructureNotifyMask);
						// FIXME: should this be an NSNotification?
						}
#endif
					break;
				case ResizeRequest:						// another client (or WM) attempts to change window size
					NSDebugLog(@"ResizeRequest"); 
					break;
				case SelectionNotify:
					NSLog(@"SelectionNotify");
					{
//						NSPasteboard *pb = [NSPasteboard generalPasteboard];

						// FIXME: should this be an NSNotification? Or where should we send this event to?
//						[pb _handleSelectionNotify:(XSelectionEvent *)&xe];

						e = [NSEvent otherEventWithType:NSFlagsChanged	
											   location:NSZeroPoint
										  modifierFlags:0
											  timestamp:X11toTimestamp(xe.xbutton)
										   windowNumber:windowNumber	// 0 ??
												context:self
												subtype:0
												  data1:0
												  data2:0];
						break;
					}					
				case SelectionClear:						// X selection events 
				case SelectionRequest:
					NSLog(@"SelectionRequest");
#if FIXME
					xHandleSelectionRequest((XSelectionRequestEvent *)&xe);
#endif
					break;
				case VisibilityNotify:						// window's visibility 
					NSDebugLog(@"VisibilityNotify");		// has changed
					break;
				default:									// should not get here
					NSLog(@"Received an untrapped event");
					break;
				} // end of event type switch
			if(e != nil)
				[NSApp postEvent:e atStart:NO];			// add event to app queue
			}
		}
}

@end

@implementation NSColor (NSBackendOverride)

+ (id) allocWithZone:(NSZone *) z;
{
	return NSAllocateObject([_NSX11Color class], 0, z?z:NSDefaultMallocZone());
}

@end

@implementation _NSX11Color

- (unsigned long) _pixelForScreen:(Screen *) scr;
{
	// FIXME: we must cache different pixel values for different screens!
	if(!_colorData || _screen != scr)
		{ // not yet cached or for a different screen
		NSColor *color;
		_screen=scr;
		if(!(_colorData = objc_malloc(sizeof(XColor))))
			[NSException raise:NSMallocException format:@"Unable to malloc XColor backend structure"];
		if(_colorspaceName != NSDeviceRGBColorSpace)
			color=(_NSX11Color *) [self colorUsingColorSpaceName:NSDeviceRGBColorSpace];	// convert
		else
			color=self;
		if(self)
			{
			((XColor *) _colorData)->red = (unsigned short)(65535 * [color redComponent]);
			((XColor *) _colorData)->green = (unsigned short)(65535 * [color greenComponent]);
			((XColor *) _colorData)->blue = (unsigned short)(65535 * [color blueComponent]);
			}
		if(!self || !scr || !XAllocColor(_display, XDefaultColormapOfScreen(scr), _colorData))
			{
			NSLog(@"Unable to allocate color %@ for X11 Screen %08x", color, scr);
			return 0;
			}
#if OLD
		else
			{ // Copy actual values back to the NSColor variables
			_rgb.red = ((float) (((XColor *) _colorData)->red)) / 65535;
			_rgb.green = ((float) (((XColor *) _colorData)->green)) / 65535;
			_rgb.blue = ((float) (((XColor *) _colorData)->blue)) / 65535;
			_color.rgb=YES;
			}
#endif
		}
	return ((XColor *) _colorData)->pixel;
}

- (void) dealloc;
{
	if(_colorData)
		objc_free(_colorData);
	[super dealloc];
}

@end

@implementation NSFont (NSBackendOverride)

+ (id) allocWithZone:(NSZone *) z;
{
	return NSAllocateObject([_NSX11Font class], 0, z?z:NSDefaultMallocZone());
}

@end

@implementation _NSX11Font

- (NSFont *) screenFontWithRenderingMode:(NSFontRenderingMode) mode;
{ // make it a screen font
	if(_fontStruct)
		return nil;	// is already a screen font!
	// FIXME: check if we either have no transform matrix or it is an identity matrix
	if((self=[[self copy] autorelease]))
		{
		_renderingMode=mode;	// make it a bitmapped screen font
		[self _setScale:1.0];
		if(![self _font])
			{ // try to make it a screen font
			[self release];
			return nil;
			}
		}
	return self;
}

- (void) _setScale:(float) scale;
{ // scale font
	scale*=10.0;
	if(_fontScale != scale)
		{ // has been changed
		_fontScale=scale;
		if(_fontStruct)
			{ // clear cache
			XFreeFont(_display, _fontStruct);	// no longer needed
			_fontStruct=NULL;
			}
		}
}

- (XFontStruct *) _font;
{
	NSString *name=[self fontName];
#if 0
	NSLog(@"_font %@ %.1f", name, [self pointSize]);
#endif
	if(_fontScale == 1.0 && _unscaledFontStruct)
		return _unscaledFontStruct;
//	if(_renderingMode != NSFontDefaultRenderingMode)
//		[NSException raise:NSGenericException format:@"Is not a screen font %@:%f", name, [self pointSize]];		
	if(!_fontStruct)
		{
		char *xFoundry = "*";
		char *xFamily = "*";									// default font family 
		char *xWeight = "*";									// font weight (light, bold)
		char *xSlant = "r";										// font slant (roman, italic, oblique)
		char *xWidth = "*";										// width (normal, condensed, narrow)
		char *xStyle = "*";										// additional style (sans serif)
		char *xPixel = "*";
		char xPoint[32];										// variable size
		char *xXDPI = "*";										// we could try to match screen resolution first and try again with *
		char *xYDPI = "*";
		char *xSpacing = "*";									// P proportional, M monospaced, C cell
		char *xAverage = "*";									// average width
		char *xRegistry = "*";
		char *xEncoding = "*";
		NSString *xf = nil;
		
		if(!_display)
			[NSScreen class];	// +initialize
			// [NSException raise:NSGenericException format:@"font %@: no _display: %@", self, xf];
		sprintf(xPoint, "%.0f", _fontScale*[self pointSize]);	// scaled font for X11 server
		
		if([name caseInsensitiveCompare:@"Helvetica"] == NSOrderedSame)
			{
			xFamily = "helvetica";
			xWeight = "medium";
			}
		else if([name caseInsensitiveCompare:@"Helvetica-Bold"] == NSOrderedSame)
			{
			xFamily = "helvetica";
			xWeight = "bold";
			}
		else if(([name caseInsensitiveCompare: @"Courier"] == NSOrderedSame))
			{
			xFamily = "courier";
			xWeight = "medium";
			}
		else if(([name caseInsensitiveCompare: @"Courier-Bold"] == NSOrderedSame))
			{
			xFamily = "courier";
			xWeight = "bold";
			}
		else if(([name caseInsensitiveCompare: @"Ohlfs"] == NSOrderedSame))
			{
			xFamily="fixed";
			xWidth="ohlfs";
			xRegistry="iso8859";
			xFamily="1";
			}
		xf=[NSString stringWithFormat: @"-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s",
			xFoundry, xFamily, xWeight, xSlant, xWidth, xStyle,
			xPixel, xPoint, xXDPI, xYDPI, xSpacing, xAverage,
			xRegistry, xEncoding];
		if((_fontStruct = XLoadQueryFont(_display, [xf cString])))	// Load X font
			return _fontStruct;
		xWeight="*";	// any weight
		xf=[NSString stringWithFormat: @"-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s",
			xFoundry, xFamily, xWeight, xSlant, xWidth, xStyle,
			xPixel, xPoint, xXDPI, xYDPI, xSpacing, xAverage,
			xRegistry, xEncoding];
		if((_fontStruct = XLoadQueryFont(_display, [xf cString])))	// Load X font
			return _fontStruct;
		xFamily="*";	// any family
		xf=[NSString stringWithFormat: @"-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s",
			xFoundry, xFamily, xWeight, xSlant, xWidth, xStyle,
			xPixel, xPoint, xXDPI, xYDPI, xSpacing, xAverage,
			xRegistry, xEncoding];
		if((_fontStruct = XLoadQueryFont(_display, [xf cString])))	// Load X font
			return _fontStruct;
		NSLog(@"font: %@ is not available", xf);
		NSLog(@"Trying 9x15 system font instead");			
		if((_fontStruct = XLoadQueryFont(_display, "9x15")))
		   return _fontStruct;	// "9x15" exists
		NSLog(@"Trying fixed font instead");			
		if((_fontStruct = XLoadQueryFont(_display, "fixed")))
			return _fontStruct;	// "fixed" exists
		[NSException raise:NSGenericException format:@"Unable to open any fixed font for %@:%f", name, [self pointSize]];
		return NULL;	// here we should return nil for screenFont because we can't get one
		}
	return _fontStruct;
}

- (NSSize) _sizeOfString:(NSString *) string;
{ // get size from X11 font assuming no scaling
	unsigned length=[string length];
	NSSize size;
	if(!_unscaledFontStruct)
		{
		_fontScale=10.0;
		[self _font];			// load font data
		_unscaledFontStruct=_fontStruct;
		_fontStruct=NULL;		// recache if we need a different scaling
		}
	size=NSMakeSize(XTextWidth16(_unscaledFontStruct, XChar2bFromString(string, NO), length), (((XFontStruct *)_unscaledFontStruct)->ascent + ((XFontStruct *)_unscaledFontStruct)->descent));	// character box
#if 0
	NSLog(@"%@[%@] -> %@ (C: %d)", self, string, NSStringFromSize(size), XTextWidth(_fontStruct, [string cString], length));
#endif
	return size;	// return size of character box
}

- (void) dealloc;
{
	if(_fontStruct)
		XFreeFont(_display, _fontStruct);	// no longer needed
	if(_unscaledFontStruct)
		XFreeFont(_display, _unscaledFontStruct);	// no longer needed
	[super dealloc];
}

@end

@implementation NSCursor (NSBackendOverride)

+ (id) allocWithZone:(NSZone *) z;
{
	return NSAllocateObject([_NSX11Cursor class], 0, z?z:NSDefaultMallocZone());
}

@end

@implementation _NSX11Cursor

- (Cursor) _cursor;
{
	if(!_cursor)
		{
		if(_image)
			{
#if FIXME
			// we should lockFocus on a Pixmap and call _draw:bestRep
			NSBitmapImageRep *bestRep = [_image bestRepresentationForDevice:nil];	// get device description??
			Pixmap mask = (Pixmap)[bestRep xPixmapMask];
			Pixmap bits = (Pixmap)[bestRep xPixmapBitmap];
			_cursor = XCreatePixmapCursor(_display, bits, mask, &fg, &bg, _hotSpot.x, _hotSpot.y);
#endif
			}
		if(!_cursor)
			return None;	// did not initialize
		}
	return _cursor;
}

- (void) dealloc;
{
	if(_cursor)
		XFreeCursor(_display, _cursor);	// no longer needed
	[super dealloc];
}

@end

// EOF