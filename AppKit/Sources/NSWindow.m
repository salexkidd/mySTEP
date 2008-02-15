/* 
   NSWindow.m

   Window class

   Copyright (C) 1998 Free Software Foundation, Inc.

   Author:  Felipe A. Rodriguez <far@pcmagic.net>
   Date:    June 1998
   
   This file is part of the mySTEP Library and is provided
   under the terms of the GNU Library General Public License.
*/ 

#import <Foundation/NSString.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSValue.h>
#import <Foundation/NSException.h>
#import <Foundation/NSEnumerator.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSDictionary.h>

#import <AppKit/NSWindow.h>
#import <AppKit/NSWindowController.h>
#import <AppKit/NSPanel.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSCachedImageRep.h>
#import <AppKit/NSTextFieldCell.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSSliderCell.h>
#import <AppKit/NSButtonCell.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSCursor.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSToolbar.h>
#import <AppKit/NSAnimation.h>
#import <AppKit/NSBezierPath.h>

#import "NSAppKitPrivate.h"
#import "NSBackendPrivate.h"

#define NOTE(notif_name) NSWindow##notif_name##Notification

// Class variables
static id __responderClass = nil;
static id __lastKeyDown = nil;
static id __frameNames = nil;
static BOOL __cursorHidden = NO;

@interface NSView (LifeResize)
- (void) _performOnAllSubviews:(SEL) sel;
@end

@implementation NSView (LifeResize)
- (void) _performOnAllSubviews:(SEL) sel
{
	NSEnumerator *e=[sub_views objectEnumerator];
	NSView *v;
	[self performSelector:sel];
	while((v=[e nextObject]))
		[v _performOnAllSubviews:sel];
}
@end

@interface _NSThemeWidget : NSButton
- (id) initWithFrame:(NSRect) f forStyleMask:(unsigned int) aStyle;
@end

@interface _NSThemeCloseWidget : _NSThemeWidget
{
	BOOL isDocumentEdited;
}
- (BOOL) isDocumentEdited;
- (void) setDocumentEdited:(BOOL) flag;	// changes image
@end

@interface NSThemeFrame : NSView
{
	NSString *_title;
	NSImage *_titleIcon;
	NSButton *_resizeButton;	// really here?
	NSToolbar *_toolbar;
	NSColor *_backgroundColor;	// window background color
	float _height;	// title bar height
	unsigned int _style;
	BOOL _inLiveResize;
	BOOL _didSetShape;
}

// handle active/inactive by dimming out everything

- (id) initWithFrame:(NSRect) frame forStyleMask:(unsigned int) aStyle forScreen:(NSScreen *) screen;
- (unsigned int) style;

- (NSString *) title;
- (void) setTitle:(NSString *) title;
- (NSImage *) titleIcon;
- (void) setTitleIcon:(NSImage *) img;
- (NSColor *) backgroundColor;
- (void) setBackgroundColor:(NSColor *) color;

- (NSButton *) standardWindowButton:(NSWindowButton) button;
- (NSView *) contentView;
- (void) setContentView:(NSView *) view;
- (void) layout;	// set frame of content view to fit to buttons bar and toolbar (if present)
- (NSToolbar *) toolbar;
- (void) setToolbar:(NSToolbar *) toolbar;
- (BOOL) showsToolbarButton;
- (void) setShowsToolbarButton:(BOOL) flag;
- (void) _setTexturedBackground:(BOOL)flag;

@end

@interface NSGrayFrame : NSThemeFrame	// for textured windows
@end

@interface NSNextStepFrame : NSThemeFrame	// for borderless windows (has no buttons and only contentView)
@end

// what about panels?

@interface NSToolbarView : NSView
{
	NSToolbar *_toolbar;
}
- (void) setToolbar:(NSToolbar *) _toolbar;
- (NSToolbar *) toolbar;

@end

@implementation NSThemeFrame

/* FIXME:
* draw icon
* properly handle window resizing
*/

- (BOOL) isOpaque;	{ return YES; }	// only if background color has alpha==1.0
- (BOOL) isFlipped;	{ return YES; }	// to simplify coordinate calculations: titlebar is at (0,0)

- (id) initWithFrame:(NSRect) f forStyleMask:(unsigned int) aStyle forScreen:(NSScreen *) screen;
{
	if((aStyle&GSAllWindowMask) == NSBorderlessWindowMask)
		{
		[self release];
		self=[NSNextStepFrame alloc];
		}
	else if(aStyle&NSTexturedBackgroundWindowMask)
		{
		[self release];
		self=[NSGrayFrame alloc];
		}
	if((self=[super initWithFrame:f]))
		{
		_style=aStyle;
		[self setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];	// resize with window
		[self setAutoresizesSubviews:YES];
		if((aStyle&GSAllWindowMask) != NSBorderlessWindowMask)
			{
			NSButton *b0, *b1, *b2;
			[self addSubview:b0=[NSWindow standardWindowButton:NSWindowCloseButton forStyleMask:aStyle]];
			[self addSubview:b1=[NSWindow standardWindowButton:NSWindowMiniaturizeButton forStyleMask:aStyle]];
			[self addSubview:b2=[NSWindow standardWindowButton:NSWindowZoomButton forStyleMask:aStyle]];
			if([self interfaceStyle] >= NSPDAInterfaceStyle)
				[b1 setHidden:YES], [b2 setHidden:YES];	// standard PDA screen is not large enough for multiple resizable windows
			else
			if((aStyle & (NSClosableWindowMask | NSMiniaturizableWindowMask| NSResizableWindowMask)) == 0)
				{ // no visible buttons!
				[b0 setHidden:YES], [b1 setHidden:YES], [b2 setHidden:YES];
				}
			// add window title button (?)
			}
		[self layout];
		ASSIGN(_backgroundColor, [NSColor windowBackgroundColor]);	// default background
		}
	return self;
}

- (void) dealloc;
{
	[_title release];
	[_titleIcon release];
	[_backgroundColor release];
	[super dealloc];
}

- (void) drawRect:(NSRect)rect
{ // draw window background
	static NSDictionary *a;
	if(!_didSetShape)
		{
		if((_style&NSUtilityWindowMask) == 0)
			{ // make title bar with rounded corners
			NSGraphicsContext *ctxt=[NSGraphicsContext currentContext];
			float radius=9.0;
			NSBezierPath *b=[NSBezierPath new];
			[b appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(_frame)+radius, NSMinY(_frame)+radius)
										  radius:radius
									  startAngle:180.0
										endAngle:270.0
									   clockwise:NO];	// top left corner
			[b appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(_frame)-radius, NSMinY(_frame)+radius)
										  radius:radius
									  startAngle:270.0
										endAngle:360.0
									   clockwise:NO];	// top right corner
			[b lineToPoint:NSMakePoint(NSMaxX(_frame), NSMaxY(_frame))];	// bottom right
			[b lineToPoint:NSMakePoint(0.0, NSMaxY(_frame))];	// bottom left
			[b closePath];
			[ctxt _setShape:b];
			}
		_didSetShape=YES;
		}
	[_backgroundColor set];
	NSRectFill(rect);	// draw window background
	[[NSColor windowFrameColor] set];
	NSFrameRect(_bounds);	// draw a frame
	// FIXME: should also fill background behind a toolbar if present
	NSRectFill((NSRect){NSZeroPoint, {_bounds.size.width, _height}});	// fill titlebar background behind buttons
	if(!_title && !_titleIcon)
		return;
	if(_titleIcon)
		{
		[_titleIcon compositeToPoint:NSMakePoint((_bounds.size.width-[_title sizeWithAttributes:a].width)/2.0-[_titleIcon size].width,
																						 1.0+(_height-16.0)/2.0)
											 operation:NSCompositeSourceOver];
		}
	if(!a)
		a=[[NSDictionary dictionaryWithObjectsAndKeys:		// FIXME: how does this differ from the defaults?
			[NSColor windowFrameTextColor], NSForegroundColorAttributeName,
			// use smaller font for NSUtilityWindowMask - we could e.g. use something like frame.size.height-10
			// but we have only one cache! -> add instance variable _titleAttributes
			[NSFont titleBarFontOfSize:12.0], NSFontAttributeName,
			nil] retain];
	// draw document icon or shouldn't we better use a document NSButton to store the window icon and title?
	// [_titleButton drawInteriorWithFrame:rect between buttons inView:self];
	[_title drawAtPoint:NSMakePoint((_bounds.size.width-[_title sizeWithAttributes:a].width)/2.0, 1.0+(_height-16.0)/2.0) withAttributes:a]; // draw centered window title
	// draw resize area (how to draw it in front of the subviews?) - or add another subview?
}

- (void) unlockFocus;
{ // last chance to draw anything - note that we start with the graphics state left over by the previous operations
	if((_style & NSResizableWindowMask) != 0 && !([self interfaceStyle] >= NSPDAInterfaceStyle))
		{ // draw resizing handle in the lower right corner
		[NSGraphicsContext setGraphicsState:[_window gState]];
		[[NSBezierPath bezierPathWithRect:_bounds] setClip];
		[[NSColor grayColor] set];
#if 0
		[[NSColor redColor] set];
#endif
		[NSBezierPath strokeLineFromPoint:NSMakePoint(_bounds.size.width-2, _bounds.size.height-8)
															toPoint:NSMakePoint(_bounds.size.width-8, _bounds.size.height-2)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(_bounds.size.width-2, _bounds.size.height-11)
															toPoint:NSMakePoint(_bounds.size.width-11, _bounds.size.height-2)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(_bounds.size.width-2, _bounds.size.height-14)
															toPoint:NSMakePoint(_bounds.size.width-14, _bounds.size.height-2)];
		}
	[super unlockFocus];
}

- (unsigned int) style; { return _style; }

- (void) _setTexturedBackground:(BOOL)flag;
{
	_style &= ~NSTexturedBackgroundWindowMask;
	if(flag)
		_style |= NSTexturedBackgroundWindowMask;
	[self setNeedsDisplay:YES];
}

- (NSString *) title; { return _title; }
- (void) setTitle:(NSString *) title; { ASSIGN(_title, title); }
- (NSImage *) titleIcon; { return _titleIcon; }
- (void) setTitleIcon:(NSImage *) img; { ASSIGN(_titleIcon, img); }
- (NSColor *) backgroundColor; { return _backgroundColor; }
- (void) setBackgroundColor:(NSColor *) color; { ASSIGN(_backgroundColor, color); }

