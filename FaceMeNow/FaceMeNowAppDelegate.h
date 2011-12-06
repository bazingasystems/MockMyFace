//
//  FaceMeNowAppDelegate.h
//  FaceMeNow
//
//  Created by Jaume Cornadó on 10/11/11.
//  Copyright (c) 2011 Bazinga Systems. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "FBConnect.h"

@class FaceMeNowViewController;

@interface FaceMeNowAppDelegate : UIResponder <UIApplicationDelegate, FBSessionDelegate, FBRequestDelegate>

@property (strong, nonatomic) UIWindow *window;

@property (strong, nonatomic) FaceMeNowViewController *viewController;
@property (strong, nonatomic) Facebook *facebook;

-(void) postImageToFacebook: (UIImage*) image;

@end
