//
//  MockCameraViewController.m
//  MockMyFace
//
//  Created by Jaume Cornadó on 10/11/11.
//  Copyright (c) 2011 Bazinga Systems. All rights reserved.
//

#import "MockCameraViewConroller.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "ViewAndShareController.h"

#pragma mark-

// used for KVO observation of the @"capturingStillImage" property to perform flash bulb animation
static const NSString *AVCaptureStillImageIsCapturingStillImageContext = @"AVCaptureStillImageIsCapturingStillImageContext";

static CGFloat DegreesToRadians(CGFloat degrees) {return degrees * M_PI / 180;};

static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size);
static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size) 
{	
	CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)pixel;
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
	CVPixelBufferRelease( pixelBuffer );
}

// create a CGImage with provided pixel buffer, pixel buffer must be uncompressed kCVPixelFormatType_32ARGB or kCVPixelFormatType_32BGRA
static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut);
static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut) 
{	
	OSStatus err = noErr;
	OSType sourcePixelFormat;
	size_t width, height, sourceRowBytes;
	void *sourceBaseAddr = NULL;
	CGBitmapInfo bitmapInfo;
	CGColorSpaceRef colorspace = NULL;
	CGDataProviderRef provider = NULL;
	CGImageRef image = NULL;
	
	sourcePixelFormat = CVPixelBufferGetPixelFormatType( pixelBuffer );
	if ( kCVPixelFormatType_32ARGB == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
	else if ( kCVPixelFormatType_32BGRA == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
	else
		return -95014; // only uncompressed pixel formats
	
	sourceRowBytes = CVPixelBufferGetBytesPerRow( pixelBuffer );
	width = CVPixelBufferGetWidth( pixelBuffer );
	height = CVPixelBufferGetHeight( pixelBuffer );
	
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	sourceBaseAddr = CVPixelBufferGetBaseAddress( pixelBuffer );
	
	colorspace = CGColorSpaceCreateDeviceRGB();
    
	CVPixelBufferRetain( pixelBuffer );
	provider = CGDataProviderCreateWithData( (void *)pixelBuffer, sourceBaseAddr, sourceRowBytes * height, ReleaseCVPixelBuffer);
	image = CGImageCreate(width, height, 8, 32, sourceRowBytes, colorspace, bitmapInfo, provider, NULL, true, kCGRenderingIntentDefault);
	
bail:
	if ( err && image ) {
		CGImageRelease( image );
		image = NULL;
	}
	if ( provider ) CGDataProviderRelease( provider );
	if ( colorspace ) CGColorSpaceRelease( colorspace );
	*imageOut = image;
	return err;
}

// utility used by newSquareOverlayedImageForFeatures for 
static CGContextRef CreateCGBitmapContextForSize(CGSize size);
static CGContextRef CreateCGBitmapContextForSize(CGSize size)
{
    CGContextRef    context = NULL;
    CGColorSpaceRef colorSpace;
    int             bitmapBytesPerRow;
	
    bitmapBytesPerRow = (size.width * 4);
	
    colorSpace = CGColorSpaceCreateDeviceRGB();
    context = CGBitmapContextCreate (NULL,
									 size.width,
									 size.height,
									 8,      // bits per component
									 bitmapBytesPerRow,
									 colorSpace,
									 kCGImageAlphaPremultipliedLast);
	CGContextSetAllowsAntialiasing(context, NO);
    CGColorSpaceRelease( colorSpace );
    return context;
}

//Private UIImage Category
@interface UIImage (RotationMethods)
- (UIImage *)imageRotatedByDegrees:(CGFloat)degrees;
@end

@implementation UIImage (RotationMethods)

- (UIImage *)imageRotatedByDegrees:(CGFloat)degrees 
{   
	// calculate the size of the rotated view's containing box for our drawing space
	UIView *rotatedViewBox = [[UIView alloc] initWithFrame:CGRectMake(0,0,self.size.width, self.size.height)];
	CGAffineTransform t = CGAffineTransformMakeRotation(DegreesToRadians(degrees));
	rotatedViewBox.transform = t;
	CGSize rotatedSize = rotatedViewBox.frame.size;
	
	// Create the bitmap context
	UIGraphicsBeginImageContext(rotatedSize);
	CGContextRef bitmap = UIGraphicsGetCurrentContext();
	
	// Move the origin to the middle of the image so we will rotate and scale around the center.
	CGContextTranslateCTM(bitmap, rotatedSize.width/2, rotatedSize.height/2);
	
	//   // Rotate the image context
	CGContextRotateCTM(bitmap, DegreesToRadians(degrees));
	
	// Now, draw the rotated/scaled image into the context
	CGContextScaleCTM(bitmap, 1.0, -1.0);
	CGContextDrawImage(bitmap, CGRectMake(-self.size.width / 2, -self.size.height / 2, self.size.width, self.size.height), [self CGImage]);
	
	UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return newImage;
}

@end


//Private methods
@interface MockCameraViewController (InternalMethods)
- (void)setupAVCapture;
- (void)teardownAVCapture;
- (void)drawFaceBoxesForFeatures:(NSArray *)features forVideoBox:(CGRect)clap orientation:(UIDeviceOrientation)orientation;
@end



//Main class
@implementation MockCameraViewController

const CGBitmapInfo kDefaultCGBitmapInfo	= (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
const CGBitmapInfo kDefaultCGBitmapInfoNoAlpha	= (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);

@synthesize itemSelectorViewController, previewController, sunglasses, hat, mouth, marc, stillImageOutput, videoDataOutput, previewView, previewLayer, faceIndicatorLayer, session;

/* Turn on the camera */
- (void)setupAVCapture
{
	NSError *error = nil;
	
	session = [AVCaptureSession new];
    
    [session setSessionPreset:AVCaptureSessionPreset640x480];
	
    // Select a video device, make an input
	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
	
    //Error starting the camera
    if(error != nil) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"Failed with error %d", (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil 
												  cancelButtonTitle:@"Dismiss" 
												  otherButtonTitles:nil];
		[alertView show];
		
		[self teardownAVCapture];
        return;
    }
    
	
    if ( [session canAddInput:deviceInput] )
		[session addInput:deviceInput];
	
    // Make a still image output to process the photos we will take
	stillImageOutput = [AVCaptureStillImageOutput new];
   
	if([session canAddOutput:stillImageOutput])
		[session addOutput:stillImageOutput];
	
    // Make a video data output
	videoDataOutput = [AVCaptureVideoDataOutput new];
	
    // we want BGRA, both CoreGraphics and OpenGL work well with 'BGRA'
	NSDictionary *rgbOutputSettings = [NSDictionary dictionaryWithObject:
									   [NSNumber numberWithInt:kCMPixelFormat_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
	[videoDataOutput setVideoSettings:rgbOutputSettings];
	[videoDataOutput setAlwaysDiscardsLateVideoFrames:YES]; // discard if the data output queue is blocked (as we process the still image)
    
    // create a serial dispatch queue used for the sample buffer delegate as well as when a still image is captured
    // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
    // see the header doc for setSampleBufferDelegate:queue: for more information
	videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
	[videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];
	
    if([session canAddOutput:videoDataOutput])
		[session addOutput:videoDataOutput];
	[[videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:NO];
	
	effectiveScale = 1.0;
    
    //Attach the video to a view on the screen, so we can see it.
	previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
	[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
	[previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
	CALayer *rootLayer = [previewView layer];
	[rootLayer setMasksToBounds:YES];
	[previewLayer setFrame:[rootLayer bounds]];
	[rootLayer insertSublayer:previewLayer atIndex:0];
	[session startRunning];
}

// clean up capture setup
- (void)teardownAVCapture
{
	if (videoDataOutputQueue)
		dispatch_release(videoDataOutputQueue);
	
    [previewLayer removeFromSuperlayer];
	
    previewLayer = nil;
    session = nil;
    videoDataOutputQueue = nil;
    previewLayer = nil;
    videoDataOutput = nil;
    stillImageOutput = nil;
}

// utility routing used during image capture to set up capture orientation
- (AVCaptureVideoOrientation)avOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation
{
	AVCaptureVideoOrientation result = deviceOrientation;
	if ( deviceOrientation == UIDeviceOrientationLandscapeLeft )
		result = AVCaptureVideoOrientationLandscapeRight;
	else if ( deviceOrientation == UIDeviceOrientationLandscapeRight )
		result = AVCaptureVideoOrientationLandscapeLeft;
	return result;
}

// utility routine to create a new image with the red square overlay with appropriate orientation
// and return the new composited image which can be saved to the camera roll
- (CGImageRef)newSquareOverlayedImageForFeatures:(NSArray *)features
                                       inCGImage:(CGImageRef)backgroundImage 
                                 withOrientation:(UIDeviceOrientation)orientation 
                                     frontFacing:(BOOL)isFrontFacing
                                withSampleBuffer:(CMSampleBufferRef) sampleBuffer 
{
    
    CGImageRef returnImage = NULL;
    
    CGRect backgroundImageRect = CGRectMake(0, 0, 480, 320);
    CGContextRef bitmapContext = CreateCGBitmapContextForSize(backgroundImageRect.size);
    
	CGContextClearRect(bitmapContext, backgroundImageRect);
    
    // get the clean aperture
    // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
    // that represents image data valid for display.
	CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sampleBuffer);
	CGRect clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/);
    
    CGSize parentFrameSize = [previewView frame].size;
	NSString *gravity = [previewLayer videoGravity];

    CGRect previewBox = [MockCameraViewController videoPreviewBoxForGravity:gravity
                                                                 frameSize:parentFrameSize 
                                                              apertureSize:clap.size];
    
    //draw the image on the camera
    CGContextDrawImage(bitmapContext, 
                       CGRectMake(previewBox.origin.y, previewBox.origin.x, previewBox.size.height, previewBox.size.width)
                       , backgroundImage);
    
	CGFloat rotationDegrees = 0.;
	
	switch (orientation) {
		case UIDeviceOrientationPortrait:
			rotationDegrees = -90.;
			break;
		case UIDeviceOrientationPortraitUpsideDown:
			rotationDegrees = 90.;
			break;
		case UIDeviceOrientationLandscapeLeft:
			if (isFrontFacing) rotationDegrees = 180.;
			else rotationDegrees = 0.;
			break;
		case UIDeviceOrientationLandscapeRight:
			if (isFrontFacing) rotationDegrees = 0.;
			else rotationDegrees = 180.;
			break;
		case UIDeviceOrientationFaceUp:
		case UIDeviceOrientationFaceDown:
		default:
			break; // leave the layer in its last known orientation
	}
    
    //Check if we have faces on the screen
    if([features count] == 0) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error" message:@"No faces detected!" delegate:self cancelButtonTitle:@"Ok" otherButtonTitles: nil];
        [alertView show];
    }
	
    //Iterate over faces to mock it
	for (CIFaceFeature *ff in features ) {
        
        /// SUNGLASSES POSITION
        if(self.sunglasses != nil) {
            CGRect glassesRect = [self getSunglassesRectFromFace:ff isStill:YES];
            UIImage *sunglassesImage = [sunglasses imageRotatedByDegrees:rotationDegrees];
            CGContextDrawImage(bitmapContext, glassesRect, [sunglassesImage CGImage]);
        }
        
        // HAT POSITION
        if(self.hat != nil) {
            CGRect hatRect = [self getHatRectFromFace:ff isStill:YES];
            UIImage *hatImage = [hat imageRotatedByDegrees:rotationDegrees];
            CGContextDrawImage(bitmapContext, hatRect, [hatImage CGImage]);
        }
        
        // MOUTH POSITION
        if(self.mouth != nil) {
            CGRect mouthRect = [self getMouthRectFromFace:ff isStill:YES];
            UIImage *mouthImage = [mouth imageRotatedByDegrees:rotationDegrees];
            CGContextDrawImage(bitmapContext, mouthRect, [mouthImage CGImage]);
        }
	}
    
    //Draw the border
    CGContextDrawImage(bitmapContext, backgroundImageRect, [[marc.image imageRotatedByDegrees:rotationDegrees] CGImage]);
    
	returnImage = CGBitmapContextCreateImage(bitmapContext);
	CGContextRelease (bitmapContext);
	
	return returnImage;
}


// utility routine to display error alert if takePicture fails
- (void)displayErrorOnMainQueue:(NSError *)error withMessage:(NSString *)message
{
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%d)", message, (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil 
												  cancelButtonTitle:@"Dismiss" 
												  otherButtonTitles:nil];
		[alertView show];
	
	});
}

