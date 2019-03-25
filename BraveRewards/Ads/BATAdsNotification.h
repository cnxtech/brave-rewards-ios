/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BATAdsConfirmationType) {
  BATAdsConfirmationTypeUnknown,  // = ads::ConfirmationType::UNKNOWN
  BATAdsConfirmationTypeClick,    // = ads::ConfirmationType::CLICK
  BATAdsConfirmationTypeDismiss,  // = ads::ConfirmationType::DISMISS
  BATAdsConfirmationTypeView,     // = ads::ConfirmationType::VIEW
  BATAdsConfirmationTypeLanded    // = ads::ConfirmationType::LANDED
} NS_SWIFT_NAME(ConfirmationType);

extern BATAdsConfirmationType BATAdsConfirmationTypeForString(NSString *string);

NS_SWIFT_NAME(AdsNotification)
@interface BATAdsNotification : NSObject
@property (nonatomic, readonly, copy) NSString *creativeSetID;
@property (nonatomic, readonly, copy) NSString *category;
@property (nonatomic, readonly, copy) NSString *advertiser;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly, copy) NSString *uuid;
@property (nonatomic, readonly) BATAdsConfirmationType confirmationType;
@end

NS_ASSUME_NONNULL_END
