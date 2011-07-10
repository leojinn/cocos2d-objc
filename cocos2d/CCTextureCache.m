/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2008-2010 Ricardo Quesada
 * Copyright (c) 2011 Zynga Inc.
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#import <Availability.h>

#import "Platforms/CCGL.h"
#import "CCTextureCache.h"
#import "CCTexture2D.h"
#import "CCTexturePVR.h"
#import "ccMacros.h"
#import "CCConfiguration.h"
#import "Support/CCFileUtils.h"
#import "CCDirector.h"
#import "ccConfig.h"

// needed for CCCallFuncO in Mac-display_link version
#import "CCActionManager.h"
#import "CCActionInstant.h"

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
static EAGLContext *_auxGLcontext = nil;
#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
static NSOpenGLContext *_auxGLcontext = nil;
#endif

static dispatch_queue_t _concurrentQueue;

@implementation CCTextureCache

#pragma mark TextureCache - Alloc, Init & Dealloc
static CCTextureCache *sharedTextureCache;

+ (CCTextureCache *)sharedTextureCache
{
	if (!sharedTextureCache)
		sharedTextureCache = [[self alloc] init];
		
	return sharedTextureCache;
}

+(id)alloc
{
	NSAssert(sharedTextureCache == nil, @"Attempted to allocate a second instance of a singleton.");
	return [super alloc];
}

+(void)purgeSharedTextureCache
{
	[sharedTextureCache release];
	sharedTextureCache = nil;
}

-(id) init
{
	if( (self=[super init]) ) {
		textures_ = [[NSMutableDictionary dictionaryWithCapacity: 10] retain];
		
		// init "global" stuff
		_concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
			_auxGLcontext = [[EAGLContext alloc]
							 initWithAPI:kEAGLRenderingAPIOpenGLES2
							 sharegroup:[[[[CCDirector sharedDirector] openGLView] context] sharegroup]];
		
#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
		
			MacGLView *view = [[CCDirector sharedDirector] openGLView];
			
			NSOpenGLPixelFormat *pf = [view pixelFormat];
			NSOpenGLContext *share = [view openGLContext];
			
			_auxGLcontext = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:share];

#endif // __MAC_OS_X_VERSION_MAX_ALLOWED

			NSAssert( _auxGLcontext, @"TextureCache: Could not create EAGL context");
		

	}

	return self;
}

- (NSString*) description
{
	return [NSString stringWithFormat:@"<%@ = %08X | num of textures =  %i | keys: %@>",
			[self class],
			self,
			[textures_ count],
			[textures_ allKeys]
			];
			
}

-(void) dealloc
{
	CCLOGINFO(@"cocos2d: deallocing %@", self);

	[textures_ release];
	[_auxGLcontext release];
	_auxGLcontext = nil;
	sharedTextureCache = nil;
	[super dealloc];
}

#pragma mark TextureCache - Add Images

-(void) addImageAsync: (NSString*)path target:(id)target selector:(SEL)selector
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");
	NSAssert(target != nil, @"TextureCache: target can't be nil");
	NSAssert(selector != NULL, @"TextureCache: selector can't be NULL");

	// optimization
	
	CCTexture2D * tex;
	
	path = ccRemoveHDSuffixFromFile(path);
	
	if( (tex=[textures_ objectForKey: path] ) ) {
		[target performSelector:selector withObject:tex];
		return;
	}

	// dispatch it concurrently
	dispatch_async(_concurrentQueue, ^{
		
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
		if( [EAGLContext setCurrentContext:_auxGLcontext] ) {
			
			// load / create the texture
			CCTexture2D *tex = [self addImage:path];
			
			glFlush();
			
			// callback should be executed in cocos2d thread
			id action = [CCCallFuncO actionWithTarget:target selector:selector object:tex];			
			[[CCActionManager sharedManager] addAction:action target:target paused:NO];
			
			[EAGLContext setCurrentContext:nil];
		} else {
			CCLOG(@"cocos2d: ERROR: TetureCache: Could not set EAGLContext");
		}
		
#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
		
		[_auxGLcontext makeCurrentContext];
		
		// load / create the texture
		CCTexture2D *tex = [self addImage:path];
		
		glFlush();
		
		// callback should be executed in cocos2d thread
		id action = [CCCallFuncO actionWithTarget:target selector:selector object:tex];			
		[[CCActionManager sharedManager] addAction:action target:target paused:NO];
		
		[NSOpenGLContext clearCurrentContext];
				
#endif // __MAC_OS_X_VERSION_MAX_ALLOWED

	});	
}