//ItemSelectorDelegate implementation of takePhoto
-(void) takePhoto {
    
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    [hud setLabelFont:[UIFont fontWithName:@"SusanWrittingMAYUSC-Regular" size:15.0]];
    [hud setLabelText:@"Processing image"];
    
	// Find out the current orientation and tell the still image output.
	AVCaptureConnection *stillImageConnection = [stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
	UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
	AVCaptureVideoOrientation avcaptureOrientation = [self avOrientationForDeviceOrientation:curDeviceOrientation];
	[stillImageConnection setVideoOrientation:avcaptureOrientation];
	[stillImageConnection setVideoScaleAndCropFactor:effectiveScale];
	
    // set the appropriate pixel format / image type output setting depending on if we'll need an uncompressed image for
    // the possiblity of drawing the red square over top or if we're just writing a jpeg to the camera roll which is the trival case

    [stillImageOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA] 
                                                                    forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
	
	[stillImageOutput captureStillImageAsynchronouslyFromConnection:stillImageConnection
                                                  completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                                      if (error) {
                                                          [self displayErrorOnMainQueue:error withMessage:@"Take picture failed"];
                                                      }
                                                      else {
                                                          dispatch_sync(videoDataOutputQueue, ^(void) {
                                                              
                                                                  CGImageRef srcImage = NULL;
                                                                  OSStatus err = CreateCGImageFromCVPixelBuffer(CMSampleBufferGetImageBuffer(imageDataSampleBuffer), &srcImage);
                                                                  check(!err);
                                                                  
                                                                  CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, 
                                                                                                                              imageDataSampleBuffer, 
                                                                                                                              kCMAttachmentMode_ShouldPropagate);
                                                               
                                                                  
                                                                  NSDictionary *metadata = [[NSDictionary alloc] initWithDictionary:(__bridge NSDictionary*)attachments];

                                                                  
                                                                  
                                                                  NSDictionary *imageOptions = nil;
                                                                  NSNumber *orientation = (__bridge NSNumber*)CMGetAttachment(imageDataSampleBuffer,kCGImagePropertyOrientation, NULL);
                                                                  
                                                                  if (orientation) {
                                                                      imageOptions = [NSDictionary dictionaryWithObject:orientation forKey:CIDetectorImageOrientation];
                                                                  }
                                                                  
                                                              
                                                                    if(isUsingFrontFacingCamera) {
                                                                        srcImage = [self imageFlipedHorizontal: srcImage];
                                                              } else {
                                                                  srcImage = [self imageSized:srcImage];
                                                              }
                                                              
                                                              
                                                              
                                                                  CIImage *img = [[CIImage alloc] initWithCGImage:srcImage options:imageOptions];
                                                            
                                                                  NSArray *features = [faceDetector featuresInImage:img options:imageOptions];
                                                                  
                                                                  
                                                                  
                                                                CGImageRef cgImageResult = [self newSquareOverlayedImageForFeatures:features 
                                                                                                                            inCGImage:srcImage 
                                                                                                                      withOrientation:curDeviceOrientation 
                                                                                                                          frontFacing:isUsingFrontFacingCamera
                                                                                                                     withSampleBuffer:imageDataSampleBuffer];
                                                                                                                                  
                                                                  [self displayPreviewImage:cgImageResult withMetadata:metadata];
                                                                  
                                                                  
                                                        
                                                                  
                                                                  if (attachments)
                                                                      CFRelease(attachments);
                                                                  if (cgImageResult)
                                                                      CFRelease(cgImageResult);
                                                                      
                                                                  
                                                                 
                                                              });
                                                              
                                                              
                                                        
                                                      }
                                                  }
	 ];
    
    
    [stillImageOutput setOutputSettings:nil];
    
    
	
}

