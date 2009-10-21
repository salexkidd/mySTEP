//
//  ScreenSaverDefaults.h
//  ScreenSaver
//
//  Created by H. Nikolaus Schaller on 20.10.09.
//  Copyright 2009 Golden Delicious Computers GmbH&Co. KG. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface ScreenSaverDefaults : NSUserDefaults {

}

+ (id) defaultsForModuleWithName:(NSString *) name;

@end