-(void) addImageAsync:(NSString*)path withBlock:(void(^)(CCTexture2D* tex))block
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");
	
	// optimization
	
	CCTexture2D * tex;
	
	path = ccRemoveHDSuffixFromFile(path);
	
	if( (tex=[textures_ objectForKey: path] ) ) {
		block(tex);
		return;
	}
	
	// dispatch it concurrently
	dispatch_async( _concurrentQueue, ^{
		
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
		if( [EAGLContext setCurrentContext:_auxGLcontext] ) {
			
			// load / create the texture
			CCTexture2D *tex = [self addImage:path];
			
			glFlush();
			
			// callback should be executed in cocos2d thread
			id action = [CCCallBlockO actionWithBlock:block object:tex];
			[[CCActionManager sharedManager] addAction:action target:self paused:NO];
			
			[EAGLContext setCurrentContext:nil];
		} else {
			CCLOG(@"cocos2d: ERROR: TetureCache: Could not set EAGLContext");
		}

#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
		
		[_auxGLcontext makeCurrentContext];
		
		// load / create the texture
		CCTexture2D *tex = [self addImage:path];
		
		glFlush();
		
		// callback should be executed in cocos2d thread
		id action = [CCCallBlockO actionWithBlock:block object:tex];
		[[CCActionManager sharedManager] addAction:action target:self paused:NO];
		
		[NSOpenGLContext clearCurrentContext];
		
#endif // __MAC_OS_X_VERSION_MAX_ALLOWED

	});	
}

-(CCTexture2D*) addImage: (NSString*) path
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");

	CCTexture2D * tex = nil;

	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	path = ccRemoveHDSuffixFromFile( path );

	// Needed since addImageAsync calls this method from a different task
	@synchronized( self ) {
		tex=[textures_ objectForKey: path];
		
		if( ! tex ) {
			
			NSString *lowerCase = [path lowercaseString];
			// all images are handled by UIImage except PVR extension that is handled by our own handler
			
			if ( [lowerCase hasSuffix:@".pvr"] || [lowerCase hasSuffix:@".pvr.gz"] || [lowerCase hasSuffix:@".pvr.ccz"] )
				tex = [self addPVRImage:path];

			// Only iPhone
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

			// Issue #886: TEMPORARY FIX FOR TRANSPARENT JPEGS IN IOS4
			else if ( ( [[CCConfiguration sharedConfiguration] OSVersion] >= kCCiOSVersion_4_0) &&
					  ( [lowerCase hasSuffix:@".jpg"] || [lowerCase hasSuffix:@".jpeg"] ) 
					 ) {
				// convert jpg to png before loading the texture
				
				CCLOG(@"cocos2d: WARNING: Loading JPEG image. For faster loading times, convert it to PVR or PNG");
				
				NSString *fullpath = [CCFileUtils fullPathFromRelativePath: path ];
							
				UIImage *jpg = [[UIImage alloc] initWithContentsOfFile:fullpath];
				UIImage *png = [[UIImage alloc] initWithData:UIImagePNGRepresentation(jpg)];
				tex = [ [CCTexture2D alloc] initWithImage: png ];
				[png release];
				[jpg release];
				
				if( tex )
					[textures_ setObject: tex forKey:path];
				else
					CCLOG(@"cocos2d: Couldn't add image:%@ in CCTextureCache", path);
				
				// autorelease prevents possible crash in multithreaded environments
				[tex autorelease];
			}

			else {
				
				// prevents overloading the autorelease pool
				NSString *fullpath = [CCFileUtils fullPathFromRelativePath: path ];

				UIImage *image = [ [UIImage alloc] initWithContentsOfFile: fullpath ];
				tex = [ [CCTexture2D alloc] initWithImage: image ];
				[image release];
				
				if( tex )
					[textures_ setObject: tex forKey:path];
				else
					CCLOG(@"cocos2d: Couldn't add image:%@ in CCTextureCache", path);
				
				// autorelease prevents possible crash in multithreaded environments
				[tex autorelease];			
			}

			
			// Only in Mac
#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
			else {
				NSString *fullpath = [CCFileUtils fullPathFromRelativePath: path ];

				NSData *data = [[NSData alloc] initWithContentsOfFile:fullpath];
				NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithData:data];
				tex = [ [CCTexture2D alloc] initWithImage:[image CGImage]];
				
				[data release];
				[image release];

				if( tex )
					[textures_ setObject: tex forKey:path];
				else
					CCLOG(@"cocos2d: Couldn't add image:%@ in CCTextureCache", path);
				
				// autorelease prevents possible crash in multithreaded environments
				[tex autorelease];			
			}

#endif // __MAC_OS_X_VERSION_MAX_ALLOWED

		}
	}
	
	return tex;
}


