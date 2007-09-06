/* 
   NSBundle.h

   Interface to NSBundle class

   Copyright (C) 1995, 1997 Free Software Foundation, Inc.

   Author:	Adam Fedor <fedor@boulder.colorado.edu>
   Date:	1995
   Author:	H. Nikolaus Schaller <hns@computer.org>
   Date:	2003

   H.N.Schaller, Dec 2005 - API revised to be compatible to 10.4

   This file is part of the mySTEP Library and is provided
   under the terms of the GNU Library General Public License.
*/ 

#ifndef _mySTEP_H_NSBundle
#define _mySTEP_H_NSBundle

#import <Foundation/NSObject.h>

#define NSLocalizedString(key, comment) \
	[[NSBundle mainBundle] localizedStringForKey:(key) value:(key) table:nil]
#define NSLocalizedStringFromTable(key, tbl, comment) \
	[[NSBundle mainBundle] localizedStringForKey:(key) value:(key) table:(tbl)]
#define NSLocalizedStringFromTableInBundle(key, tbl, bundle, comment) \
	[bundle localizedStringForKey:(key) value:(key) table:(tbl)]
#define NSLocalizedStringWithDefaultValue(key, tbl, bundle, value, comment) \
	[bundle localizedStringForKey:(key) value:(value) table:(tbl)]

@class NSString;
@class NSArray;
@class NSMutableArray;
@class NSDictionary;
@class NSMutableDictionary;

extern NSString *NSBundleDidLoadNotification;
extern NSString *NSLoadedClasses;

@interface NSBundle : NSObject
{
    NSString *_path;
    NSString *_bundleContentPath;
    NSMutableArray *_bundleClasses;
    NSMutableDictionary *_searchPaths;			// cache
	NSMutableArray *_localizations;				// cache
	NSMutableArray *_preferredLocalizations;	// cache
	Class _principalClass;
    NSDictionary *_infoDict;
	unsigned int _bundleType;
	BOOL _codeLoaded;
}

+ (NSArray *) allBundles;
+ (NSArray *) allFrameworks;
+ (NSBundle *) bundleForClass:(Class)aClass;
+ (NSBundle *) bundleWithIdentifier:(NSString *) ident;
+ (NSBundle *) bundleWithPath:(NSString *)path;
+ (NSBundle *) mainBundle;
+ (NSString *) pathForResource:(NSString *)name
						ofType:(NSString *)ext
				   inDirectory:(NSString *)bundlePath;
+ (NSArray *) pathsForResourcesOfType:(NSString *) ext
						  inDirectory:(NSString *)bundlePath;
+ (NSArray *) preferredLocalizationsFromArray:(NSArray *) array;
+ (NSArray *) preferredLocalizationsFromArray:(NSArray *) array
							   forPreferences:(NSArray *) pref;

- (NSString *) builtInPlugInsPath;
- (NSString *) bundleIdentifier;
- (NSString *) bundlePath;
- (Class) classNamed:(NSString *)className;
- (NSString *) developmentLocalization;
- (NSString *) executablePath;
- (NSDictionary *) infoDictionary;
- (id) initWithPath:(NSString *) fullpath;
- (BOOL) isLoaded;
- (BOOL) load;
- (NSArray *) localizations;
- (NSDictionary *) localizedInfoDictionary;
- (NSString *) localizedStringForKey:(NSString *)key	
							   value:(NSString *)value
							   table:(NSString *)tableName;
- (id) objectForInfoDictionaryKey:(NSString *) key;
- (NSString *) pathForAuxiliaryExecutable:(NSString *) name;
- (NSString *) pathForResource:(NSString *)name
						ofType:(NSString *)ext;
- (NSString *) pathForResource:(NSString *)name
						ofType:(NSString *)ext	
				   inDirectory:(NSString *)subpath;
- (NSString *) pathForResource:(NSString *)name
						ofType:(NSString *)ext	
				   inDirectory:(NSString *)subpath
			   forLocalization:(NSString *)locale;
- (NSArray *) pathsForResourcesOfType:(NSString *)extension
						  inDirectory:(NSString *)subpath;
- (NSArray *) pathsForResourcesOfType:(NSString *)extension
						  inDirectory:(NSString *)subpath
					  forLocalization:(NSString *)locale;
- (NSArray *) preferredLocalizations;
- (Class) principalClass;
- (NSString *) privateFrameworksPath;
- (NSString *) resourcePath;
- (NSString *) sharedFrameworksPath;
- (NSString *) sharedSupportPath;

@end

#endif /* _mySTEP_H_NSBundle */