-(void) displayPreviewImage:(CGImageRef)previewImage withMetadata: (NSDictionary*) metadata {
    
    self.previewController = [[ViewAndShareController alloc] initWithNibName:@"ViewAndShareController" bundle:nil];
    self.previewController.view.frame = self.view.bounds;
    [self addChildViewController:self.previewController];
    //[[self view] addSubview:previewController.view];
    
    [UIView transitionWithView:self.view duration:0.5
                       options:UIViewAnimationOptionTransitionFlipFromBottom
                    animations:^ {  [[self view] addSubview:previewController.view]; }
                    completion:^(BOOL finished) {
                        [MBProgressHUD hideHUDForView:self.view animated:YES];
                    }];
    
    
    UIImage *image = [[UIImage alloc] initWithCGImage:previewImage scale:1.0 orientation:UIImageOrientationRight];
    
    [self.previewController.previewImage setImage:image];
    self.previewController.imageMetatadata = [NSDictionary dictionaryWithDictionary:metadata];
    
    //Init all the system to clean the memory
    [NSThread detachNewThreadSelector:@selector(restartVideoCapture) toTarget:self withObject:nil];
}

-(void) restartVideoCapture {
    [self teardownAVCapture];
    [self setupAVCapture];
    
    [self setFrontCamera:isUsingFrontFacingCamera];
}