- (NSButton *) standardWindowButton:(NSWindowButton) button;
{
	switch(button)
		{
		case NSWindowCloseButton: return [sub_views objectAtIndex:0];
		case NSWindowMiniaturizeButton: return [sub_views objectAtIndex:1];
		case NSWindowZoomButton: return [sub_views objectAtIndex:2];
		case NSWindowToolbarButton: return [sub_views count] > 4?[sub_views objectAtIndex:4]:nil;
		case NSWindowDocumentIconButton:
		default: return nil;
		}
}

- (NSView *) contentView; { return [sub_views count] > 3?[sub_views objectAtIndex:3]:nil; }

- (void) layout;
{ // NOTE: if the window fills the screen, the content view has to be made smaller
	NSView *cv;
	NSRect f=[self frame];
	// handle userspace scaling factor
	_height=[NSWindow _titleBarHeightForStyleMask:_style];
	f.origin.y+=_height;		// add room for buttons
	f.size.height-=_height;
	if(/* toolbar exists and is visible */ NO)
		{
		// resize everything to have room for toolbar frame
		}
	cv=[self contentView];
#if 0
	NSLog(@"layout %@", self);
	NSLog(@"  cv=%@", cv);
	NSLog(@"  frame=%@", NSStringFromRect(f));
#endif
	if(!cv)
		[self addSubview:[[[NSView alloc] initWithFrame:f] autorelease]];	// add an initial content view
	else
		[cv setFrame:f];	// enforce size of content view to fit
	[cv setNeedsDisplay:YES];	// needs redraw
	_didSetShape=NO;	// and reset shape
}

- (void) resizeSubviewsWithOldSize:(NSSize)oldSize
{
	if(!NSEqualSizes(oldSize, _frame.size))
		[self layout];	// resize so that the content view matches our current size
}

- (void) viewWillMoveToWindow:(NSWindow *) win;
{
	if(win)
		[self layout];	// update layout initially
}

- (void) setContentView:(NSView *) view;
{
	NSView *cv=[self contentView];	// current content view
#if 0
	NSLog(@"setContentView %@", self);
	NSLog(@"  view=%@", view);
	NSLog(@"  cv=%@", [self contentView]);
#endif
	[self replaceSubview:cv with:view];	// this checks if a content view exists
	[view setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
	[view setAutoresizesSubviews:YES];	// enforce for content view
	[self layout];
	[self setNeedsDisplay:YES];	// show everything
#if 0
	NSLog(@"self=%@", [self _descriptionWithSubviews]);
#endif	
}

- (NSToolbar *) toolbar; { return [sub_views count] > 4?[[sub_views objectAtIndex:5] toolbar]:nil; }

- (void) setToolbar:(NSToolbar *) toolbar;
{
	if(toolbar && [sub_views count] < 4)
		{ // we don't have a toolbar (yet)
		NSToolbarView *tv;
		NSButton *wb;
		NSRect f, wf;
		[self addSubview:wb=[NSWindow standardWindowButton:NSWindowToolbarButton forStyleMask:_style]];
		[wb setTarget:_window];
		f=[wb frame];		// button frame
		wf=[_window frame];	// window frame
		f.origin.x+=wf.size.width-f.size.width;	// flush toolbar button to the right end
		[wb setFrameOrigin:f.origin];
		tv=[[NSToolbarView alloc] initWithFrame:(NSRect){{0.0, wf.size.width}, {20.0, 20.0}}];	// as wide as the window
		[tv setAutoresizingMask:NSViewMaxYMargin|NSViewWidthSizable];
		[tv setAutoresizesSubviews:YES];
		[self addSubview:tv];
		[tv release];
		}
	if(!toolbar && [sub_views count] >= 4)
		{ // remove
		[[sub_views objectAtIndex:5] removeFromSuperviewWithoutNeedingDisplay];	// toolbar view
		[[sub_views objectAtIndex:4] removeFromSuperviewWithoutNeedingDisplay];	// toolbar button
		}
	else if(toolbar)
		[[sub_views objectAtIndex:5] setToolbar:toolbar];	// update
	[self layout];
}

- (BOOL) showsToolbarButton; { return ![[self standardWindowButton:NSWindowToolbarButton] isHidden]; }
- (void) setShowsToolbarButton:(BOOL) flag; { [[self standardWindowButton:NSWindowToolbarButton] setHidden:!flag]; }

- (BOOL) inLiveResize	{ return _inLiveResize; }

- (BOOL) shouldBeTreatedAsInkEvent:(NSEvent *) theEvent;
{
	return NO;	// don't ink on theme frame...
}

- (BOOL) mouseDownCanMoveWindow; { return YES; }

	// might need to modify hit-test to detect resize...

- (BOOL) acceptsFirstMouse:(NSEvent *) event; { return YES; }	// send us the first event
- (BOOL) acceptsFirstResponder;	{ return YES; }	// to allow selecting the window

- (void) mouseDown:(NSEvent *)theEvent
{ // NSTheme frame
	NSPoint p = [self convertPoint:[theEvent locationInWindow] fromView:nil];
#if 0
	NSLog(@"NSThemeFrame clicked (%@)", NSStringFromPoint(p));
#endif
	if((_style & NSResizableWindowMask) != 0 && ([self interfaceStyle] >= NSPDAInterfaceStyle))
		return;	// resizable window has been enlarged for full screen - don't permit to move
	if(p.y > _height)
		{ // check if we a have resize enabled in _style and we clicked on lower right corner
		if((_style & NSResizableWindowMask) == 0 || p.y < _frame.size.height-10.0 || p.x < _frame.size.width-10.0)
			return;	// ignore if not in title bar (or we ask hitTest's view if it permits for textured windows)
		_inLiveResize=YES;
#if 1
		NSLog(@"liveResize started");
#endif
		// FIXME: should also be called exactly once if view is added/removed repeatedly to the hierarchy during life resize
		[self _performOnAllSubviews:@selector(viewWillStartLiveResize)];
		}
	p=[NSEvent mouseLocation];	// get in screen coordinates
	while(YES)
		{ // loop until mouse goes up
		theEvent = [NSApp nextEventMatchingMask:GSTrackingLoopMask
									  untilDate:[NSDate distantFuture]						// get next event
										 inMode:NSEventTrackingRunLoopMode 
										dequeue:YES];
		
		switch([theEvent type])
			{
			default: break;	// ignore
			case NSLeftMouseUp:					// If mouse went up then we are done
				if(_inLiveResize)
					{
					_inLiveResize=NO;
					[self _performOnAllSubviews:@selector(viewDidEndLiveResize)];
					}
				else
					_inLiveResize=NO;
				return;
			case NSLeftMouseDragged:
				{
					NSRect wframe=[_window frame];
					NSPoint loc=[NSEvent mouseLocation];
					if(_inLiveResize)
						{ // resizing
						wframe.size.width+=(loc.x-p.x);
						wframe.size.height-=(loc.y-p.y);	// resize as mouse moves
						wframe.origin.y+=(loc.y-p.y);		// keep top left corner constant
						// FIXME: handle resizeIncrements
#if 1
						NSLog(@"resize window from (%@) to (%@)", NSStringFromRect([_window frame]), NSStringFromRect(wframe));
#endif
						[_window setFrame:wframe display:YES];
						}
					else
						{ // moving
						wframe.origin.x+=(loc.x-p.x);
						wframe.origin.y+=(loc.y-p.y);	// move as mouse moves
						// FIXME: this has some issues when frame is clipped to the visible screen
#if 0
						NSLog(@"move window from (%@) to (%@)", NSStringFromPoint([_window frame].origin), NSStringFromPoint(wframe.origin));
#endif
						[_window setFrameOrigin:wframe.origin];	// move window (no need to redisplay)
						}
					p=loc;
					break;
				}
			}
  		}
}

@end

@implementation NSGrayFrame		// used for NSTexturedBackgroundWindowMask

// we don't distinguish here
// but might initialize our window for a different layout and style here

@end

@implementation NSNextStepFrame	// used for borderless window

- (void) drawRect:(NSRect)rect
{ // draw window background only (no title, no shape!)
	[_backgroundColor set];
	NSRectFill(rect);	// draw window background
}

- (NSButton *) standardWindowButton:(NSWindowButton) button;
{
	return nil;	// has no buttons
}

- (NSView *) contentView; { return [sub_views count] > 0?[sub_views objectAtIndex:0]:nil; }

- (void) layout;
{ // we don't have a button bar
	NSView *cv=[self contentView];
	NSRect f=[self frame];
#if 0
	NSLog(@"layout %@", self);
	NSLog(@"  cv=%@", cv);
	NSLog(@"  frame=%@", NSStringFromRect(f));
#endif
	if(!cv)
		[self addSubview:[[[NSView alloc] initWithFrame:f] autorelease]];	// add an initial content view
	else
		[cv setFrame:f];	// enforce size of content view to fit
	[cv setNeedsDisplay:YES];	// needs redraw
}

- (void) setToolbar:(NSToolbar *) toolbar; { NIMP; }	// can't save/create for borderless windows

// - (BOOL) mouseDownCanMoveWindow; { return YES; } but only in titlebar area!

@end

@implementation _NSThemeWidget

- (id) initWithFrame:(NSRect) f forStyleMask:(unsigned int) aStyle;
{
	if((self=[super initWithFrame:f]))
		{
		[self setButtonType:NSMomentaryChangeButton];	// toggle images
		[self setAutoresizesSubviews:YES];
		[self setAutoresizingMask:(NSViewMaxXMargin|NSViewMinYMargin)];	// don't resize with window
		[_cell setAlignment:NSCenterTextAlignment];
		[_cell setImagePosition:NSImageOverlaps];
		[_cell setBordered:NO];	// no bezel
		[_cell setFont:[NSFont titleBarFontOfSize:0]];
		}
	return self;
}

- (void) viewDidMoveToWindow
{ // set window as target for buttons
	[self setTarget:_window];
}

- (BOOL) shouldDelayWindowOrderingForEvent:(NSEvent*)event	{ return YES; }		// always delay window ordering
- (BOOL) acceptsFirstResponder; { return NO; }
- (BOOL) acceptsFirstMouse; { return YES; }

- (void) mouseDown:(NSEvent *) e;
{
	[NSApp preventWindowOrdering];	// don't ever order front
	[super mouseDown:e];
}

@end

@implementation _NSThemeCloseWidget

- (BOOL) isDocumentEdited; { return isDocumentEdited; }
- (void) setDocumentEdited:(BOOL) flag;
{
	isDocumentEdited=flag;
	[self setImage:[NSImage imageNamed:flag?@"NSWindowChangedButton":@"NSWindowCloseButton"]];	// change button image
	[self setNeedsDisplay];
	// notify backend
}

@end

@implementation NSToolbarView

- (void) setToolbar:(NSToolbar *) toolbar;
{
	ASSIGN(_toolbar, toolbar);
	// layout
}

- (NSToolbar *) toolbar; { return _toolbar; }

// ADDME: handle mouse-down and tracking etc.

@end

@implementation NSWindow

+ (void) initialize
{
	if (self == [NSWindow class])
		{
		NSDebugLog(@"Initialize NSWindow class\n");
		__responderClass = [NSResponder class];
		}
}

+ (NSWindowDepth) defaultDepthLimit							{ return 32; }

+ (NSRect) contentRectForFrameRect:(NSRect)aRect
						 styleMask:(unsigned int)aStyle
{
	aRect.size.height-=[self _titleBarHeightForStyleMask:aStyle];  // remove space for title bar
	return aRect;
}

+ (NSRect) frameRectForContentRect:(NSRect)aRect
						 styleMask:(unsigned int)aStyle
{
	aRect.size.height+=[self _titleBarHeightForStyleMask:aStyle];  // make space for title bar
	return aRect;
}

+ (float) minFrameWidthWithTitle:(NSString *)aTitle
						styleMask:(unsigned int)aStyle
{
	return 0.0;
}

+ (float) _titleBarHeightForStyleMask:(unsigned int) mask
{ // make dependent on total window height (i.e. smaller title bar on a QVGA PDA screen)
	if((mask&GSAllWindowMask) == NSBorderlessWindowMask && [[NSScreen screens] count] > 0)
		return 0.0;	// no title bar
	if([[[NSScreen screens] objectAtIndex:0] frame].size.height < 400)
		return (mask&NSUtilityWindowMask)?12.0:16.0;
	else
		return (mask&NSUtilityWindowMask)?16.0:23.0;
}

- (void) dealloc
{
#if 0
	NSLog(@"dealloc - %@ [%d]", self, [self retainCount]);
#endif
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidChangeScreenParametersNotification object:nil];
	[self resignKeyWindow];
#if 1
	NSLog(@"a");
#endif
	[self resignMainWindow];
	[self setDelegate:nil];	// release delegate
	[_windowController release];
	[_fieldEditor release];	// if it exists
	[_themeFrame _setWindow:nil];
#if 0
	NSLog(@"b3");
#endif
	[_themeFrame release]; // delete old one (does not really have a superview, therefore we don't call removeFromSuperview)
#if 0
	NSLog(@"c");
#endif
	//	[_backgroundColor release];
	[_miniWindowImage release];
	[_miniWindowTitle release];
	[_representedFilename release];
	[_windowTitle release];
#if 0
	NSLog(@"d");
#endif
	[_frameSaveName release];
	[_context release];	// if still existing
#if 0
	NSLog(@"e");
#endif
	[super dealloc];
}

