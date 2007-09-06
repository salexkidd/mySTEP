/* 
   NSSearchField.m

   Text field control and cell classes

   Author:  Nikolaus Schaller <hns@computer.org>
   Date:    December 2004
   
   This file is part of the mySTEP Library and is provided
   under the terms of the GNU Library General Public License.
*/ 

// FIXME: make us react on textChanged/didEndEditing of the NSText and send the Cell's action

#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSException.h>

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSSearchField.h>
#import <AppKit/NSSearchFieldCell.h>
#import <AppKit/NSImage.h>

#import "NSAppKitPrivate.h"

@implementation NSSearchFieldCell

- (id) initTextCell:(NSString *)aString
{
	if((self=[super initTextCell:aString]))
		{
		[self resetCancelButtonCell];
		[self resetSearchButtonCell];
		maxRecents=254;
		}
	return self;
}

- (void) dealloc
{
	[_cancelButtonCell release];
	[_searchButtonCell release];
	[recentSearches release];
	[recentsAutosaveName release];
	[_menuTemplate release];
	[super dealloc];
}

- (id) copyWithZone:(NSZone *) zone;
{
	NSSearchFieldCell *c = [super copyWithZone:zone];
	c->_cancelButtonCell=[_cancelButtonCell copyWithZone:zone];
	c->_searchButtonCell=[_searchButtonCell copyWithZone:zone];
	c->_menuTemplate=[_menuTemplate retain];
	c->recentSearches=[recentSearches copyWithZone:zone];
	c->recentsAutosaveName=[recentsAutosaveName retain];
	c->maxRecents=maxRecents;
	c->sendsWholeSearchString=sendsWholeSearchString;
	return c;
}

- (BOOL) isOpaque
{
	return [super isOpaque] && [_cancelButtonCell isOpaque] && [_searchButtonCell isOpaque];	// only if all components are opaque
}

- (void) drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView*)controlView
{ // draw components
	[super drawInteriorWithFrame:[self searchTextRectForBounds:cellFrame] inView:controlView];
	[_searchButtonCell drawInteriorWithFrame:[self searchButtonRectForBounds:cellFrame] inView:controlView];
	[_cancelButtonCell drawInteriorWithFrame:[self cancelButtonRectForBounds:cellFrame] inView:controlView];
}

- (void) drawWithFrame:(NSRect)cellFrame inView:(NSView*)controlView
{
	NSGraphicsContext *ctxt=[NSGraphicsContext currentContext];
	NSBezierPath *p;
#if 0
	NSLog(@"%@ drawWithFrame:%@", self, NSStringFromRect(cellFrame));
#endif
	p=[NSBezierPath _bezierPathWithRoundedBezelInRect:cellFrame vertical:NO];	// box with halfcircular rounded ends
	[ctxt saveGraphicsState];
	[[NSColor whiteColor] set];
	[p fill];		// fill with background color
	[[NSColor blackColor] set];
	[p stroke];		// fill border
	[p addClip];	// clip to contour
	[ctxt restoreGraphicsState];
}

- (BOOL) sendsWholeSearchString; { return sendsWholeSearchString; }
- (void) setSendsWholeSearchString:(BOOL) flag; { sendsWholeSearchString=flag; }
- (int) maximumRecents; { return maxRecents; }
- (void) setMaximumRecents:(int) max;
{
	if(max > 254) max=254;
	maxRecents=max;
}

- (NSArray *) recentSearches; { return recentSearches; }
- (NSString *) recentsAutosaveName; { return recentsAutosaveName; }
- (void) setRecentSearches:(NSArray *) searches; { ASSIGN(recentSearches, searches); }
- (void) setRecentsAutosaveName:(NSString *) name; { ASSIGN(recentsAutosaveName, name); }

- (NSMenu *) searchMenuTemplate; { return _menuTemplate; }
- (void) setSearchMenuTemplate:(NSMenu *) menu; { ASSIGN(_menuTemplate, menu); }

- (void) _searchFieldCancel:(id) sender;
{
}

- (void) _searchFieldSearch:(id) sender;
{
}

- (NSButtonCell *) cancelButtonCell; { return _cancelButtonCell; }
- (void) setCancelButtonCell:(NSButtonCell *) cell; { ASSIGN(_cancelButtonCell, cell); }
- (NSButtonCell *) searchButtonCell; { return _searchButtonCell; }
- (void) setSearchButtonCell:(NSButtonCell *) cell; { ASSIGN(_searchButtonCell, cell); }

- (void) resetCancelButtonCell;
{
	NSButtonCell *c= [[NSButtonCell alloc] init];
	[c setButtonType:NSMomentaryChangeButton];	// configure the button
	[c setBezelStyle:NSRegularSquareBezelStyle];	// configure the button
	[c setBordered:NO];
	[c setBezeled:NO];
	[c setTransparent:YES];
	[c setEditable:NO];
	[c setImagePosition:NSImageOnly];
//	[c setAlignment:NSRightTextAlignment];
	[c setImage:[NSImage imageNamed:@"GSStop"]];
	[self setCancelButtonCell:c];
}