-(CGImageRef) imageFlipedHorizontal: (CGImageRef) frontCamImage {
    
    CGImageRef imgRef = frontCamImage;
        
    /*CGFloat width = CGImageGetWidth(imgRef);
    CGFloat height = CGImageGetHeight(imgRef);*/
    CGFloat width = 480.0;
    CGFloat height = 320.0;
        
    CGAffineTransform transform = CGAffineTransformMake(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);
    CGRect bounds = CGRectMake(0, 0, width, height);
    
    UIGraphicsBeginImageContext(bounds.size);
        
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    CGContextConcatCTM(context, transform);
        
    CGContextDrawImage(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, width, height), imgRef);
    
    UIImage *imageCopy = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
        
    return [imageCopy CGImage];
}


-(CGImageRef) imageSized: (CGImageRef) backCamImage {
    
    CGImageRef imgRef = backCamImage;
    
    /*CGFloat width = CGImageGetWidth(imgRef);
     CGFloat height = CGImageGetHeight(imgRef);*/
    CGFloat width = 480.0;
    CGFloat height = 320.0;
    
    CGAffineTransform transform = CGAffineTransformMake(1.0, 0.0, 0, -1.0, 0.0, height);
    CGRect bounds = CGRectMake(0, 0, width, height);
    

    
    UIGraphicsBeginImageContext(bounds.size);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    CGContextConcatCTM(context, transform);
    
    CGContextDrawImage(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, width, height), imgRef);
    
    UIImage *imageCopy = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return [imageCopy CGImage];
}