- (id) init
{
	NSLog(@"should not -init NSWindow");
	return [self initWithContentRect:NSMakeRect(0.0, 0.0, 48.0, 48.0)
				 styleMask:GSAllWindowMask				// default style mask
				 backing:NSBackingStoreBuffered
				 defer:NO
				 screen:nil];
}

- (NSWindow *) initWithWindowRef:(void *) ref;
{
	if((self=[super init]))
		{
		_context=[[NSGraphicsContext graphicsContextWithGraphicsPort:ref flipped:YES] retain];
		[self _setFrame:[_context _frame]];	// get frame from existing window
		_w.isOneShot=NO;
		// FIXME: anything else to init?
		}
	return self;
}

- (void) _screenParametersNotification:(NSNotification *) notification;
{
#if 0
	NSLog(@"%@ _screenParametersNotification: %@", NSStringFromClass([self class]), notification);
#endif
	if(notification)
		; // FIXME: we might have to rearrange menu bars! - better solutions: menu bars separately register for this notification
	if( _w.visible)
		[self orderFront:nil];	// this will resize the window if needed
}

- (id) initWithContentRect:(NSRect)cRect
				 styleMask:(unsigned int)aStyle
				   backing:(NSBackingStoreType)bufferingType
					 defer:(BOOL)flag
{
	return [self initWithContentRect:cRect 
						   styleMask:aStyle
							 backing:bufferingType 
							   defer:flag 
							  screen:nil];
}

- (id) initWithContentRect:(NSRect)cRect
				 styleMask:(unsigned int)aStyle
				 backing:(NSBackingStoreType)bufferingType
				 defer:(BOOL)defer
				 screen:(NSScreen *)aScreen
{
	if((self=[super init]))
		{
#if 0
		NSLog(@"NSWindow initWithContentRect:%@ styleMask:%04x backing:%04x screen:%@", NSStringFromRect(cRect), aStyle, bufferingType, aScreen);
#endif
		_miniWindowTitle = _windowTitle = _representedFilename = @"Window";
		if(!aScreen)
			aScreen=[NSScreen mainScreen];	// use main screen (defined by keyWindow) if possible
		if(!aScreen)
			aScreen=[[NSScreen screens] objectAtIndex:0];	// menu bar screen if there is no main screen (yet)
		if(!aScreen)
			[NSException raise:NSGenericException format:@"Unable to find a default NSScreen"];
		_screen=aScreen;	// screens are never released
		_w.menuExclude = [self isKindOfClass:[NSPanel class]];
		if(_w.menuExclude)
			_level=NSModalPanelWindowLevel;	// default for NSPanels
		else
			_level=NSNormalWindowLevel;	// default for NSWindows
		if(aStyle&NSUnscaledWindowMask)
			_userSpaceScaleFactor=1.0;
		else
			_userSpaceScaleFactor=[_screen userSpaceScaleFactor];	// ask the screen
		_w.backingType = bufferingType;
		_w.styleMask = aStyle;
		_w.needsDisplay = NO;	// will be set by first expose
		_w.autodisplay = YES;
		_w.optimizeDrawing = YES;
		_w.dynamicDepthLimit = YES;
		_w.releasedWhenClosed = YES;
		_w.acceptsMouseMoved = NO;  // default
		_w.cursorRectsEnabled = YES;
		_w.canHide = YES;
		_w.hidesOnDeactivate = YES;
		_frame=[NSWindow frameRectForContentRect:cRect styleMask:aStyle];		// get requested screen frame
		_themeFrame=[[NSThemeFrame alloc] initWithFrame:(NSRect){{0, 0}, _frame.size} forStyleMask:aStyle forScreen:_screen];	// create view hierarchy
		[_themeFrame _setWindow:self];
		[_themeFrame setNextResponder:self];
		[self setNextResponder:NSApp];	// NSApp is next responder
		[[NSCursor arrowCursor] push];	// push the arrow as the default cursor	- FIXME: why are we doing that for every new window???
		if(!defer)
			[self orderWindow:NSWindowAbove relativeTo:0];	// insert sort relative to self; add to Window menu when being mapped
#if 0
		NSLog(@"NSWindow end of designated initializer\n");
#endif
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(_screenParametersNotification:)
													 name:NSApplicationDidChangeScreenParametersNotification
												   object:nil];
		}
	return self;
}

- (NSString *) title						{ return _windowTitle; }
- (NSString *) miniwindowTitle				{ return _miniWindowTitle; }
- (NSString *) representedFilename			{ return _representedFilename; }
- (NSImage *) miniwindowImage				{ return _miniWindowImage; }
- (unsigned int) styleMask					{ return _w.styleMask; }
- (void)setBackingType:(NSBackingStoreType)t{ _w.backingType = t; }	// FIXME: should be reflected in the backend!
- (NSBackingStoreType) backingType			{ return _w.backingType; }
- (NSDictionary *) deviceDescription		{ return [_screen deviceDescription]; }
- (NSGraphicsContext*) graphicsContext		{ return _context; }
- (int) gState								{ return _gState; }
- (int) windowNumber						{ return [_context _windowNumber]; }
- (void *) windowRef						{ return [_context graphicsPort]; }
- (NSColor *) backgroundColor				{ return [(NSThemeFrame *) _themeFrame backgroundColor]; }
- (void) setBackgroundColor:(NSColor*)color	{ [(NSThemeFrame *) _themeFrame setBackgroundColor:color]; }
- (void) setMiniwindowImage:(NSImage*)image	{ ASSIGN(_miniWindowImage,image); }
- (void) setOneShot:(BOOL)flag				{ _w.isOneShot = flag; }
- (void) _setTexturedBackground:(BOOL)flag;	{ [(NSThemeFrame *) _themeFrame _setTexturedBackground:flag]; }

- (void) setTitle:(NSString*)aString
{
	ASSIGN(_windowTitle, aString);						// local cache
	[(NSThemeFrame *) _themeFrame setTitle:aString];	// theme frame
	[_context _setTitle:aString];						// backend might want to pass to some window manager
	[(NSThemeFrame *) _themeFrame setTitleIcon:nil];				// no icon
	if(_w.visible && !_w.menuExclude)
		[NSApp changeWindowsItem:self title:_windowTitle filename:NO];
}

- (void) setTitleWithRepresentedFilename:(NSString*)aString
{
	aString=[aString stringByExpandingTildeInPath];
	[self setRepresentedFilename: aString];
	ASSIGN(_windowTitle, [aString lastPathComponent]);						// local cache
	[(NSThemeFrame *) _themeFrame setTitle:aString];	// theme frame
	[_context _setTitle:aString];						// backend might want to pass to some window manager
	if([aString isAbsolutePath])
		[(NSThemeFrame *) _themeFrame setTitleIcon:[[NSWorkspace sharedWorkspace] iconForFile:aString]];	// get document icon - if found
	if(_w.visible && !_w.menuExclude)
		[NSApp changeWindowsItem:self title:_windowTitle filename:YES];
}

- (BOOL) isOneShot							{ return _w.isOneShot; }
- (id) contentView							{ return [(NSThemeFrame *) _themeFrame contentView]; }

- (void) setContentView:(NSView *)aView				
{
#if 0
	NSLog(@"setContentView: %@", [aView _descriptionWithSubviews]);
#endif
	[(NSThemeFrame *) _themeFrame setContentView:aView];
}