-(CCTexture2D*) addCGImage: (CGImageRef) imageref forKey: (NSString *)key
{
	NSAssert(imageref != nil, @"TextureCache: image MUST not be nill");
	
	CCTexture2D * tex = nil;
	
	// If key is nil, then create a new texture each time
	if( key && (tex=[textures_ objectForKey: key] ) ) {
		return tex;
	}
	
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
	// prevents overloading the autorelease pool
	UIImage *image = [[UIImage alloc] initWithCGImage:imageref];
	tex = [[CCTexture2D alloc] initWithImage: image];
	[image release];

#elif defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
	tex = [[CCTexture2D alloc] initWithImage: imageref];
#endif
	
	if(tex && key)
		[textures_ setObject: tex forKey:key];
	else
		CCLOG(@"cocos2d: Couldn't add CGImage in CCTextureCache");
	
	return [tex autorelease];
}

#pragma mark TextureCache - Remove

-(void) removeAllTextures
{
	[textures_ removeAllObjects];
}

-(void) removeUnusedTextures
{
	NSArray *keys = [textures_ allKeys];
	for( id key in keys ) {
		id value = [textures_ objectForKey:key];		
		if( [value retainCount] == 1 ) {
			CCLOG(@"cocos2d: CCTextureCache: removing unused texture: %@", key);
			[textures_ removeObjectForKey:key];
		}
	}
}

-(void) removeTexture: (CCTexture2D*) tex
{
	if( ! tex )
		return;
	
	NSArray *keys = [textures_ allKeysForObject:tex];
	
	for( NSUInteger i = 0; i < [keys count]; i++ )
		[textures_ removeObjectForKey:[keys objectAtIndex:i]];
}

-(void) removeTextureForKey:(NSString*)name
{
	if( ! name )
		return;
	
	[textures_ removeObjectForKey:name];
}

#pragma mark TextureCache - Get
- (CCTexture2D *)textureForKey:(NSString *)key
{
    return [textures_ objectForKey:key];    
}

@end


@implementation CCTextureCache (PVRSupport)

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
-(CCTexture2D*) addPVRTCImage:(NSString*)path bpp:(int)bpp hasAlpha:(BOOL)alpha width:(int)w
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");
	NSAssert( bpp==2 || bpp==4, @"TextureCache: bpp must be either 2 or 4");
	
	CCTexture2D * tex;
	
	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	path = ccRemoveHDSuffixFromFile( path );

	if( (tex=[textures_ objectForKey: path] ) ) {
		return tex;
	}
	
	// Split up directory and filename
	NSString *fullpath = [CCFileUtils fullPathFromRelativePath:path];
	
	NSData *nsdata = [[NSData alloc] initWithContentsOfFile:fullpath];
	tex = [[CCTexture2D alloc] initWithPVRTCData:[nsdata bytes] level:0 bpp:bpp hasAlpha:alpha length:w pixelFormat:bpp==2?kCCTexture2DPixelFormat_PVRTC2:kCCTexture2DPixelFormat_PVRTC4];
	if( tex )
		[textures_ setObject: tex forKey:path];
	else
		CCLOG(@"cocos2d: Couldn't add PVRTCImage:%@ in CCTextureCache",path);
	
	[nsdata release];
	
	return [tex autorelease];
}
#endif // __IPHONE_OS_VERSION_MAX_ALLOWED

-(CCTexture2D*) addPVRImage:(NSString*)path
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");
	
	CCTexture2D * tex;
	
	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	path = ccRemoveHDSuffixFromFile( path );

	if( (tex=[textures_ objectForKey: path] ) ) {
		return tex;
	}
	
	// Split up directory and filename
	NSString *fullpath = [CCFileUtils fullPathFromRelativePath:path];
	
	tex = [[CCTexture2D alloc] initWithPVRFile: fullpath];
	if( tex )
		[textures_ setObject: tex forKey:path];
	else
		CCLOG(@"cocos2d: Couldn't add PVRImage:%@ in CCTextureCache",path);	
	
	return [tex autorelease];
}

@end


@implementation CCTextureCache (Debug)

-(void) dumpCachedTextureInfo
{
	NSUInteger count = 0;
	NSUInteger totalBytes = 0;
	for (NSString* texKey in textures_) {
		CCTexture2D* tex = [textures_ objectForKey:texKey];
		NSUInteger bpp = [tex bitsPerPixelForFormat];
		// Each texture takes up width * height * bytesPerPixel bytes.
		NSUInteger bytes = tex.pixelsWide * tex.pixelsWide * bpp / 8;
		totalBytes += bytes;
		count++;
		CCLOG( @"cocos2d: \"%@\" rc=%lu id=%lu %lu x %lu @ %ld bpp => %lu KB",
			  texKey,
			  (long)[tex retainCount],
			  (long)tex.name,
			  (long)tex.pixelsWide,
			  (long)tex.pixelsHigh,
			  (long)bpp,
			  (long)bytes / 1024 );
	}
	CCLOG( @"cocos2d: CCTextureCache dumpDebugInfo: %ld textures, for %lu KB (%.2f MB)", (long)count, (long)totalBytes / 1024, totalBytes / (1024.0f*1024.0f));
}

@end
