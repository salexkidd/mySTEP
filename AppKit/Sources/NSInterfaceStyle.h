//
//  NSInterfaceStyle.h
//  mySTEP
//
//  Created by Dr. H. Nikolaus Schaller on Sat Jan 07 2006.
//  Copyright (c) 2005 DSITRI.
//
//  This file is part of the mySTEP Library and is provided
//  under the terms of the GNU Library General Public License.
//

#ifndef _mySTEP_H_NSInterfaceStyle
#define _mySTEP_H_NSInterfaceStyle

#import "AppKit/NSResponder.h"

typedef enum _NSInterfaceStyle
{
	NSNoInterfaceStyle=0,
	NSNextStepInterfaceStyle,
	NSWindows95InterfaceStyle,
	NSMacintoshInterfaceStyle,
	// mySTEP extensions
	NSPDAInterfaceStyle=256,
	NSSmartPhoneInterfaceStyle=257,
} NSInterfaceStyle;

#endif /* _mySTEP_H_NSInterfaceStyle */