- (void) resetSearchButtonCell;
{
	NSButtonCell *c= [[NSButtonCell alloc] init];
	[c setButtonType:NSMomentaryChangeButton];	// configure the button
	[c setBezelStyle:NSRegularSquareBezelStyle];	// configure the button
	[c setBordered:NO];
	[c setBezeled:NO];
	[c setTransparent:YES];
	[c setEditable:NO];
	[c setImagePosition:NSImageOnly];
	[c setImage:[NSImage imageNamed:@"GSSearch"]];
	[self setSearchButtonCell:c];
}

#define ICON_WIDTH	16

- (NSRect) cancelButtonRectForBounds:(NSRect) rect;
{
	rect.origin.x+=rect.size.width-(_searchButtonCell?(ICON_WIDTH+4.0):4.0);
	rect.size.width=_cancelButtonCell?ICON_WIDTH:0.0;
	return rect;
}

- (NSRect) searchButtonRectForBounds:(NSRect) rect;
{
	rect.origin.x+=4.0;
	rect.size.width=_searchButtonCell?ICON_WIDTH:0.0;
	return rect;
}

- (NSRect) searchTextRectForBounds:(NSRect) rect;
{
	NSRect r1=[self searchButtonRectForBounds:rect];
	NSRect r2=[self cancelButtonRectForBounds:rect];
	r1.origin.x+=r1.size.width+2.0;			// to the right of the search button
	r1.size.width=r2.origin.x-r1.origin.x-2.0;
	return r1;
}

- (void) selectWithFrame:(NSRect)aRect					// similar to editWith-
				  inView:(NSView*)controlView	 		// Frame method but can
				  editor:(NSText*)textObject	 		// be called from more
				delegate:(id)anObject	 				// than just mouseDown
				   start:(int)selStart	 
				  length:(int)selLength
{ // constrain to visible text area
	[super selectWithFrame:[self searchTextRectForBounds:aRect]
					inView:controlView
					editor:textObject
				  delegate:anObject
					 start:selStart
					length:selLength];
}

// FIXME:
// make cancel button send delete: message to responder chain
// make search button send action to target (or responder chain)
// make search button menu working

- (void) _textDidChange:(NSText *) text
{ // make textChanged send action (unless disabled)
	NSLog(@"NSSearchField _textDidChange:%@", text);
	if(sendsWholeSearchString)
		return;	// ignore
	NSLog(@"current text: %@", [text string]);
	[self setStringValue:[text string]]; // copy the current NSTextEdit string so that it can be read from the NSSearchFieldCell!
	[self performClick:_controlView];
}

- (BOOL) trackMouse:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView untilMouseUp:(BOOL)untilMouseUp
{ // check if we should forward to subcell
	NSPoint loc=[event locationInWindow];
	loc = [controlView convertPoint:loc fromView:nil];
	NSLog(@"NSSearchFieldCell trackMouse:%@ inRect:%@", NSStringFromPoint(loc), NSStringFromRect(cellFrame));
	if(NSMouseInRect(loc, [self cancelButtonRectForBounds:cellFrame], NO))
		return [_cancelButtonCell trackMouse:event inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];
	if(NSMouseInRect(loc, [self searchButtonRectForBounds:cellFrame], NO))
		return [_searchButtonCell trackMouse:event inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];
	// might check for searchtextRectForBounds
 	return [super trackMouse:event inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];
}

- (void) encodeWithCoder:(NSCoder *) aCoder
{
	NIMP;
}

- (id) initWithCoder:(NSCoder *) aDecoder
{
	const unsigned char *sfFlags;
	unsigned int len;
	self=[super initWithCoder:aDecoder];
	if(![aDecoder allowsKeyedCoding])
		{ [self release]; return nil; }
	if([aDecoder containsValueForKey:@"NSSearchFieldFlags"])
		{
		sfFlags=[aDecoder decodeBytesForKey:@"NSSearchFieldFlags" returnedLength:&len];
#define FLAG (sfFlags[0] != 0)
		sendsWholeSearchString=FLAG;	// ????
		}
	_cancelButtonCell = [[aDecoder decodeObjectForKey:@"NSCancelButtonCell"] retain];
	_searchButtonCell = [[aDecoder decodeObjectForKey:@"NSSearchButtonCell"] retain];
	maxRecents = [aDecoder decodeIntForKey:@"NSMaximumRecents"];
	sendsWholeSearchString = [aDecoder decodeIntForKey:@"NSSendsWholeSearchString"];
	// NSSearchFieldFlags - NSData (?)
	[self resetCancelButtonCell];
	[self resetSearchButtonCell];
#if 0
	NSLog(@"%@ initWithCoder:%@", self, aDecoder);
#endif
	return self;
}

@end /* NSSearchFieldCell */

@implementation NSSearchField

+ (Class) cellClass
{ 
	return [NSSearchFieldCell class]; 
}

+ (void) setCellClass:(Class)class
{ 
	[NSException raise:NSInvalidArgumentException
				format:@"NSSearchField only uses NSSearchFieldCells"];
}

- (NSArray *) recentSearches; { return [[self cell] recentSearches]; }
- (NSString *) recentsAutosaveName; { return [[self cell] recentsAutosaveName]; }
- (void) setRecentSearches:(NSArray *) searches; { [[self cell] setRecentSearches:searches]; }
- (void) setRecentsAutosaveName:(NSString *) name; { [[self cell] setRecentsAutosaveName:name]; }

@end /* NSSearchField */
