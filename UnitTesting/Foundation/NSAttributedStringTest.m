//
//  NSAttributedStringTest.m
//  UnitTests
//
//  Created by H. Nikolaus Schaller on 11.04.09.
//  Copyright 2009 Golden Delicious Computers GmbH&Co. KG. All rights reserved.
//

#import "NSAttributedStringTest.h"
#import <Cocoa/Cocoa.h>


@implementation NSAttributedStringTest

- (void) test1
{
	NSAttributedString *s=[[NSAttributedString alloc] initWithString:@"string"];
	STAssertEqualObjects(@"string", [s string], nil);
	STAssertTrue([s length] == 6, nil);
	STAssertNotNil([s attributesAtIndex:0 effectiveRange:NULL], nil);	// return empty NSDictionary and not nil
	STAssertTrue([[s attributesAtIndex:0 effectiveRange:NULL] count] == 0, nil);	
	[s release];
}

- (void) test2
{
	NSMutableAttributedString *s=[[NSMutableAttributedString alloc] initWithString:@"string"];
	STAssertEqualObjects(@"string", [s string], nil);
	STAssertTrue([s length] == 6, nil);
	STAssertNotNil([s attributesAtIndex:0 effectiveRange:NULL], nil);	// return empty NSDictionary and not nil
	STAssertTrue([[s attributesAtIndex:0 effectiveRange:NULL] count] == 0, nil);	
	[s setAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor redColor], NSForegroundColorAttributeName, nil] range:NSMakeRange(0, 3)];
	STAssertTrue([[s attributesAtIndex:0 effectiveRange:NULL] count] == 1, nil);
	STAssertTrue([[s attributesAtIndex:3 effectiveRange:NULL] count] == 0, nil);
	[s setAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor blueColor], NSForegroundColorAttributeName, nil] range:NSMakeRange(3, 3)];
	STAssertTrue([[s attributesAtIndex:0 effectiveRange:NULL] count] == 1, nil);
	STAssertTrue([[s attributesAtIndex:3 effectiveRange:NULL] count] == 1, nil);
	[s release];
}

- (void) searchData:(id) obj
{
	if([obj isKindOfClass:[NSData class]])
		NSLog(@"%@", obj);
	else if([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]])
			{
				NSEnumerator *e=[obj objectEnumerator];
				while((obj=[e nextObject]))
					[self searchData:obj];
			}
}

- (void) analyse:(NSData *) d
{
	NSPropertyListFormat format;
	NSString *error;
	id obj=[NSPropertyListSerialization propertyListFromData:d mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&error];
	[self searchData:obj];
}

- (void) test3
{
	NSMutableAttributedString *s=[[NSMutableAttributedString alloc] initWithString:@"string"];
	[[s mutableString] setString:@"a much longer string"];
	// test what happens...
	[s release];
}

@end