// find where the video box is positioned within the preview layer based on the video size and gravity
+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity frameSize:(CGSize)frameSize apertureSize:(CGSize)apertureSize
{
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
    CGFloat viewRatio = frameSize.width / frameSize.height;
    
    CGSize size = CGSizeZero;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        } else {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
        if (viewRatio > apertureRatio) {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        } else {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        size.width = frameSize.width;
        size.height = frameSize.height;
    }
	
	CGRect videoBox;
	videoBox.size = size;
	if (size.width < frameSize.width)
		videoBox.origin.x = (frameSize.width - size.width) / 2;
	else
		videoBox.origin.x = (size.width - frameSize.width) / 2;
	
	if ( size.height < frameSize.height )
		videoBox.origin.y = (frameSize.height - size.height) / 2;
	else
		videoBox.origin.y = (size.height - frameSize.height) / 2;
    
	return videoBox;
}

-(NSMutableArray*) getEnabledLayers {
    NSMutableArray *enabledLayers = [NSMutableArray array];
    
    if(self.sunglasses != nil) [enabledLayers addObject:kSunglassesLayer];
    if(self.hat != nil) [enabledLayers addObject:kHatLayer];
    if(self.mouth != nil) [enabledLayers addObject:kMouthLayer];
    return enabledLayers;
}



