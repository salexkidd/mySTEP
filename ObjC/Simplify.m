//
//  Simplify.m
//  objc2pp
//
//  Created by H. Nikolaus Schaller on 16.02.12.
//  Copyright 2012 Golden Delicious Computers GmbH&Co. KG. All rights reserved.
//

#import "Simplify.h"

// NOTE: evaluation/simplification of constant float expression needs private IEEE FPU implementation!
// unless we want to require a FPU on the underlaying system

/*
 * evaluate constant expressions
 * remove dead code
 * expand static inline
 * loop unrolling/vectorization
 * evaluate common subexpressions only once
 * remove "parexpr"
 */

@implementation Node (Simplify)

- (void) redo
{
	// set redo flag
	// can be called as [self redo] or [parent redo]
}

- (void) simplify;
{ // main function
	// FIXME: should loop on each level individually!
	// should loop while something has been modified or a redo-indicator/attribute has been set
	[self treeWalk:@"simplify_"];	// recursive
}

- (void) simplify_default
{
}

- (void) simplifycomment
{
	[self replaceBy:nil];	// delete
}

- (void) simplifyparaexpr
{
	[self replaceBy:[self firstChild]];	// remove braces node
}

- (void) simplifyblock
{
	if([self childrenCount] == 0)
		[self replaceBy:nil];	// remove
}

- (void) simplifyif
{
	// check for constant condition
	// replace by then or else part
	if([self childrenCount] == 0)
		[self replaceBy:nil];	// statement has no effect - can be removed
}

- (void) simplifywhile
{
	// check for constant condition
	// optionally remove whole loop
	/* should we eliminate empty while loops in any case? what with while(1); ? */
	if(/* condition is false */ [self childrenCount] == 0)
		[self replaceBy:nil];	// statement has no effect - can be removed
}

@end