- (void) setRepresentedFilename:(NSString *)aString
{
	ASSIGN(_representedFilename, aString);
}

- (void) setMiniwindowTitle:(NSString *)title
{
	ASSIGN(_miniWindowTitle, title);
	//	if (_w.miniaturized == NO);					// FIX ME redisplay miniWin
}

- (void) endEditingFor:(id)anObject					// field editor
{
#if 1
	NSLog(@"NSWindow endEditingFor: %@", anObject);
#endif
	if(![_fieldEditor resignFirstResponder] && _fieldEditor == _firstResponder)
		{ // if not force resignation
		NSLog(@" NSWindow endEditingFor: current field editor did not resign voluntarily.");
		[[NSNotificationCenter defaultCenter] postNotificationName:NSTextDidEndEditingNotification
							object:_fieldEditor];
		[(_firstResponder = self) becomeFirstResponder];
		}
}

- (NSText *) fieldEditor:(BOOL)createFlag forObject:(id)anObject
{
	SEL s = @selector(windowWillReturnFieldEditor:toObject:);
	NSText *d;											// ask delegate if it can provide a field editor
	if (_delegate && [_delegate respondsToSelector:s])
		if ((d = [_delegate windowWillReturnFieldEditor:self toObject:anObject]))
			return d;
	if(!_fieldEditor && createFlag)					// each window has a global
		{											// text field editor, if it
		_fieldEditor = [NSTextView new];			// doesn't exist create it
		[_fieldEditor setFieldEditor:YES]; 			// if create flag is set					 
		}
	return _fieldEditor;							
}

- (int) level								{ return _level; }
- (BOOL) canHide							{ return _w.canHide; }
- (BOOL) hidesOnDeactivate					{ return _w.hidesOnDeactivate; }
- (BOOL) isMiniaturized						{ return _w.miniaturized; }
- (BOOL) isVisible							{ return _w.visible; }

- (void) _setIsVisible:(BOOL) flag
{
	if(_w.visible == flag)
		return;
	_w.visible=flag;
}

- (BOOL) isKeyWindow						{ return [_context _windowNumber] == [_screen _keyWindowNumber]; }	// this asks the backend if we are really the key window!
- (BOOL) isMainWindow						{ return _w.isMain; }

- (void) becomeKeyWindow
{
#if 0
	NSLog(@"becomeKeyWin %@", _windowTitle);
#endif
	if(_w.isKey)	// we are already key window
		return;
	_w.isKey = YES;
	if(_w.visible)	// already visible
		{
#if 0
		NSLog(@"becomeKeyWindow _makeKeyWindow");
#endif
		[_context _makeKeyWindow];
		[_context flushGraphics];
		}
	if(!_w.cursorRectsValid)
		[self resetCursorRects];	
	[_firstResponder becomeFirstResponder];
	[[NSNotificationCenter defaultCenter] postNotificationName: NOTE(DidBecomeKey) object: self];
}

- (void) becomeMainWindow
{
	if (_w.isMain)
		return;										
	_w.isMain = YES;								// We are the main window
	[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeMainNotification object: self];
}

- (BOOL) canBecomeKeyWindow					
{ 
	return (_w.styleMask & (NSTitledWindowMask|NSResizableWindowMask)); 
}

- (BOOL) canBecomeMainWindow					
{ 
	return (_w.styleMask & (NSTitledWindowMask|NSResizableWindowMask));
}

- (void) makeKeyAndOrderFront:(id) sender
{
#if 0
	NSLog(@"makeKeyAndOrderFront: %@", self);
#endif
	[self orderFront:sender];						// order self to the front
#if 0
	NSLog(@"isKey: %d", _w.isKey);
#endif
	if(!_w.isKey)
		{
		[self makeKeyWindow];						// Make self the key window
		[self makeMainWindow];
		}
}

- (void) makeKeyWindow
{													// Can we become the key
#if 0
	NSLog(@"makeKeyWindow: %@", self);
#endif
	if ((_w.isKey) || ![self canBecomeKeyWindow]) 	// window?
		return;										
	[[NSApp keyWindow] resignKeyWindow];			// ask current key window to resign status
	[self becomeKeyWindow];
}													 
	
- (void) makeMainWindow
{													// Can we become main win
	if ((_w.isMain) || ![self canBecomeMainWindow])
		return;
													// ask current main window
	[[NSApp mainWindow] resignMainWindow];			// to resign status
	[self becomeMainWindow];
}													

- (void) resignKeyWindow
{
#if 0
	NSLog(@"resignKeyWindow");
#endif
	if (!(_w.isKey))
		return;
	_w.isKey = NO;
	[_firstResponder resignFirstResponder];
	[NSCursor pop];									// empty cursor stack
	[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object: self];
#if 0
	NSLog(@"notified");
#endif
}

- (void) resignMainWindow
{
	if (!(_w.isMain))
		return;
	_w.isMain = NO;
	[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignMainNotification object:self];
}

- (void) orderWindow:(NSWindowOrderingMode) place 
		  relativeTo:(int) otherWin
{ // main interface call
#if 0
	NSString *str[]={ @"Below", @"Out", @"Above" };
	NSLog(@"orderWindow:NSWindow%@ relativeTo:%d - %@", str[place+1], otherWin, self);
#endif
	if(place == NSWindowOut)
		{ // close window
		if(_w.isOneShot)
			{ // also close screen representation
			[_context release];
			_context=nil;
			_gState=0;
			return;
			}
		}
	else
		{
		if(!_context)
			{ // allocate context (had been temporarily deallocated if we are a oneshot window)
			_context=[[NSGraphicsContext graphicsContextWithWindow:self] retain];	// now, create window
			_gState=[_context _currentGState];			// save gState
			}
		[self setFrame:[self constrainFrameRect:_frame toScreen:_screen] display:_w.visible animate:_w.visible];	// constrain window frame if needed
		if(!_w.visible)
			{
			_w.needsDisplay = NO;							// reset first - display may result in callbacks that will set this flag again
			[_themeFrame displayIfNeeded];					// Draw the window view hierarchy (if changed) before mapping
			}
		}
	if(!otherWin)
		{ // find first/last window on same level to place in front/behind
		int level;
//		int n=[NSScreen _windowListForContext:0 size:0 list:NULL];
		// int *list=(int *) objc_malloc(n*sizeof(int));
//		[NSScreen _windowListForContext:0 size:n list:list];
		// for(otherWin=0; otherWin<n; otherWin++)
//			level=[NSWindow _getLevelOfWindowNumber:otherWin];
		// compare levels
		// determine relevant 'other window' according to current level (might still be 0 if we are the first window)
		}
	[_context _orderWindow:place relativeTo:otherWin];	// request map/umap from beackend
	[_context flushGraphics];							// and directly send to the server
	while(place == NSWindowOut?_w.visible:!_w.visible)
		{ // queue events until window becomes (in)visible
		[[NSRunLoop currentRunLoop] runMode:NSEventTrackingRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];	// wait some fractions of a second...
		}
#if 0
	if(_w.isKey && place != NSWindowOut)
		NSLog(@"orderWindow XSetInputFocus");
#endif
	if(_w.isKey && place != NSWindowOut)
		[_context _makeKeyWindow];
	if(!_w.menuExclude)
		[NSApp changeWindowsItem:self title:_windowTitle filename:NO];	// update
}

// convenience calls

// FIXME: don't move a window in front of the key window unless both are in the same application
// make dependent on [self isKeyWindodow];

- (void) orderFront:(id) Sender; { [self orderWindow:NSWindowAbove relativeTo:0]; }
- (void) orderBack:(id) Sender; { [self orderWindow:NSWindowBelow relativeTo:0]; }
- (void) orderOut:(id) Sender; { [self orderWindow:NSWindowOut relativeTo:0]; }
- (void) orderFrontRegardless	{ [self orderFront:nil]; }

- (void) setLevel:(int)newLevel
{
	if(_level == newLevel)
		return;	// unchanged
	_level=newLevel;
	[_context _setLevel:newLevel];	// save in window list
	if(_w.visible)
		[self orderWindow:NSWindowAbove relativeTo:0];	// and immediately rearrange
}

- (void) setCanHide:(BOOL)flag				{ _w.canHide = flag; }
- (void) setHidesOnDeactivate:(BOOL)flag	{ _w.hidesOnDeactivate = flag; }

- (NSPoint) cascadeTopLeftFromPoint:(NSPoint)topLeftPoint
{
	static NSPoint cascadePoint = { 0, 0 };
	NSSize screenSize = [_screen visibleFrame].size;
	NSPoint new = { topLeftPoint.x + 25, topLeftPoint.y - 25 };

	if(NSEqualPoints(topLeftPoint, NSZeroPoint))
		; // constrain to screen but don't move
	else
		[self setFrameTopLeftPoint:topLeftPoint];

	if(new.x + _frame.size.width > screenSize.width)
		{
		new.x = 30 + cascadePoint.x;
		cascadePoint.x = (cascadePoint.x < 200) ? cascadePoint.x + 50 : 25;
		}
	if(new.y - _frame.size.height < 0)
		{
		new.y = screenSize.height - (30 + cascadePoint.y);
		cascadePoint.y = (cascadePoint.y < 200) ? cascadePoint.y + 50 : 25;
		}
	return new;
}

- (void) center
{ // center the window within it's screen
	NSSize screenSize = [_screen visibleFrame].size;
	NSPoint origin = _frame.origin;
	origin.x = (screenSize.width - _frame.size.width) / 2;
	origin.y = (screenSize.height - _frame.size.height) / 2;
	[self setFrameOrigin:origin];
}