// called asynchronously as the capture output is capturing sample buffers, this method asks the face detector (if on)
// to detect features and for each draw the red square in a layer and set appropriate orientation
- (void)drawFaceBoxesForFeatures:(NSArray *)features forVideoBox:(CGRect)clap orientation:(UIDeviceOrientation)orientation
{
    
    NSMutableArray *enabledLayers = [self getEnabledLayers];
    

    
	NSArray *sublayers = [NSArray arrayWithArray:[previewLayer sublayers]];
	NSInteger sublayersCount = [sublayers count], currentSublayer = 0;
	NSInteger featuresCount = [features count], currentFeature = 0;
	  
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
	
	// hide all the face layers
	for ( CALayer *layer in sublayers ) {
        if([enabledLayers containsObject:[layer name]]) 
            [layer setHidden:YES];
	}	
	
    //No faces detected, we show a message
	if ( featuresCount == 0) {
		[CATransaction commit];

        [self.faceIndicatorLayer displayMessage:YES withText:kNoFacesMessage];
        for(CALayer *layer in sublayers) {
            if([[layer name] isEqualToString:kHatLayer] ||
               [[layer name] isEqualToString:kSunglassesLayer] ||
               [[layer name] isEqualToString:kMouthLayer]                
               )
                [layer removeFromSuperlayer];
        }

		return; // early bail.
	} else {
        //If we got no items enabled, tell the user to enable something
        if([enabledLayers count] == 0) {
            [self.faceIndicatorLayer displayMessage:YES withText:kNoMocksEnabled];
        } else {
            [self.faceIndicatorLayer displayMessage:NO withText:nil];
        }
    }
    
	CGSize parentFrameSize = [previewView frame].size;
	NSString *gravity = [previewLayer videoGravity];
	BOOL isMirrored = [previewLayer isMirrored];
	CGRect previewBox = [MockCameraViewController videoPreviewBoxForGravity:gravity
                                                                 frameSize:parentFrameSize 
                                                              apertureSize:clap.size];
	     
    CIFaceFeature *ff = [features objectAtIndex:0];
    
    // find the correct position for the square layer within the previewLayer
    // the feature box originates in the bottom left of the video frame.
    // (Bottom right if mirroring is turned on)
    CGRect faceRect = [ff bounds];

    CGRect hatRect = [self getHatRectFromFace:ff isStill:NO];
        
    /*float mouthSize = faceRect.size.width / 2;
        
    CGRect mouthRect = CGRectMake((ff.mouthPosition.y-(mouthSize/2)), (ff.mouthPosition.x-(mouthSize/2))+10, mouthSize, mouthSize);*/
    CGRect mouthRect = [self getMouthRectFromFace:ff isStill:NO];
    
       
    CGRect glassesRect = [self getSunglassesRectFromFace:ff isStill:NO];
    
		// scale coordinates so they fit in the preview box, which may be scaled
		CGFloat widthScaleBy = previewBox.size.width / clap.size.height;
		CGFloat heightScaleBy = previewBox.size.height / clap.size.width;
		faceRect.size.width *= widthScaleBy;
		faceRect.size.height *= heightScaleBy;
		faceRect.origin.x *= widthScaleBy;
		faceRect.origin.y *= heightScaleBy;

        hatRect.size.width *= widthScaleBy;
        hatRect.size.height *= heightScaleBy;
        hatRect.origin.x *= widthScaleBy;
        hatRect.origin.y *= heightScaleBy;
        
        mouthRect.size.width *= widthScaleBy;
        mouthRect.size.height *= heightScaleBy;
        mouthRect.origin.x *= widthScaleBy;
        mouthRect.origin.y *= heightScaleBy;
        
        glassesRect.size.width *= widthScaleBy;
        glassesRect.size.height *= heightScaleBy;
        glassesRect.origin.x *= widthScaleBy;
        glassesRect.origin.y *= heightScaleBy;
        
        
		if ( isMirrored ) {
			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
            hatRect = CGRectOffset(hatRect, previewBox.origin.x + previewBox.size.width - hatRect.size.width - (hatRect.origin.x * 2), previewBox.origin.y);
            mouthRect = CGRectOffset(mouthRect, previewBox.origin.x + previewBox.size.width - mouthRect.size.width - (mouthRect.origin.x * 2), previewBox.origin.y);
           /* leftEyeRect = CGRectOffset(leftEyeRect, previewBox.origin.x + previewBox.size.width - leftEyeRect.size.width - (leftEyeRect.origin.x * 2), previewBox.origin.y);
            rightEyeRect = CGRectOffset(rightEyeRect, previewBox.origin.x + previewBox.size.width - rightEyeRect.size.width - (rightEyeRect.origin.x * 2), previewBox.origin.y);*/
            glassesRect = CGRectOffset(glassesRect, previewBox.origin.x + previewBox.size.width - glassesRect.size.width - (glassesRect.origin.x * 2), previewBox.origin.y);
        } else {
			faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);
            hatRect = CGRectOffset(hatRect, previewBox.origin.x, previewBox.origin.y);
            mouthRect = CGRectOffset(mouthRect, previewBox.origin.x, previewBox.origin.y);
            /*leftEyeRect = CGRectOffset(leftEyeRect, previewBox.origin.x, previewBox.origin.y);
            rightEyeRect = CGRectOffset(rightEyeRect, previewBox.origin.x, previewBox.origin.y);*/
            glassesRect = CGRectOffset(glassesRect, previewBox.origin.x, previewBox.origin.y);
        }
		
		
    CALayer *sunglassesLayer = nil, *mouthLayer = nil, *hatLayer = nil;
		
		// re-use an existing layer if possible
		while ( (!sunglassesLayer || !mouthLayer || !hatLayer) 
               && (currentSublayer < sublayersCount) ) {
			CALayer *currentLayer = [sublayers objectAtIndex:currentSublayer++];
            if([enabledLayers containsObject:[currentLayer name]]) {
				[currentLayer setHidden:NO];
                
                if([[currentLayer name] isEqualToString:kSunglassesLayer]) {
                    sunglassesLayer = currentLayer;
                } else if([[currentLayer name] isEqualToString:kHatLayer]) {
                    hatLayer = currentLayer;
                } else if([[currentLayer name] isEqualToString: kMouthLayer]) {
                    mouthLayer = currentLayer;
                }
            }
		}
        
        if(!sunglassesLayer && sunglasses != nil) {
            sunglassesLayer = [CALayer new];
            [sunglassesLayer setContents:(id)[sunglasses CGImage]];
            [sunglassesLayer setName:kSunglassesLayer];
            [previewLayer addSublayer:sunglassesLayer];
        }
        
        //sunglassesLayer.opacity = 0.5;
        //sunglassesLayer.backgroundColor = [[UIColor redColor] CGColor];
       
        [sunglassesLayer setFrame:glassesRect];
		
        if(!hatLayer && hat != nil) {
            hatLayer = [CALayer new];
            [hatLayer setContents:(id)[hat CGImage]];
            [hatLayer setName:kHatLayer];
            [previewLayer addSublayer:hatLayer];
        }

        //hatLayer.opacity = 0.5;
        //hatLayer.backgroundColor = [[UIColor blueColor] CGColor];
        [hatLayer setFrame:hatRect];
        
        if(!mouthLayer && mouth != nil) {
            mouthLayer = [CALayer new];
            [mouthLayer setContents:(id)[mouth CGImage]];
            [mouthLayer setName:kMouthLayer];
            [previewLayer addSublayer:mouthLayer];
        }
        
        //mouthLayer.opacity = 0.5;
        //mouthLayer.backgroundColor = [[UIColor purpleColor] CGColor];
        [mouthLayer setFrame:mouthRect];
                
		currentFeature++;
	
    //} //end of for face features
	
	[CATransaction commit];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{	
	// got an image
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
	CIImage *ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer options:(__bridge NSDictionary *)attachments];
	if (attachments)
		CFRelease(attachments);
	NSDictionary *imageOptions = nil;
	UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
	int exifOrientation;
	
    /* kCGImagePropertyOrientation values
     The intended display orientation of the image. If present, this key is a CFNumber value with the same value as defined
     by the TIFF and EXIF specifications -- see enumeration of integer constants. 
     The value specified where the origin (0,0) of the image is located. If not present, a value of 1 is assumed.
     
     used when calling featuresInImage: options: The value for this key is an integer NSNumber from 1..8 as found in kCGImagePropertyOrientation.
     If present, the detection will be done based on that orientation but the coordinates in the returned features will still be based on those of the image. */
    
	enum {
		PHOTOS_EXIF_0ROW_TOP_0COL_LEFT			= 1, //   1  =  0th row is at the top, and 0th column is on the left (THE DEFAULT).
		PHOTOS_EXIF_0ROW_TOP_0COL_RIGHT			= 2, //   2  =  0th row is at the top, and 0th column is on the right.  
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT      = 3, //   3  =  0th row is at the bottom, and 0th column is on the right.  
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_LEFT       = 4, //   4  =  0th row is at the bottom, and 0th column is on the left.  
		PHOTOS_EXIF_0ROW_LEFT_0COL_TOP          = 5, //   5  =  0th row is on the left, and 0th column is the top.  
		PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP         = 6, //   6  =  0th row is on the right, and 0th column is the top.  
		PHOTOS_EXIF_0ROW_RIGHT_0COL_BOTTOM      = 7, //   7  =  0th row is on the right, and 0th column is the bottom.  
		PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM       = 8  //   8  =  0th row is on the left, and 0th column is the bottom.  
	};
	
	switch (curDeviceOrientation) {
		case UIDeviceOrientationPortraitUpsideDown:  // Device oriented vertically, home button on the top
			exifOrientation = PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM;
			break;
		case UIDeviceOrientationLandscapeLeft:       // Device oriented horizontally, home button on the right
			if (isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			break;
		case UIDeviceOrientationLandscapeRight:      // Device oriented horizontally, home button on the left
			if (isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			break;
		case UIDeviceOrientationPortrait:            // Device oriented vertically, home button on the bottom
		default:
			exifOrientation = PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP;
			break;
	}
    
	imageOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:exifOrientation] forKey:CIDetectorImageOrientation];
	NSArray *features = [faceDetector featuresInImage:ciImage options:imageOptions];
	
    // get the clean aperture
    // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
    // that represents image data valid for display.
	CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sampleBuffer);
	CGRect clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/);
	
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		[self drawFaceBoxesForFeatures:features forVideoBox:clap orientation:curDeviceOrientation];
	});
}

