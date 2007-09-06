/* 
   NSFileWrapper.h

   NSFileWrapper objects hold a file's contents in dynamic memory.

   Copyright (C) 1996 Free Software Foundation, Inc.

   Author:  Felipe A. Rodriguez <far@ix.netcom.com>
   Date: Sept 1998

   This file is part of the GNUstep GUI Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; see the file COPYING.LIB.
   If not, write to the Free Software Foundation,
   59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*/ 

#ifndef _GNUstep_H_NSFileWrapper
#define _GNUstep_H_NSFileWrapper

#import <Foundation/NSDictionary.h>
#import <AppKit/NSImage.h>

@class NSImage;
@class NSString;

typedef enum
{
	GSFileWrapperDirectoryType,
	GSFileWrapperRegularFileType,
	GSFileWrapperSymbolicLinkType
} GSFileWrapperType;

@interface NSFileWrapper : NSObject 
{
	NSString		*_filename;
	NSString		*_preferredFilename;
	NSMutableDictionary	*_fileAttributes;
	GSFileWrapperType	_wrapperType;
	id			_wrapperData;
	NSImage		*_iconImage;
}

//
// Initialization 
//

// Init instance of directory type
- (id)initDirectoryWithFileWrappers:(NSDictionary *)docs;	 

	// Init instance of regular file type
- (id)initRegularFileWithContents:(NSData *)data;		 

	// Init instance of symbolic link type
- (id)initSymbolicLinkWithDestination:(NSString *)path;

	// Init an instance from the file, directory, or symbolic link at path. 
	// This can create a tree of instances 
- (id)initWithPath:(NSString *)path;	// with a directory instance at the top

	// Init an instance from data in standard serial format.  Serial format
	// is the same as that used by NSText's RTFDFromRange: method.  This can 
	// create a tree of instances with a directory instance at the top
- (id)initWithSerializedRepresentation:(NSData *)data;

	//
	// General methods 
	//

	// write instace to disk at path. if directory type, this method is recursive
	// if flag is YES, the wrapper will be updated with the name used in writing
	// the file
- (BOOL)writeToFile:(NSString *)path
         atomically:(BOOL)atomicFlag
    updateFilenames:(BOOL)updateFilenamesFlag;

- (NSData *)serializedRepresentation;

- (void)setFilename:(NSString *)filename;
- (NSString *)filename;

- (void)setPreferredFilename:(NSString *)filename;
- (NSString *)preferredFilename;

- (void)setFileAttributes:(NSDictionary *)attributes;
- (NSDictionary *)fileAttributes;

- (BOOL)isRegularFile;
- (BOOL)isDirectory;
- (BOOL)isSymbolicLink;

- (void)setIcon:(NSImage *)icon;
- (NSImage *)icon;

- (BOOL)needsToBeUpdatedFromPath:(NSString *)path;
- (BOOL)updateFromPath:(NSString *)path;

	//								
	// Directory type methods 				  
	//

	// these messages raise an exception when sent to non-directory type wrappers!
- (NSString *)addFileWrapper:(NSFileWrapper *)doc;
- (void)removeFileWrapper:(NSFileWrapper *)doc;
- (NSDictionary *)fileWrappers;
- (NSString *)keyForFileWrapper:(NSFileWrapper *)doc;
- (NSString *)addFileWithPath:(NSString *)path;
- (NSString *)addRegularFileWithContents:(NSData *)data 
                       preferredFilename:(NSString *)filename;
- (NSString *)addSymbolicLinkWithDestination:(NSString *)path 
                           preferredFilename:(NSString *)filename;

	//
	// Regular file type methods 				  
	//

- (NSData *)regularFileContents;

	//
	// Symbolic link type methods 				  
	//

- (NSString *)symbolicLinkDestination;

@end

#endif // _GNUstep_H_NSFileWrapper