- (NSRect) constrainFrameRect:(NSRect)rect toScreen:(NSScreen *)screen
{
	NSRect vf;
#if 0
	NSLog(@"constrain rect %@ forscreen %@", NSStringFromRect(rect), NSStringFromRect([screen visibleFrame]));
#endif
	if((_w.styleMask&GSAllWindowMask) == NSBorderlessWindowMask)
		return rect;	// never constrain
	vf=[screen visibleFrame];
#if 0
#if __APPLE__
	vf=NSMakeRect(100.0, 100.0, 800.0, 500.0);	// special constraining for test purposes on the Mac
#endif
#endif
	if((_w.styleMask & NSResizableWindowMask) && [self interfaceStyle] >= NSPDAInterfaceStyle)
		return vf;	// resize to full screen for PDA styles
	if(NSMaxX(rect) > NSMaxX(vf))
		rect.origin.x=NSMaxX(vf)-NSWidth(rect);	// goes beyond right edge - move left
	if(NSMinX(rect) < NSMinX(vf))
		rect.origin.x=NSMinX(vf);	// goes beyond left edge - move right
	if(NSMaxY(rect) > NSMaxY(vf))
		rect.origin.y=NSMaxY(vf)-NSHeight(rect);	// goes beyond top edge - move down
	if(NSMinY(rect) < NSMinY(vf))
		rect.origin.y=NSMinY(vf);	// goes beyond top edge - move down
#if 0
	NSLog(@"shifted frameRect %@", NSStringFromRect(rect));
#endif
	rect=NSIntersectionRect(vf, rect);	// reduce to visible frame if still too large
#if 0
	NSLog(@"constrained frameRect %@", NSStringFromRect(rect));
#endif
	return rect;
}

- (NSRect) contentRectForFrameRect:(NSRect) frameRect
{
	frameRect=[NSWindow contentRectForFrameRect:frameRect styleMask:_w.styleMask];
	// FIXME: subtract toolbar height
	// scale by userspace factor
	return frameRect;
}

- (NSRect) frameRectForContentRect:(NSRect) cRect
{
	cRect=[NSWindow frameRectForContentRect:cRect styleMask:_w.styleMask];
	// FIXME: add toolbar height
	// scale by userspace factor
	return cRect;
}

- (NSRect) frame								{ return _frame; }
- (NSSize) minSize								{ return _minSize; }
- (NSSize) maxSize								{ return _maxSize; }

- (void) setContentSize:(NSSize)aSize
{
	NSRect r={ _frame.origin, aSize };
	// limit to be larger than minSize and smaller than maxSize!
	[self setFrame:[self frameRectForContentRect:r] display:_w.visible];
}

- (void) setFrameTopLeftPoint:(NSPoint)aPoint
{
	[self setFrameOrigin:NSMakePoint(aPoint.x, aPoint.y-_frame.size.height)];
}

- (void) setFrameOrigin:(NSPoint)aPoint
{
	if(!NSEqualPoints(aPoint, _frame.origin))
		{
		NSRect r={aPoint, _frame.size};
		[_context _setOrigin:r.origin];
		_frame.origin=aPoint;	// remember; no need to update theme frame
		}
}

- (void) setFrame:(NSRect)r display:(BOOL)flag
{
	if(!NSEqualSizes(r.size, _frame.size))
		{ // resize (and move)
		[_context _setOriginAndSize:r];	// set origin since we must "move" in X11 coordinates even if we resize only
		[self _setFrame:r];	// update content view size etc.
		// FIXME: must also update window title shape!
		}
	else if(!NSEqualPoints(r.origin, _frame.origin))
		{ // move only
		[_context _setOrigin:r.origin];
		[self _setFrame:r];	// update content view etc.
		}
	else if(flag)
		{ // no change, but display requested
		[self display];
		return;
		}
	else
		return;	// NOOP request
	if(flag)
		[self display];	// if requested in addition
}

- (void) _setFrame:(NSRect) rect
{ // this is also a callback from window manager
#if 0
	NSLog(@"_setFrame:%@", NSStringFromRect(rect));
#endif
	if(NSEqualRects(rect, _frame))
		return;	// no change
	if(!NSEqualSizes(rect.size, _frame.size))
		{ // needs to resize content view
		_frame=rect;
		[(NSThemeFrame *) _themeFrame setFrameSize:rect.size];	// adjust theme frame subviews and content View
		}
	else
		{
		_frame.origin=rect.origin;	// just moved
#if 1
		NSLog(@"window has no need to re-layout: %@", self);
#endif
		}
}

- (void) setFrame:(NSRect) rect display:(BOOL) flag animate:(BOOL) animate
{
	if(NSEqualRects(rect, _frame))
		return;	// no change
#if 0	// if window animation works
	if(animate)
		{ // smooth resize
		NSArray *animations=[NSArray arrayWithObject:
			[NSDictionary dictionaryWithObjectsAndKeys:
				[NSValue valueWithRect:_frame], NSViewAnimationStartFrameKey,	// current frame
				[NSValue valueWithRect:rect], NSViewAnimationEndFrameKey,		// new frame
				self, NSViewAnimationTargetKey,
				nil]
			];
		NSViewAnimation *a=[[[NSViewAnimation alloc] initWithViewAnimations:animations] autorelease];
		[a startAnimation];	// start
		return;
		}
#endif
	[self setFrame:rect display:flag];	// just setFrame...
}

- (void) setMinSize:(NSSize)aSize				{ _minSize = aSize; }
- (void) setMaxSize:(NSSize)aSize				{ _maxSize = aSize; }
- (void) setResizeIncrements:(NSSize)aSize		{ _resizeIncrements = aSize; }

- (NSAffineTransform *) _base2screen;
{ // return matrix to transform base coordinates to screen coordinates
	NSAffineTransform *atm=[NSAffineTransform transform];
	// FIXME: handle userSpaceScaling here?
	[atm translateXBy:_frame.origin.x yBy:_frame.origin.y];
#if 0
	NSLog(@"_base2screen=%@", atm);
#endif
	return atm;
}

- (NSPoint) convertBaseToScreen:(NSPoint)base
{
	return [[self _base2screen] transformPoint:base];
}

- (NSPoint) convertScreenToBase:(NSPoint)screen
{
	NSAffineTransform *atm=[[self _base2screen] copy];
	[atm invert];
	[atm autorelease];
	return [atm transformPoint:screen];
}

- (void) display
{
	if(!_w.visible)
		[self orderFront:nil];	// will call -update when window becomes mapped
	else
		{
		NSAutoreleasePool *arp=[NSAutoreleasePool new];	// collect all drawing temporaries here
		_w.needsDisplay = NO;	// reset first - display may result in callbacks that will set this flag again
		[self disableFlushWindow];						// tmp disable of display
		[_themeFrame display];							// Draw the window view hierarchy (if changed)
		[self enableFlushWindow];						// Reenable displaying
		[self flushWindowIfNeeded];
		[arp release];
		}
}													

- (void) displayIfNeeded
{
	if(!_w.visible)
		[self orderFront:nil];	// will call -update when window becomes mapped
	else
		{
		NSAutoreleasePool *arp=[NSAutoreleasePool new];	// collect all drawing temporaries here
		_w.needsDisplay = NO;	// reset first - display may result in callbacks that will set this flag again
		[self disableFlushWindow];						// tmp disable of display
		[_themeFrame displayIfNeeded];					// Draw the window view hierarchy (if changed)
		[self enableFlushWindow];						// Reenable displaying
		[self flushWindowIfNeeded];
		[arp release];
		}
}

- (void) update
{
#if 0
	NSLog(@"%@ update %d %d", self, _w.autodisplay, _w.needsDisplay);
#endif
	if(_w.autodisplay && _w.needsDisplay && _w.visible)
		{ // if autodisplay is enabled and window needs display
#if 0
		NSLog(@"%@ update %@", self, [_themeFrame _descriptionWithSubviews]);
#endif
		[self displayIfNeeded];	// display subviews if needed
    	}
	[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidUpdateNotification object:self];
}

- (void) flushWindowIfNeeded
{
	if (!_w.disableFlushWindow && _w.needsFlush) 
		[self flushWindow];
}

- (void) disableFlushWindow					{ _w.disableFlushWindow = YES; }
- (void) flushWindow						{ [_context flushGraphics]; }						
- (void) enableFlushWindow					{ _w.disableFlushWindow = NO; }
- (BOOL) isAutodisplay						{ return _w.autodisplay; }
- (BOOL) isFlushWindowDisabled				{ return _w.disableFlushWindow; }
- (void) setAutodisplay:(BOOL)flag			{ _w.autodisplay = flag; }
- (void) setViewsNeedDisplay:(BOOL)flag		{ _w.needsDisplay = flag; }
- (BOOL) viewsNeedDisplay					{ return _w.needsDisplay; }
- (void) useOptimizedDrawing:(BOOL)flag		{ _w.optimizeDrawing = flag; }
- (BOOL) canStoreColor						{ return (_w.depthLimit > 1); }
- (NSWindowDepth) depthLimit				{ return _w.depthLimit; }
- (BOOL) hasDynamicDepthLimit				{ return _w.dynamicDepthLimit; }
- (NSScreen *) screen						{ return _screen; }
- (NSScreen *) deepestScreen				{ return _screen?_screen:[NSScreen deepestScreen]; }
- (void) setDepthLimit:(NSWindowDepth)limit	{ _w.depthLimit = limit; }
- (void) setDynamicDepthLimit:(BOOL)flag	{ _w.dynamicDepthLimit = flag; }
- (int) resizeFlags							{ return 0; }

- (void) setDocumentEdited:(BOOL)flag
{
	_w.isEdited=flag;	// keep a local copy if we have no close button for any reason
	[(_NSThemeCloseWidget*) [(NSThemeFrame *) _themeFrame standardWindowButton:NSWindowCloseButton] setDocumentEdited:flag];
	[NSApp updateWindowsItem:self];	// modify menu state
	// we could/should forward to the backend...
}

- (void) setReleasedWhenClosed:(BOOL)flag
{
#if 0
	NSLog(@"%@: setReleasedWhenClosed:%d", _windowTitle, flag);
#endif
	_w.releasedWhenClosed = flag; 
}

- (BOOL) acceptsMouseMovedEvents			{ return _w.acceptsMouseMoved; }
- (BOOL) isExcludedFromWindowsMenu			{ return _w.menuExclude; }
- (void) setAcceptsMouseMovedEvents:(BOOL)f	{ _w.acceptsMouseMoved = f;}

- (void) setExcludedFromWindowsMenu:(BOOL)f
{
	if(_w.menuExclude == f)
		return;	// no change
	if((_w.menuExclude = f))
		[NSApp removeWindowsItem:self];	// now excluded
	else if(_w.visible)
		[NSApp addWindowsItem:self title:_windowTitle filename:NO];	// add
}

- (NSEvent *) currentEvent					{ return [NSApp currentEvent]; }
- (id) delegate								{ return _delegate; }