//Close the video on dealloc
- (void)dealloc
{
	[self teardownAVCapture];
}

//Change the capture camera from front to back and vice...
-(void) setFrontCamera:(BOOL)isFront {
    AVCaptureDevicePosition desiredPosition;
	if (!isFront)
		desiredPosition = AVCaptureDevicePositionBack;
	else
		desiredPosition = AVCaptureDevicePositionFront;
	
	for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
		if ([d position] == desiredPosition) {
			[[previewLayer session] beginConfiguration];
			AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:d error:nil];
			for (AVCaptureInput *oldInput in [[previewLayer session] inputs]) {
				[[previewLayer session] removeInput:oldInput];
			}
			[[previewLayer session] addInput:input];
			[[previewLayer session] commitConfiguration];
			break;
		}
	}
	isUsingFrontFacingCamera = isFront;
}

// use front/back camera
- (IBAction)switchCameras:(id)sender
{
    [self setFrontCamera:!isUsingFrontFacingCamera];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Release any cached data, images, etc that aren't in use.
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    isUsingFrontFacingCamera = NO;
	[self setupAVCapture];
    
	NSDictionary *detectorOptions = [[NSDictionary alloc] initWithObjectsAndKeys:CIDetectorAccuracyLow, CIDetectorAccuracy, nil];
	faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace context:nil options:detectorOptions];

    //We start using the front camera
    [self setFrontCamera:YES];
    
    //Create the item selector view
    [itemSelectorViewController.view setFrame:CGRectMake(0, 480-168, 320, 168)];
    [self.view addSubview:itemSelectorViewController.view];
    itemSelectorViewController.delegate = self;
   
    //Init message layer and set in the center of screen
    self.faceIndicatorLayer = [[FaceIndicatorLayer alloc] initWithNibName:@"FaceIndicatorLayer" bundle:nil];
    
    self.faceIndicatorLayer.view.frame = CGRectMake(self.view.frame.size.width/2 - (self.faceIndicatorLayer.view.frame.size.width/2),
                                                    self.view.frame.size.height / 2 - (self.faceIndicatorLayer.view.frame.size.height / 2), 
                                                    self.faceIndicatorLayer.view.frame.size.width, self.faceIndicatorLayer.view.frame.size.height);
 
    [self.view addSubview: self.faceIndicatorLayer.view];
    [self.faceIndicatorLayer displayMessage:NO withText:nil];
}


-(void) itemSelected:(int)kItemType imageName:(NSString *)imgName {
    switch (kItemType) {
        case kItemTypeHat:
            [self removeLayer:kHatLayer];
            hat = [UIImage imageNamed:imgName];
            break;
        case kItemTypeSunglasses:
            [self removeLayer:kSunglassesLayer];
            sunglasses = [UIImage imageNamed:imgName];
            break;
        case kItemTypeMouth:
            [self removeLayer:kMouthLayer];
            mouth = [UIImage imageNamed:imgName];
            break;
        case kItemTypeMarc:
            [marc setImage:[UIImage imageNamed:imgName]];
            break;
        default:
            break;
    }
}

-(void) removeLayer:(NSString *)layerToClean {
    NSArray *sublayers = [NSArray arrayWithArray:[previewLayer sublayers]];
    
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
	
	// hide all the face layers
	for ( CALayer *layer in sublayers ) {
        if([[layer name] isEqualToString:layerToClean])
            [layer removeFromSuperlayer];
	}	
    [CATransaction commit];
}

-(void) clearMocks {
    [self removeLayer:kSunglassesLayer];
    [self removeLayer:kHatLayer];
    [self removeLayer:kMouthLayer];
    self.sunglasses = nil;
    self.hat = nil;
    self.mouth = nil;
    
    [marc setImage:[UIImage imageNamed:@"marc_corporatiu.png"]];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    [self becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
	return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

-(void) motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    
    if (event.type == UIEventSubtypeMotionShake) 
    {
        //If the user shakes, we put random items on the screen, for lazy boys
        [itemSelectorViewController getRandomItems];
    }   
    
}

/* Gets the size and position of the hat frame 
 depending on the face detected */
-(CGRect) getHatRectFromFace:(CIFaceFeature *)face isStill:(BOOL)still {
    CGRect faceRect = [face bounds];
    
    if(still) {
        return CGRectMake(faceRect.origin.x - (faceRect.size.width * 0.85),
                   faceRect.origin.y,
                   faceRect.size.width,
                   faceRect.size.width);
    } else {
        //We have to flip the face rect in preview mode...
        faceRect = [self flipRect:faceRect];
        return CGRectMake(faceRect.origin.x,
                                faceRect.origin.y - (faceRect.size.width * 0.85),
                                faceRect.size.width,
                                faceRect.size.width);
    }
}

-(CGRect) getSunglassesRectFromFace:(CIFaceFeature *)face isStill:(BOOL)still {
    
    float eyeCenterY = ((face.rightEyePosition.y - face.leftEyePosition.y) / 2) + face.leftEyePosition.y;
    
    CGPoint eyeCenter = CGPointMake(face.rightEyePosition.x, eyeCenterY);
    
    float glassesWidth = (face.rightEyePosition.y-face.leftEyePosition.y)*2;
    
    
    if(still) {
        return CGRectMake(face.leftEyePosition.x-(glassesWidth/2),
                          eyeCenterY-(glassesWidth/2),
                          glassesWidth,
                          glassesWidth);
    } else {
        return CGRectMake(eyeCenter.y - (glassesWidth / 2),
                          eyeCenter.x - (glassesWidth / 2),
                          glassesWidth,
                          glassesWidth);
    }
}

-(CGRect) getMouthRectFromFace:(CIFaceFeature *)face isStill:(BOOL)still {
    
    CGRect faceRect = [face bounds];
    
    float mouthSize = faceRect.size.width / 2;
    
    if(still) {
        return CGRectMake((face.mouthPosition.x-(mouthSize/2))+10, face.mouthPosition.y-(mouthSize/2), mouthSize, mouthSize);
    }
    CGRect mouthRect = CGRectMake((face.mouthPosition.y-(mouthSize/2)), (face.mouthPosition.x-(mouthSize/2))+10, mouthSize, mouthSize);
    
    return mouthRect;
}

-(CGRect) flipRect:(CGRect)rectToFlip {
    // flip preview width and height
    CGFloat temp = rectToFlip.size.width;
    rectToFlip.size.width = rectToFlip.size.height;
    rectToFlip.size.height = temp;
    temp = rectToFlip.origin.x;
    rectToFlip.origin.x = rectToFlip.origin.y;
    rectToFlip.origin.y = temp;
    return rectToFlip;
}

@end