- (void) setDelegate:(id)anObject
{
	NSNotificationCenter *n;

	if(_delegate == anObject)
		return;

#define IGNORE_(notif_name) [n removeObserver:_delegate \
								name:NSWindow##notif_name##Notification \
								object:self]

	n = [NSNotificationCenter defaultCenter];
	if (_delegate)
		{
		IGNORE_(DidBecomeKey);
		IGNORE_(DidBecomeMain);
		IGNORE_(DidChangeScreen);
		IGNORE_(DidDeminiaturize);
		IGNORE_(DidExpose);
		IGNORE_(DidMiniaturize);
		IGNORE_(DidMove);
		IGNORE_(DidResignKey);
		IGNORE_(DidResignMain);
		IGNORE_(DidResize);
		IGNORE_(DidUpdate);
		IGNORE_(WillClose);
		IGNORE_(WillMiniaturize);
		}

	ASSIGN(_delegate, anObject);
	if(!anObject)
		return;

#define OBSERVE_(notif_name) \
	if ([_delegate respondsToSelector:@selector(window##notif_name:)]) \
		[n addObserver:_delegate \
		   selector:@selector(window##notif_name:) \
		   name:NSWindow##notif_name##Notification \
		   object:self]

	OBSERVE_(DidBecomeKey);
	OBSERVE_(DidBecomeMain);
	OBSERVE_(DidChangeScreen);
	OBSERVE_(DidDeminiaturize);
	OBSERVE_(DidExpose);
	OBSERVE_(DidMiniaturize);
	OBSERVE_(DidMove);
	OBSERVE_(DidResignKey);
	OBSERVE_(DidResignMain);
	OBSERVE_(DidResize);
	OBSERVE_(DidUpdate);
	OBSERVE_(WillClose);
	OBSERVE_(WillMiniaturize);
	OBSERVE_(WillMove);
}

- (void) discardCursorRects
{
	[_cursorRects removeAllObjects];
}

- (void) invalidateCursorRectsForView:(NSView *)aView
{
	if(aView)
		{
		if(_w.isKey)
			{
			[aView discardCursorRects];
			[aView resetCursorRects];
			}
		else
			_w.cursorRectsValid = NO;
		}
}

- (void) resetCursorRects
{
	[self discardCursorRects];
	[_themeFrame resetCursorRects];
	_w.cursorRectsValid = YES;
}

- (void) disableCursorRects					{ _w.cursorRectsEnabled = NO; }
- (void) enableCursorRects					{ _w.cursorRectsEnabled = YES; }
- (BOOL) areCursorRectsEnabled				{ return _w.cursorRectsEnabled; }
- (BOOL) isDocumentEdited					{ return _w.isEdited; }
- (BOOL) isReleasedWhenClosed				{ return _w.releasedWhenClosed; }
- (BOOL) isZoomed							{ return _w.isZoomed; }

- (void) miniaturize:(id)sender
{
	if(_w.miniaturized)
		return;
	[[NSNotificationCenter defaultCenter] postNotificationName: NOTE(WillMiniaturize) object:self];
	_w.miniaturized = YES; 
	[_context _miniaturize];
	[[NSNotificationCenter defaultCenter] postNotificationName: NOTE(DidMiniaturize) object:self];
}

- (void) deminiaturize:(id)sender
{
	if(!_w.miniaturized)
		return;
	_w.miniaturized = NO;
	[_context _deminiaturize];
	[[NSNotificationCenter defaultCenter] postNotificationName: NOTE(DidDeminiaturize) object:self];
}

- (void) zoom:(id)sender
{
	NSLog(@"Zoom");
	if(_w.isZoomed)
		{
		}
	else
		{
		}
}

- (void) close
{
#if 1
	NSLog(@"close %@", self);
	NSLog(@"retain count %d", [self retainCount]);
	if(_w.releasedWhenClosed)
		NSLog(@"close %@: releasedWhenClosed", _windowTitle);
#endif
	// Notify window's delegate
	[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillCloseNotification object:self];
	[self orderOut:self];	// might dealloc graphics context
	[NSApp removeWindowsItem:self];
	if(_w.releasedWhenClosed)	// do so. Default is YES for windows and NO for panels
		{
#if 0
		NSLog(@"close %@: releasedWhenClosed", _windowTitle);
		NSLog(@"our retain count %d", [self retainCount]);
#endif
		[self autorelease]; 
		}
}

- (void) _close:(id)sender									
{
#if 1
	NSLog(@"_close");
#endif
	if(!(_w.styleMask & NSClosableWindowMask))
		{											// self must have a close
		NSBeep();									// button in order to be
		return;										// closed
		}
	if([_delegate respondsToSelector:@selector(windowShouldClose:)])
		{											// if delegate responds to
    	if(![_delegate windowShouldClose:self])		// windowShouldClose query
			{										// it to see if it's ok to
			NSBeep();								// close the window
			return;									
			}
		}
	else
		{
		if([self respondsToSelector:@selector(windowShouldClose:)])
			{										// else if self (i.e. a subclass of NSWindow) responds to
			if(![self windowShouldClose:self])		// windowShouldClose query
				{									// self to see if it's ok
				NSBeep();							// to close self
				return;								
				}
			}
		} 
	[self close];									// it's ok to close self								
}

- (void) performClose:(id)sender									
{
	// FIXME: should highlight miniaturize button temporarily
	[self _close:sender];
}

- (void) performMiniaturize:(id)sender									
{
	// FIXME: should highlight miniaturize button temporarily
	[self miniaturize:sender];
}

- (void) performZoom:(id)sender									
{
	// FIXME: should highlight zoom button temporarily
	[self zoom:sender];
}

- (void) discardEventsMatchingMask:(unsigned int)mask
					   beforeEvent:(NSEvent *)lastEvent
{
	[NSApp discardEventsMatchingMask:mask beforeEvent:lastEvent];
}

- (void) doCommandBySelector:(SEL) sel;
{
	if([self respondsToSelector:sel])
		[self performSelector:sel withObject:nil];
	else if(_nextResponder)
		[_nextResponder doCommandBySelector:sel];	// pass down
	else if(_delegate && [self respondsToSelector:_cmd])
		[_delegate doCommandBySelector:sel];		// pass down
	else
		[self noResponderFor:sel];	// Beep
}

#if 0	// FIX ME should provide default handling per NSResponder docs
- (void) keyDown:(NSEvent *)event					
{											
	switch([event keyCode])
		{
		case '\t':			// Tab
			[self selectNextKeyView:self];
			break;
		default:								// FIX ME should provide default
			NSBeep();							// handling per NSResponder docs
		}
}													
#endif

- (NSResponder *) firstResponder			{ return _firstResponder; }
- (BOOL) acceptsFirstResponder				{ return YES; }

- (BOOL) makeFirstResponder:(NSResponder *)aResponder
{
#if 0
	NSLog(@"makeFirstResponder: %@", aResponder);
#endif
	if (_firstResponder == aResponder)				// if responder is already
		return YES;									// first responder return Y

	if(!aResponder)
		aResponder=self;
	if (![aResponder isKindOfClass: __responderClass])
		return NO;									// not a responder return N

	if (![aResponder acceptsFirstResponder])		
		return NO;									// does not accept status

	if (_firstResponder)
		{ // resign first responder status
		NSResponder *first = _firstResponder;

		_firstResponder = nil;
		if (![first resignFirstResponder])			// the first responder must
			{										// agree to resign
			_firstResponder = first;	// did not!
			return NO;
			}
		}
	
	if (__cursorHidden)
		[NSCursor unhide];
	__cursorHidden = NO;

	if (_firstResponder == aResponder)				// in case resignFirstResponder already set
		return YES;									// a new first responder

	if([(_firstResponder = aResponder) becomeFirstResponder])
		return YES;									// Notify responder of it's	
													// new status, make window
	_firstResponder = self;							// first if it refuses

	return NO;
}

- (NSEvent *) nextEventMatchingMask:(unsigned int)mask
{
	return [NSApp nextEventMatchingMask:mask 
							  untilDate:[NSDate distantFuture]
								 inMode:NSEventTrackingRunLoopMode 
								dequeue:YES];
}

- (NSEvent *) nextEventMatchingMask:(unsigned int)mask
						  untilDate:(NSDate *)expiration
						  inMode:(NSString *)mode
						  dequeue:(BOOL)deqFlag
{
	return [NSApp nextEventMatchingMask:mask 
							  untilDate:expiration
								 inMode:mode 
								dequeue:deqFlag];
}

- (void) postEvent:(NSEvent *)event atStart:(BOOL)flag
{
	[NSApp postEvent:event atStart:flag];
}

- (BOOL) shouldBeTreatedAsInkEvent:(NSEvent *) theEvent;
{ // permit ink-anywhere
	_lastLeftHit=[_themeFrame hitTest:[theEvent locationInWindow]];	// cache
	return [_lastLeftHit shouldBeTreatedAsInkEvent:theEvent];	// pass to view under pen (subview of theme frame)
}

- (void) sendEvent:(NSEvent *)event
{
	if (!_w.cursorRectsValid)
		[self resetCursorRects];

	switch ([event type])
    	{
		case NSAppKitDefined:
			{
#if 1
				NSLog(@"Event %@", event);
#endif
				switch([event subtype])
					{
					case NSWindowExposedEventType:
						{
							NSRect rect={[event locationInWindow], {[event data1], [event data2] }};
							NSDictionary *uinfo=[NSDictionary dictionaryWithObject:[NSValue valueWithRect:rect] forKey:@"NSExposedRect"];
#if 1
							NSLog(@"NSWindowExposedEventType %@", NSStringFromRect(rect));
#endif
							[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidExposeNotification
																				object:self
																			  userInfo:uinfo];
							rect=[_themeFrame convertRect:rect fromView:nil];	// from window to theme frame (which uses flipped coordinates!)
							[_themeFrame setNeedsDisplayInRect:rect];	// we know that we own the top-level view...
							if(!_w.needsDisplay)
								NSLog(@"window did expose but does not need to display? %@", self);
							break;
						}
					// should this event ever arrive at a NSWindow???
					case NSApplicationActivatedEventType:
						{
						[NSApp activateIgnoringOtherApps:YES];	// user has clicked: bring our application windows and menus to front
						[_firstResponder becomeFirstResponder];
						if (!_w.isKey)
							[self makeKeyAndOrderFront:self];
						break;
						}
					}
				break;
			}

		case NSLeftMouseDown:								// Left mouse down
			if(!_w.visible)
				break;			// we check if we are still visible (user may have clicked while we were ordering out)
			if (__cursorHidden)
				{ 
				[NSCursor unhide]; 
				__cursorHidden = NO; 
				}
//			_lastLeftHit = [_themeFrame hitTest:[event locationInWindow]];	// this assumes that we have already called shouldBeTreatedAsInkEvent!
			NSDebugLog([_lastLeftHit description]);
#if 0
			NSLog(@"NSLeftMouseDown: %@", event);
			NSLog(@"  locationInWindow=%@", NSStringFromPoint([event locationInWindow]));
			NSLog(@"  _themeFrame=%@", _themeFrame);
			NSLog(@"  _lastLeftHit=%@", _lastLeftHit);
#endif
			// FIXME: we should check for window movement and resize here so that we can honor [_lastleftHit mouseDownCanMoveWindow]

			if((NSResponder *) _lastLeftHit != _firstResponder && [(NSResponder *) _lastLeftHit acceptsFirstResponder])
				[self makeFirstResponder:_lastLeftHit];		// make hit view first responder if not already and if it accepts
			if(_w.isKey)
				[_lastLeftHit mouseDown:event];
			else
				{ // first click makes it the key window unless the view asks for a delay
				if(![_lastLeftHit shouldDelayWindowOrderingForEvent:event])
					{
#if 1
					NSLog(@"first click results in makeKeyAndOrderFront");
#endif
					[self makeKeyAndOrderFront:self];	// bring clicked window to front
					}
				else
					[NSApp _setPendingWindow:self];		// register for delayed ordering
				if([_lastLeftHit acceptsFirstMouse:event])
					[_lastLeftHit mouseDown:event];
				}
			break;

		case NSLeftMouseUp:									// Left mouse up
#if 0
			NSLog(@"NSLeftMouseUp %@", _lastLeftHit);
#endif
			if (__cursorHidden)
				{ 
				[NSCursor unhide]; 
				__cursorHidden = NO;
				}
			[_lastLeftHit mouseUp:event];
			break;

		case NSRightMouseDown:								// Right mouse down
			if (__cursorHidden)
				{ [NSCursor unhide]; __cursorHidden = NO; }
			_lastRightHit = [_themeFrame hitTest:[event locationInWindow]];
			[_lastRightHit rightMouseDown:event];
			break;

		case NSRightMouseUp:								// Right mouse up
			if (__cursorHidden)
				{ [NSCursor unhide]; __cursorHidden = NO; }
			[_lastRightHit rightMouseUp:event];
			break;

		case NSMouseMoved:									// Mouse moved
			if (__cursorHidden)
				{ [NSCursor unhide]; __cursorHidden = NO; }
			if(_w.acceptsMouseMoved)
				{
				NSView *v = [_themeFrame hitTest:[event locationInWindow]];
				[v mouseMoved:event];				// hit view passes event up
				}									// responder chain to self
												// if we accept mouse moved
			if(_w.cursorRectsEnabled)
				[self mouseMoved:event];	// handle cursor
			break;

		case NSLeftMouseDragged:									// Mouse moved
#if 0
			NSLog(@"NSLeftMouseDragged %@", _lastLeftHit);
#endif
			[_lastLeftHit mouseDragged:event];
			break;
			
		case NSRightMouseDragged:									// Mouse moved
			[_lastRightHit mouseDragged:event];
			break;
			
		case NSKeyDown:										// Key down
			{
			__lastKeyDown = _firstResponder;	// save the first responder so that the key up goes to it and not a possible new first responder
			if(!__cursorHidden)
				{
				if([_firstResponder respondsToSelector:@selector(isEditable)] &&
				   [(NSText *) _firstResponder isEditable] &&
				   (__cursorHidden = [NSCursor isHiddenUntilMouseMoves]))
					[NSCursor hide];
				}
#if 1
			NSLog(@"first Responder %@ keyDown %@", _firstResponder, event);
#endif
			[_firstResponder keyDown:event];
			break;
			}

		case NSKeyUp:
			if (__lastKeyDown)
				[__lastKeyDown keyUp:event];		// send Key Up to object that got the key down
			__lastKeyDown = nil;
			break;

		case NSScrollWheel:
		    [[_themeFrame hitTest:[event locationInWindow]] scrollWheel:event];
			break;

		case NSCursorUpdate:
			if([event trackingNumber])						// a mouse entered
				[(id)[event userData] push];				// push the cursor
			else
				[NSCursor pop];								// a mouse exited
															// pop the cursor
		default:
			break;
		}
}

- (BOOL) performKeyEquivalent:(NSEvent*)event
{
#if 0
	BOOL r=[_themeFrame performKeyEquivalent:event];
	NSLog(@"%@ performKeyEquivalent -> %@", self, r?@"YES":@"NO");
	return r;
#else
	return [_themeFrame performKeyEquivalent:event];
#endif
}

- (BOOL) tryToPerform:(SEL)anAction with:anObject
{
	return [super tryToPerform:anAction with:anObject];
}

- (BOOL) worksWhenModal
{
	return NO;
}

- (void) dragImage:(NSImage *)anImage						// Drag and Drop
				at:(NSPoint)baseLocation
				offset:(NSSize)initialOffset
				event:(NSEvent *)event
				pasteboard:(NSPasteboard *)pboard
				source:sourceObject
				slideBack:(BOOL)slideFlag		{ BACKEND }

- (void) registerForDraggedTypes:(NSArray *)newTypes
{
	[_themeFrame registerForDraggedTypes:newTypes];
}

- (void) unregisterDraggedTypes		
{ 
	[_themeFrame unregisterDraggedTypes];
}

- (void) concludeDragOperation:(id <NSDraggingInfo>)sender
{
	if(_delegate)
		if ([_delegate respondsToSelector:@selector(concludeDragOperation:)])
			[_delegate concludeDragOperation:sender];
}

- (unsigned int) draggingEntered:(id <NSDraggingInfo>)sender
{
	if(_delegate && [_delegate respondsToSelector:@selector(draggingEntered:)])
		return [_delegate draggingEntered:sender];

	return NSDragOperationNone;
}

- (void) draggingExited:(id <NSDraggingInfo>)sender
{
	if (_delegate && [_delegate respondsToSelector:@selector(draggingExited:)])
		[_delegate draggingExited:sender];
}

- (unsigned int) draggingUpdated:(id <NSDraggingInfo>)sender
{
	if(_delegate && [_delegate respondsToSelector:@selector(draggingUpdated:)])
		return [_delegate draggingUpdated:sender];

	return NSDragOperationNone;
}

- (BOOL) performDragOperation:(id <NSDraggingInfo>)sender
{
	if(_delegate)
		if ([_delegate respondsToSelector:@selector(performDragOperation:)])
			return [_delegate performDragOperation:sender];

	return NO;
}

- (BOOL) prepareForDragOperation:(id <NSDraggingInfo>)sender
{
	if(_delegate)
		if ([_delegate respondsToSelector:@selector(prepareForDragOperation:)])
			return [_delegate prepareForDragOperation:sender];

	return NO;
}

- (id) validRequestorForSendType:(NSString *)sendType		// Services menu
					  returnType:(NSString *)returnType
{
	id result = nil;

	if (_delegate && [_delegate respondsToSelector: _cmd])
		result = [_delegate validRequestorForSendType: sendType
							returnType: returnType];

	if (result == nil)
		result = [NSApp validRequestorForSendType: sendType 
						returnType: returnType];
	return result;
}

+ (void) removeFrameUsingName:(NSString *)name			// Save / restore frame	
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@",name];

	[defaults removeObjectForKey:key];
	[defaults synchronize];
	[__frameNames removeObjectForKey:name];
}

- (BOOL) setFrameAutosaveName:(NSString *)name
{
	if(!__frameNames)
		__frameNames = [NSMutableDictionary new];

	if([__frameNames objectForKey:name])
		return NO;

	ASSIGN(_frameSaveName, name);
	[__frameNames setObject:self forKey:name];

	return YES;
}

- (NSString *) frameAutosaveName			{ return _frameSaveName; }

- (void) saveFrameUsingName:(NSString *)name
{
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@",name];
		
	NSDebugLog(@"saveFrameUsingName %@\n",[NSValue valueWithRect:frame]);

	[defaults setObject:[NSValue valueWithRect:_frame] forKey:key];
	[defaults synchronize];
}

- (BOOL) setFrameUsingName:(NSString *)name	
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@",name];
	NSString *value = [defaults stringForKey:key];

	if(!value)
		return NO;

	NSDebugLog(@"setFrameUsingName %@\n", value);
	[self setFrameFromString: value];

	return YES;
}

- (void) setFrameFromString:(NSString *)string
{
	NSDictionary *d = [string propertyList];
	NSRect r;
#if 0
	NSLog(@"NSWindow setFrameFromString %@\n", string);
#endif
	r.origin.x = [[d objectForKey:@"x"] floatValue];
	r.origin.y = [[d objectForKey:@"y"] floatValue];
	r.size.width = [[d objectForKey:@"width"] floatValue];
	r.size.height = [[d objectForKey:@"height"] floatValue];
	r.size.width = MIN(MAX(r.size.width, _minSize.width), _maxSize.width);
	r.size.height = MIN(MAX(r.size.height, _minSize.height), _maxSize.height);

	if(_delegate)
		{
		if ([_delegate respondsToSelector:@selector(windowWillResize:toSize:)])
			r.size = [_delegate windowWillResize:self toSize:r.size];
		}
	[self setFrame:r display:NO];
}

- (NSString *) stringWithSavedFrame				
{ 
	return [[NSValue valueWithRect:_frame] description]; 
}

- (void) print:(id) sender
{
	NSPrintOperation *po=[NSPrintOperation printOperationWithView:[(NSThemeFrame *) _themeFrame contentView]];
	[po runOperationModalForWindow:self delegate:nil didRunSelector:_cmd contextInfo:NULL];
}

- (NSString *) description;
{
#if 0
	NSLog(@"NSWindow description");
	NSLog(@" class %@", NSStringFromClass(isa));
	NSLog(@" win num %d", [_context _windowNumber]);
	NSLog(@" title %@", [self title]);
	NSLog(@" frame %@", NSStringFromRect(frame));
#endif
	return [NSString stringWithFormat:@"%@ [%lu]: title=%@ frame=%@",
		NSStringFromClass(isa),
		[_context _windowNumber],
		[self title],
		NSStringFromRect(_frame)];
}

- (NSView *) initialFirstResponder			{ return _initialFirstResponder; }

- (void) setInitialFirstResponder:(NSView *)aView
{
	_initialFirstResponder = aView;
}

- (void) selectNextKeyView:(id)sender
{
id next;

	if(_firstResponder && _firstResponder != self)
		next = [(NSView *)_firstResponder nextValidKeyView];
	else
		if((next = _initialFirstResponder) && ![next acceptsFirstResponder])
			next = [(NSView *)_initialFirstResponder nextValidKeyView];

	if(next && [self makeFirstResponder:next])
		{
		if([next respondsToSelector:@selector(selectText:)])
			[(NSTextField *)next selectText:self];
		}
	else
		NSBeep();
}

- (void) selectPreviousKeyView:(id)sender
{
id prev;

	if(_firstResponder && _firstResponder != self)
		prev = [(NSView *)_firstResponder previousValidKeyView];
	else
		if((prev = _initialFirstResponder) && ![prev acceptsFirstResponder])
			prev = [(NSView *)_initialFirstResponder previousValidKeyView];

	if(prev && [self makeFirstResponder:prev])
		{
		if([prev respondsToSelector:@selector(selectText:)])
			[(NSTextField *)prev selectText:self];
		}
	else
		NSBeep();
}

- (void) selectKeyViewFollowingView:(NSView *)aView
{
	if((aView = [aView nextValidKeyView]) && [self makeFirstResponder:aView] && [aView respondsToSelector:@selector(selectText:)])
		[(NSTextField *)aView selectText:self];
}

- (void) selectKeyViewPrecedingView:(NSView *)aView
{
	if((aView = [aView previousValidKeyView]) && [self makeFirstResponder:aView] && [aView respondsToSelector:@selector(selectText:)])
		[(NSTextField *)aView selectText:self];
}

- (void) encodeWithCoder:(NSCoder *)aCoder				// NSCoding protocol
{
	int _windowNum=[self windowNumber];
	[super encodeWithCoder:aCoder];
	
	NSDebugLog(@"NSWindow: start encoding\n");
	[aCoder encodeRect:_frame];
	[aCoder encodeObject:_themeFrame];
	[aCoder encodeObject:_initialFirstResponder];
//  [aCoder encodeObjectReference: _delegate withName:NULL];
	[aCoder encodeValueOfObjCType:"i" at:&_windowNum];
//	[aCoder encodeObject:_backgroundColor];
	[aCoder encodeObject:_representedFilename];
	[aCoder encodeObject:_miniWindowTitle];
	[aCoder encodeObject:_windowTitle];
	[aCoder encodeSize:_minSize];
	[aCoder encodeSize:_maxSize];
	[aCoder encodeObject:_miniWindowImage];
	[aCoder encodeValueOfObjCType:@encode(int) at: &_level];
	[aCoder encodeValueOfObjCType:@encode(unsigned int) at: &_w];
}

- (id) initWithCoder:(NSCoder *)aDecoder
{
	// FIXME: we can only decode a NSWindowTemplate from NIBs
	// and doc says that this call should create an error message!
	int _windowNum;
	self=[super initWithCoder:aDecoder];
	if([aDecoder allowsKeyedCoding])
		return NIMP;
	
	NSDebugLog(@"NSWindow: start decoding\n");
	_frame = [aDecoder decodeRect];
	_themeFrame = [aDecoder decodeObject];
	_initialFirstResponder = [aDecoder decodeObject];
//  [aDecoder decodeObjectAt: &_delegate withName:NULL];
	[aDecoder decodeValueOfObjCType:"i" at:&_windowNum];
	[self setBackgroundColor:[aDecoder decodeObject]];
	_representedFilename = [aDecoder decodeObject];
	_miniWindowTitle = [aDecoder decodeObject];
	_windowTitle = [aDecoder decodeObject];
	_minSize = [aDecoder decodeSize];
	_maxSize = [aDecoder decodeSize];
	_miniWindowImage = [aDecoder decodeObject];
	[aDecoder decodeValueOfObjCType:@encode(int) at: &_level];
	[aDecoder decodeValueOfObjCType:@encode(unsigned int) at: &_w];

	return self;
}

- (void) setWindowController:(NSWindowController *)windowController; { ASSIGN(_windowController, windowController); }
- (id) windowController; { return _windowController; }

+ (NSButton *) standardWindowButton:(NSWindowButton) type forStyleMask:(unsigned int) aStyle;
{
	NSButton *b=nil;
	static NSSize smallImage={ 15.0, 15.0 };
	float button=[self _titleBarHeightForStyleMask:aStyle];
	// set style dependent windget cell, i.e. brushed metal
	switch(type)
		{
		case NSWindowCloseButton:
			b=[[_NSThemeCloseWidget alloc] initWithFrame:NSMakeRect(4.0, 0.0, button, button) forStyleMask:aStyle];
			[b setAction:@selector(_close:)];
			[b setEnabled:(aStyle&NSClosableWindowMask) != 0];
			[b setImage:[NSImage imageNamed:@"NSWindowCloseButton"]];
			[b setTitle:@"x"];
			[b setAutoresizingMask:NSViewMaxXMargin|NSViewMinYMargin];
			break;
		case NSWindowMiniaturizeButton:
			b=[[_NSThemeWidget alloc] initWithFrame:NSMakeRect(3.0+button, 0.0, button, button) forStyleMask:aStyle];
			[b setAction:@selector(miniaturize:)];
			[b setEnabled:(aStyle&NSMiniaturizableWindowMask) != 0];
			[b setImage:[NSImage imageNamed:@"NSWindowMiniaturizeButton"]];
			[b setTitle:@"-"];
			[b setAutoresizingMask:NSViewMaxXMargin|NSViewMinYMargin];
			break;
		case NSWindowZoomButton:
			b=[[_NSThemeWidget alloc] initWithFrame:NSMakeRect(2.0+2.0*button, 0.0, button, button) forStyleMask:aStyle];
			[b setAction:@selector(zoom:)];
			[b setEnabled:(aStyle&NSResizableWindowMask) != 0];
			[b setImage:[NSImage imageNamed:@"NSWindowZoomButton"]];
			[b setTitle:@"+"];
			[b setAutoresizingMask:NSViewMaxXMargin|NSViewMinYMargin];
			break;
		case NSWindowToolbarButton:
			b=[[_NSThemeWidget alloc] initWithFrame:NSMakeRect(100.0, 0.0, button, button) forStyleMask:aStyle];	// we must adapt the origin when using this button!
			[b setAction:@selector(toggleToolbarShown:)];
			[b setEnabled:YES];
			[b setImage:[NSImage imageNamed:@"NSWindowToolbarButton"]];
			[b setTitle:@""];
			[b setAutoresizingMask:NSViewMinXMargin|NSViewMinYMargin];
			break;
		case NSWindowDocumentIconButton:
			// make centered button
			// set text font as required by size
			return nil;
		}
	[b setImagePosition:NSImageOverlaps];
	if(aStyle & NSUtilityWindowMask)
		{
		NSImage *i=[[b image] copy];
		// [b setFrameSize:small];
		[i setSize:smallImage];	// scale button image
		[i setScalesWhenResized:YES];
		[b setImage:i];	// store a copy
		[i release];
		[b setNeedsDisplay:YES];
		}
	return [b autorelease];
}

- (float) userSpaceScaleFactor;
{ // value defined in NSScreen profile
	return [_screen userSpaceScaleFactor];
}

- (void) setShowsResizeIndicator:(BOOL) flag;
{
	NIMP;
}

- (void) setShowsToolbarButton:(BOOL) flag;
{
	NIMP;
}

- (BOOL) showsResizeIndicator;
{
	NIMP; return NO;
}

- (BOOL) showsToolbarButton;
{
	NIMP; return NO;
}

- (NSButton *) standardWindowButton:(NSWindowButton) button;
{
	return [(NSThemeFrame *) _themeFrame standardWindowButton:button];
}

- (void) enableKeyEquivalentForDefaultButtonCell
{
	[_defaultButtonCell setKeyEquivalent:@"\r"];
}

- (void) disableKeyEquivalentForDefaultButtonCell
{
	[_defaultButtonCell setKeyEquivalent:@""];
}

- (void) setDefaultButtonCell:(NSButtonCell *) cell
{
	_defaultButtonCell=cell;
	[self enableKeyEquivalentForDefaultButtonCell];
}

- (NSButtonCell *) defaultButtonCell; { return _defaultButtonCell; }

- (NSPoint) mouseLocationOutsideOfEventStream
{ // ask backend for relative mouse position (might be outside of the Window!)
	return [_context _mouseLocationOutsideOfEventStream];
}

+ (void) menuChanged:(NSMenu *)aMenu; { return; } // does nothing for backward compatibility

- (void) invalidateShadow;
{
	[_shadow release];
	_shadow=nil;
}

- (BOOL) hasShadow { return _w.hasShadow; }

- (void) setHasShadow:(BOOL) flag
{
	if(flag != _w.hasShadow)
		{
		_w.hasShadow=flag;
		[self invalidateShadow];
		}
}

- (BOOL) ignoresMouseEvents { return _w.ignoresMouseEvents; }

- (void) setIgnoresMouseEvents:(BOOL) flag
{
	_w.ignoresMouseEvents=flag;
	// we must notify the backend (?)...
}

- (void) cacheImageInRect:(NSRect) rect;
{
	NIMP;
	[self discardCachedImage];
	_cachedRep=[[NSCachedImageRep alloc] initWithWindow:nil rect:rect];
//	[_cachedRep lockFocus];
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:(NSBitmapImageRep *)_cachedRep]];
	NSCopyBits(_gState, rect, NSZeroPoint);	// copy from our window to the cached window
//	[_cachedRep unlockFocus];
	[NSGraphicsContext restoreGraphicsState];
}

- (void) discardCachedImage;
{
	[_cachedRep release];
	_cachedRep=nil;
}

- (void) restoreCachedImage;
{
	[_cachedRep draw];
}

- (void) setAlphaValue:(float) alpha;
{
	if(alpha != 1.0)
		_w.isOpaque=NO;
	//
}

- (float) alphaValue;
{
	return 1.0;
}

- (void) setOpaque:(BOOL) flag; { _w.isOpaque=flag; }
- (BOOL) isOpaque; { return _w.isOpaque; }

- (void) setToolbar:(NSToolbar *) toolbar; { [(NSThemeFrame *) _themeFrame setToolbar:toolbar]; }
- (NSToolbar *) toolbar; { return [(NSThemeFrame *) _themeFrame toolbar]; }

@end /* NSWindow */
