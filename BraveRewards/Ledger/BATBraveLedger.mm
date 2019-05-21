/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import <UIKit/UIKit.h>
#import "bat/ledger/ledger.h"

#import "Records+Private.h"
#import "BATPublisherInfo+Private.h"
#import "BATActivityInfoFilter+Private.h"

#import "BATBraveLedger.h"
#import "BATCommonOperations.h"
#import "NSURL+Extensions.h"

#import "NativeLedgerClient.h"
#import "NativeLedgerClientBridge.h"
#import "RewardsLogStream.h"
#import "CppTransformations.h"

#import <objc/runtime.h>

#import "BATLedgerDatabase.h"

#define BATLedgerReadonlyBridge(__type, __objc_getter, __cpp_getter) \
- (__type)__objc_getter { return ledger->__cpp_getter(); }

#define BATLedgerBridge(__type, __objc_getter, __objc_setter, __cpp_getter, __cpp_setter) \
- (__type)__objc_getter { return ledger->__cpp_getter(); } \
- (void)__objc_setter:(__type)newValue { ledger->__cpp_setter(newValue); }

#define BATClassLedgerBridge(__type, __objc_getter, __objc_setter, __cpp_var) \
+ (__type)__objc_getter { return ledger::__cpp_var; } \
+ (void)__objc_setter:(__type)newValue { ledger::__cpp_var = newValue; }

NSString * const BATBraveLedgerErrorDomain = @"BATBraveLedgerErrorDomain";

NS_INLINE ledger::ACTIVITY_MONTH BATGetPublisherMonth(NSDate *date) {
  const auto month = [[NSCalendar currentCalendar] component:NSCalendarUnitMonth fromDate:date];
  return (ledger::ACTIVITY_MONTH)month;
}

NS_INLINE int BATGetPublisherYear(NSDate *date) {
  return (int)[[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:date];
}

@interface BATBraveLedger () <NativeLedgerClientBridge> {
  NativeLedgerClient *ledgerClient;
  ledger::Ledger *ledger;
}
@property (nonatomic, copy) NSString *storagePath;
@property (nonatomic) BATWalletInfo *walletInfo;
@property (nonatomic) dispatch_queue_t stateWriteThread;
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *state;
@property (nonatomic) BATCommonOperations *commonOps;

@property (nonatomic) NSMutableArray<BATGrant *> *mPendingGrants;

/// Temporary blocks

@property (nonatomic, copy, nullable) void (^walletInitializedBlock)(const ledger::Result result);
@property (nonatomic, copy, nullable) void (^walletRecoveredBlock)(const ledger::Result result, const double balance, const std::vector<ledger::Grant> &grants);
@property (nonatomic, copy, nullable) void (^grantCaptchaBlock)(const std::string& image, const std::string& hint);

@end

@implementation BATBraveLedger

- (instancetype)initWithStateStoragePath:(NSString *)path
{
  if ((self = [super init])) {
    self.storagePath = path;
    self.commonOps = [[BATCommonOperations alloc] initWithStoragePath:path];
    self.state = [[NSMutableDictionary alloc] initWithContentsOfFile:self.randomStatePath] ?: [[NSMutableDictionary alloc] init];
    self.stateWriteThread = dispatch_queue_create("com.rewards.state", DISPATCH_QUEUE_SERIAL);
    
    ledgerClient = new NativeLedgerClient(self);
    ledger = ledger::Ledger::CreateInstance(ledgerClient);
    ledger->Initialize();
    
    // Add notifications for standard app foreground/background
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    if (self.walletCreated) {
      [self fetchWalletDetails:nil];
    }
  }
  return self;
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
  delete ledger;
  delete ledgerClient;
}

- (NSString *)randomStatePath
{
  return [self.storagePath stringByAppendingString:@"random_state.plist"];
}

#pragma mark - Global

BATClassLedgerBridge(BOOL, isDebug, setDebug, is_debug);
BATClassLedgerBridge(BOOL, isTesting, setTesting, is_testing);
BATClassLedgerBridge(BOOL, isProduction, setProduction, is_production);
BATClassLedgerBridge(int, reconcileTime, setReconcileTime, reconcile_time);
BATClassLedgerBridge(BOOL, useShortRetries, setUseShortRetries, short_retries);

#pragma mark - Wallet

BATLedgerReadonlyBridge(BOOL, isWalletCreated, IsWalletCreated)

- (void)createWallet:(void (^)(NSError * _Nullable))completion
{
  const auto __weak weakSelf = self;
  self.walletInitializedBlock = ^(const ledger::Result result) {
    const auto strongSelf = weakSelf;
    if (!strongSelf) { return; }
    NSError *error = nil;
    if (result != ledger::WALLET_CREATED) {
      std::map<ledger::Result, std::string> errorDescriptions {
        { ledger::Result::LEDGER_ERROR, "The wallet was already initialized" },
        { ledger::Result::BAD_REGISTRATION_RESPONSE, "Request credentials call failure or malformed data" },
        { ledger::Result::REGISTRATION_VERIFICATION_FAILED, "Missing master user token from registered persona" },
      };
      NSDictionary *userInfo = @{};
      const auto description = errorDescriptions[result];
      if (description.length() > 0) {
        userInfo = @{ NSLocalizedDescriptionKey: [NSString stringWithUTF8String:description.c_str()] };
      }
      error = [NSError errorWithDomain:BATBraveLedgerErrorDomain code:result userInfo:userInfo];
    }
    if (completion) {
      strongSelf.enabled = YES;
      strongSelf.autoContributeEnabled = YES;
      strongSelf.ads.enabled = YES;
      strongSelf.walletInitializedBlock = nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    }
  };
  // Results that can come from CreateWallet():
  //   - WALLET_CREATED: Good to go
  //   - LEDGER_ERROR: Already initialized
  //   - BAD_REGISTRATION_RESPONSE: Request credentials call failure or malformed data
  //   - REGISTRATION_VERIFICATION_FAILED: Missing master user token
  ledger->CreateWallet();
}

- (void)onWalletInitialized:(ledger::Result)result
{
  if (self.walletInitializedBlock) {
    self.walletInitializedBlock(result);
  }
}

- (void)fetchWalletDetails:(void (^)(BATWalletInfo *))completion
{
  ledger->FetchWalletProperties(^(ledger::Result result, std::unique_ptr<ledger::WalletInfo> info) {
    const auto walletInfo = *info.get();
    dispatch_async(dispatch_get_main_queue(), ^{
      [self onWalletProperties:result arg1:std::make_unique<ledger::WalletInfo>(walletInfo)];
      if (completion) {
        completion(self.walletInfo);
      }
    });
  });
}

- (void)onWalletProperties:(ledger::Result)result arg1:(std::unique_ptr<ledger::WalletInfo>)arg1
{
  if (result == ledger::LEDGER_OK) {
    const auto walletInfo = arg1.get();
    if (walletInfo != nullptr) {
      self.walletInfo = [[BATWalletInfo alloc] initWithWalletInfo:*walletInfo];
    } else {
      self.walletInfo = nil;
    }
  }
}

- (NSString *)walletPassphrase
{
  if (ledger->IsWalletCreated()) {
    return [NSString stringWithUTF8String:ledger->GetWalletPassphrase().c_str()];
  }
  return nil;
}

- (void)recoverWalletUsingPassphrase:(NSString *)passphrase completion:(void (^)(NSError *_Nullable))completion
{
  const auto __weak weakSelf = self;
  self.walletRecoveredBlock = ^(const ledger::Result result, const double balance, const std::vector<ledger::Grant> &grants) {
    const auto strongSelf = weakSelf;
    if (!strongSelf) { return; }
    NSError *error = nil;
    if (result != ledger::LEDGER_OK) {
      std::map<ledger::Result, std::string> errorDescriptions {
        { ledger::Result::LEDGER_ERROR, "The recovery failed" },
      };
      NSDictionary *userInfo = @{};
      const auto description = errorDescriptions[result];
      if (description.length() > 0) {
        userInfo = @{ NSLocalizedDescriptionKey: [NSString stringWithUTF8String:description.c_str()] };
      }
      error = [NSError errorWithDomain:BATBraveLedgerErrorDomain code:result userInfo:userInfo];
    }
    if (completion) {
      completion(error);
    }
    strongSelf.walletRecoveredBlock = nil;
  };
  // Results that can come from CreateWallet():
  //   - LEDGER_OK: Good to go
  //   - LEDGER_ERROR: Recovery failed
  ledger->RecoverWallet(std::string(passphrase.UTF8String));
}

- (void)onRecoverWallet:(ledger::Result)result balance:(double)balance grants:(const std::vector<ledger::Grant> &)grants
{
  if (self.walletRecoveredBlock) {
    self.walletRecoveredBlock(result, balance, grants);
  }
}

- (NSString *)BATAddress
{
  if (ledger->IsWalletCreated()) {
    return [NSString stringWithUTF8String:ledger->GetBATAddress().c_str()];
  }
  return nil;
}

- (NSString *)BTCAddress
{
  if (ledger->IsWalletCreated()) {
    return [NSString stringWithUTF8String:ledger->GetBTCAddress().c_str()];
  }
  return nil;
}

- (NSString *)ETHAddress
{
  if (ledger->IsWalletCreated()) {
    return [NSString stringWithUTF8String:ledger->GetETHAddress().c_str()];
  }
  return nil;
}

- (NSString *)LTCAddress
{
  if (ledger->IsWalletCreated()) {
    return [NSString stringWithUTF8String:ledger->GetLTCAddress().c_str()];
  }
  return nil;
}

- (NSDictionary<NSString *, NSString *> *)addresses
{
  if (ledger->IsWalletCreated()) {
    return NSDictionaryFromMap(ledger->GetAddresses());
  }
  return nil;
}

- (void)addressesForPaymentId:(void (^)(NSDictionary<NSString *,NSString *> * _Nonnull))completion
{
  ledger->GetAddressesForPaymentId(^(std::map<std::string, std::string> addresses){
    completion(NSDictionaryFromMap(addresses));
  });
}

BATLedgerReadonlyBridge(double, balance, GetBalance);

BATLedgerReadonlyBridge(double, defaultContributionAmount, GetDefaultContributionAmount);

BATLedgerReadonlyBridge(BOOL, hasSufficientBalanceToReconcile, HasSufficientBalanceToReconcile);

#pragma mark - Publishers

- (void)publisherInfoForId:(NSString *)publisherId completion:(void (^)(BATPublisherInfo * _Nullable))completion
{
  ledger->GetPublisherInfo(std::string(publisherId.UTF8String), ^(ledger::Result result, std::unique_ptr<ledger::PublisherInfo> info) {
    if (result == ledger::LEDGER_OK) {
      const auto& publisherInfo = info.get();
      if (publisherInfo != nullptr) {
        completion([[BATPublisherInfo alloc] initWithPublisherInfo:*publisherInfo]);
      }
    } else {
      completion(nil);
    }
  });
}

- (void)listActivityInfoFromStart:(unsigned int)start
                            limit:(unsigned int)limit
                           filter:(BATActivityInfoFilter *)filter
                       completion:(void (^)(NSArray<BATPublisherInfo *> *))completion
{
  const auto cppFilter = filter ? filter.cppObj : ledger::ActivityInfoFilter();
  ledger->GetActivityInfoList(start, limit, cppFilter, ^(const ledger::PublisherInfoList& list, uint32_t nextRecord) {
    const auto publishers = NSArrayFromVector(list, ^BATPublisherInfo *(const ledger::PublisherInfo& info){
      return [[BATPublisherInfo alloc] initWithPublisherInfo:info];
    });
    completion(publishers);
  });
}

- (void)activityInfoWithFilter:(nullable BATActivityInfoFilter *)filter completion:(void (^)(BATPublisherInfo * _Nullable info))completion
{
  const auto cppFilter = filter ? filter.cppObj : ledger::ActivityInfoFilter();
  ledger->GetActivityInfo(cppFilter, ^(ledger::Result result, std::unique_ptr<ledger::PublisherInfo> info) {
    if (result == ledger::LEDGER_OK) {
      const auto& publisherInfo = info.get();
      if (publisherInfo != nullptr) {
        completion([[BATPublisherInfo alloc] initWithPublisherInfo:*publisherInfo]);
      }
    } else {
      completion(nil);
    }
  });
}

- (void)publisherActivityFromURL:(NSURL *)URL
                      faviconURL:(NSURL *)faviconURL
                        windowID:(uint64_t)windowID
                   publisherBlob:(NSString *)publisherBlob
{
  auto visitData = [self visitDataForURL:URL tabId:0];
  visitData.favicon_url = std::string(faviconURL.absoluteString.UTF8String);
  ledger->GetPublisherActivityFromUrl(windowID, visitData, std::string(publisherBlob.UTF8String));
}

- (void)mediaPublisherInfoForMediaKey:(NSString *)mediaKey completion:(void (^)(BATPublisherInfo * _Nullable))completion
{
  ledger->GetMediaPublisherInfo(std::string(mediaKey.UTF8String), ^(ledger::Result result, std::unique_ptr<ledger::PublisherInfo> info) {
    if (result == ledger::LEDGER_OK) {
      const auto& publisherInfo = info.get();
      if (publisherInfo != nullptr) {
        completion([[BATPublisherInfo alloc] initWithPublisherInfo:*publisherInfo]);
      }
    } else {
      completion(nil);
    }
  });
}

- (void)updateMediaPublisherInfo:(NSString *)publisherId mediaKey:(NSString *)mediaKey
{
  ledger->SetMediaPublisherInfo(std::string(publisherId.UTF8String), std::string(mediaKey.UTF8String));
}

- (void)updatePublisherExclusionState:(NSString *)publisherId state:(BATPublisherExclude)state
{
  ledger->SetPublisherExclude(std::string(publisherId.UTF8String), (ledger::PUBLISHER_EXCLUDE)state);
}

- (void)restoreAllExcludedPublishers
{
  ledger->RestorePublishers();
}

- (NSUInteger)numberOfExcludedPublishers
{
  return [BATLedgerDatabase excludedPublishersCount];
}

- (void)publisherBannerForId:(NSString *)publisherId completion:(void (^)(BATPublisherBanner * _Nullable banner))completion
{
  ledger->GetPublisherBanner(std::string(publisherId.UTF8String), ^(std::unique_ptr<ledger::PublisherBanner> banner) {
    auto bridgedBanner = banner.get() != nullptr ? [[BATPublisherBanner alloc] initWithPublisherBanner:*banner.get()] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(bridgedBanner);
    });
  });
}

#pragma mark - Tips

- (void)listRecurringTips:(void (^)(NSArray<BATPublisherInfo *> *))completion
{
  ledger->GetRecurringTips(^(const ledger::PublisherInfoList& list, uint32_t){
    const auto publishers = NSArrayFromVector(list, ^BATPublisherInfo *(const ledger::PublisherInfo& info){
      return [[BATPublisherInfo alloc] initWithPublisherInfo:info];
    });
    completion(publishers);
  });
}

- (void)addRecurringTipToPublisherWithId:(NSString *)publisherId amount:(double)amount
{
  ledger->AddRecurringPayment(std::string(publisherId.UTF8String), amount);
}

- (void)removeRecurringTipForPublisherWithId:(NSString *)publisherId
{
  ledger->RemoveRecurringTip(std::string(publisherId.UTF8String));
}

- (void)listOneTimeTips:(void (^)(NSArray<BATPublisherInfo *> *))completion
{
  ledger->GetOneTimeTips(^(const ledger::PublisherInfoList& list, uint32_t){
    const auto publishers = NSArrayFromVector(list, ^BATPublisherInfo *(const ledger::PublisherInfo& info){
      return [[BATPublisherInfo alloc] initWithPublisherInfo:info];
    });
    completion(publishers);
  });
}

- (void)tipPublisherDirectly:(BATPublisherInfo *)publisher amount:(int)amount currency:(NSString *)currency
{
  ledger->DoDirectDonation(publisher.cppObj, amount, std::string(currency.UTF8String));
}

#pragma mark -

- (NSArray<BATContributionInfo *> *)recurringContributions
{
  const auto contributions = ledger->GetRecurringDonationPublisherInfo();
  return NSArrayFromVector(contributions, ^BATContributionInfo *(const ledger::ContributionInfo& info) {
    return [[BATContributionInfo alloc] initWithContributionInfo:info];
  });
}

#pragma mark - Grants

- (NSArray<BATGrant *> *)pendingGrants
{
  return [self.mPendingGrants copy];
}

- (void)fetchAvailableGrantsForLanguage:(NSString *)language paymentId:(NSString *)paymentId
{
  [self.mPendingGrants removeAllObjects];
  // FetchGrants callbacks:
  //  - OnWalletProperties (CORRUPTED_WALLET)
  //  - OnGrant (GRANT_NOT_FOUND, LEDGER_ERROR, LEDGER_OK)
  // Calls `OnGrant` for each grant found (...)
  ledger->FetchGrants(std::string(language.UTF8String),
                      std::string(paymentId.UTF8String));
}

- (void)onGrant:(ledger::Result)result grant:(const ledger::Grant &)grant
{
  if (result == ledger::LEDGER_OK) {
    [self.mPendingGrants addObject:[[BATGrant alloc] initWithGrant:grant]];
  }
}

- (void)grantCaptchaForPromotionId:(NSString *)promoID promotionType:(NSString *)promotionType completion:(void (^)(NSString * _Nonnull, NSString * _Nonnull))completion
{
  const auto __weak weakSelf = self;
  self.grantCaptchaBlock = ^(const std::string &image, const std::string &hint) {
    weakSelf.grantCaptchaBlock = nil;
    completion([NSString stringWithUTF8String:image.c_str()],
               [NSString stringWithUTF8String:hint.c_str()]);
  };
  ledger->GetGrantCaptcha(std::string(promoID.UTF8String),
                          std::string(promotionType.UTF8String));
}

- (void)onGrantCaptcha:(const std::string &)image hint:(const std::string &)hint
{
  if (self.grantCaptchaBlock) {
    self.grantCaptchaBlock(image, hint);
  }
}

- (void)getGrantCaptcha:(const std::string &)promotion_id promotionType:(const std::string &)promotion_type
{
  ledger->GetGrantCaptcha(promotion_id, promotion_type);
}

- (void)fetchGrants:(const std::string &)lang paymentId:(const std::string &)paymentId
{
  ledger->FetchGrants(lang, paymentId);
}

- (void)solveGrantCaptchWithPromotionId:(NSString *)promotionId solution:(NSString *)solution
{
  ledger->SolveGrantCaptcha(std::string(solution.UTF8String),
                            std::string(promotionId.UTF8String));
}

- (void)onGrantFinish:(ledger::Result)result grant:(const ledger::Grant &)grant
{
  ledger::BalanceReportInfo report_info;
  auto now = [NSDate date];
  if (result == ledger::LEDGER_OK) {
    ledger::ReportType report_type = grant.type == "ads" ? ledger::ADS : ledger::GRANT;
    ledger->SetBalanceReportItem(BATGetPublisherMonth(now),
                                 BATGetPublisherYear(now),
                                 report_type,
                                 grant.probi);
  }
  // TODO:
  // brave-core notifies that the balance report has been updated here.
  // brave-core notifies that ongrantfinished was called here
}

#pragma mark - History

- (NSDictionary<NSString *, BATBalanceReportInfo *> *)balanceReports
{
  const auto reports = ledger->GetAllBalanceReports();
  return NSDictionaryFromMap(reports, ^BATBalanceReportInfo *(ledger::BalanceReportInfo info){
    return [[BATBalanceReportInfo alloc] initWithBalanceReportInfo:info];
  });
}

- (BATBalanceReportInfo *)balanceReportForMonth:(BATActivityMonth)month year:(int)year
{
  ledger::BalanceReportInfo info;
  ledger->GetBalanceReport((ledger::ACTIVITY_MONTH)month, year, &info);
  return [[BATBalanceReportInfo alloc] initWithBalanceReportInfo:info];
}

- (BATAutoContributeProps *)autoContributeProps
{
  ledger::AutoContributeProps props;
  ledger->GetAutoContributeProps(&props);
  return [[BATAutoContributeProps alloc] initWithAutoContributeProps:props];
}

#pragma mark - Reconcile

- (void)onReconcileComplete:(ledger::Result)result viewingId:(const std::string &)viewing_id category:(ledger::REWARDS_CATEGORY)category probi:(const std::string &)probi
{
  if (result == ledger::Result::LEDGER_OK) {
    const auto now = [NSDate date];
    const auto nowTimestamp = [now timeIntervalSince1970];
    
    [self fetchWalletDetails:nil];
    
    if (category == ledger::REWARDS_CATEGORY::RECURRING_TIP) {
      //      MaybeShowNotificationTipsPaid();
    }
    
    ledger->OnReconcileCompleteSuccess(viewing_id,
                                       category,
                                       probi,
                                       BATGetPublisherMonth(now),
                                       BATGetPublisherYear(now),
                                       nowTimestamp);
  }
  
  // TODO:
  // brave-core notifies that the balance report has been updated here.
  // brave-core notifies all observers that reconciles completed here.
}

#pragma mark - Misc

+ (bool)isMediaURL:(NSURL *)url firstPartyURL:(NSURL *)firstPartyURL referrerURL:(NSURL *)referrerURL
{
  return ledger::Ledger::IsMediaLink(std::string(url.absoluteString.UTF8String),
                                     std::string(firstPartyURL.absoluteString.UTF8String),
                                     std::string(referrerURL.absoluteString.UTF8String));
}

- (NSString *)encodedURI:(NSString *)uri
{
  const auto encoded = ledger->URIEncode(std::string(uri.UTF8String));
  return [NSString stringWithUTF8String:encoded.c_str()];
}

- (BATRewardsInternalsInfo *)rewardsInternalInfo
{
  ledger::RewardsInternalsInfo info;
  ledger->GetRewardsInternalsInfo(&info);
  return [[BATRewardsInternalsInfo alloc] initWithRewardsInternalsInfo:info];
}

- (void)loadNicewareList:(ledger::GetNicewareListCallback)callback
{
  NSError *error;
  const auto bundle = [NSBundle bundleForClass:[BATBraveLedger class]];
  const auto path = [bundle pathForResource:@"wordlist" ofType:nil];
  const auto contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
  if (error || contents.length == 0) {
    callback(ledger::Result::LEDGER_ERROR, "");
  } else {
    callback(ledger::Result::LEDGER_OK, std::string(contents.UTF8String));
  }
}

#pragma mark - Reporting

- (const ledger::VisitData)visitDataForURL:(NSURL *)url tabId:(UInt32)tabId
{
  const auto normalizedHost = std::string(url.bat_normalizedHost.UTF8String);
  ledger::VisitData visit(normalizedHost,
                          std::string(url.host.UTF8String),
                          std::string(url.path.UTF8String),
                          tabId,
                          normalizedHost,
                          std::string(url.absoluteString.UTF8String),
                          "",
                          "");
  return visit;
}

- (void)setSelectedTabId:(UInt32)selectedTabId
{
  if (selectedTabId != 0) {
    ledger->OnHide(_selectedTabId, [[NSDate date] timeIntervalSince1970]);
  }
  _selectedTabId = selectedTabId;
  ledger->OnShow(_selectedTabId, [[NSDate date] timeIntervalSince1970]);
}

- (void)applicationDidBecomeActive
{
  ledger->OnForeground(self.selectedTabId, [[NSDate date] timeIntervalSince1970]);
}

- (void)applicationDidBackground
{
  ledger->OnBackground(self.selectedTabId, [[NSDate date] timeIntervalSince1970]);
}

- (void)reportLoadedPageWithURL:(NSURL *)url tabId:(UInt32)tabId
{
  const auto visit = [self visitDataForURL:url tabId:tabId];
  ledger->OnLoad(visit, [[NSDate date] timeIntervalSince1970]);
}

- (void)reportXHRLoad:(NSURL *)url tabId:(UInt32)tabId firstPartyURL:(NSURL *)firstPartyURL referrerURL:(NSURL *)referrerURL
{
  std::map<std::string, std::string> partsMap;
  const auto urlComponents = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
  for (NSURLQueryItem *item in urlComponents.queryItems) {
    partsMap[std::string(item.name.UTF8String)] = std::string(item.value.UTF8String);
  }
  
  ledger::VisitData visit("", "",
                          std::string(url.absoluteString.UTF8String),
                          tabId,
                          "", "", "", "");
  
  ledger->OnXHRLoad(tabId,
                    std::string(url.absoluteString.UTF8String),
                    partsMap,
                    std::string(firstPartyURL.absoluteString.UTF8String),
                    std::string(referrerURL.absoluteString.UTF8String),
                    visit);
}

- (void)reportPostData:(NSData *)postData url:(NSURL *)url tabId:(UInt32)tabId firstPartyURL:(NSURL *)firstPartyURL referrerURL:(NSURL *)referrerURL
{
  ledger::VisitData visit("", "",
                          std::string(url.absoluteString.UTF8String),
                          tabId,
                          "", "", "", "");
  
  const auto postDataString = [[NSString alloc] initWithData:postData encoding:NSUTF8StringEncoding];
  
  ledger->OnPostData(std::string(url.absoluteString.UTF8String),
                     std::string(firstPartyURL.absoluteString.UTF8String),
                     std::string(referrerURL.absoluteString.UTF8String),
                     std::string(postDataString.UTF8String),
                     visit);
}

- (void)reportMediaStartedWithTabId:(UInt32)tabId
{
  ledger->OnMediaStart(tabId, [[NSDate date] timeIntervalSince1970]);
}

- (void)reportMediaStoppedWithTabId:(UInt32)tabId
{
  ledger->OnMediaStop(tabId, [[NSDate date] timeIntervalSince1970]);
}

- (void)reportTabClosedWithTabId:(UInt32)tabId
{
  ledger->OnUnload(tabId, [[NSDate date] timeIntervalSince1970]);
}

#pragma mark - Preferences

BATLedgerBridge(BOOL,
                isEnabled, setEnabled,
                GetRewardsMainEnabled, SetRewardsMainEnabled);

BATLedgerBridge(UInt64,
                minimumVisitDuration, setMinimumVisitDuration,
                GetPublisherMinVisitTime, SetPublisherMinVisitTime);

BATLedgerBridge(UInt32,
                minimumNumberOfVisits, setMinimumNumberOfVisits,
                GetPublisherMinVisits, SetPublisherMinVisits);

BATLedgerBridge(BOOL,
                allowUnverifiedPublishers, setAllowUnverifiedPublishers,
                GetPublisherAllowNonVerified, SetPublisherAllowNonVerified);

BATLedgerBridge(BOOL,
                allowVideoContributions, setAllowVideoContributions,
                GetPublisherAllowVideos, SetPublisherAllowVideos);

BATLedgerReadonlyBridge(double, contributionAmount, GetContributionAmount);

- (void)setContributionAmount:(double)contributionAmount
{
  ledger->SetUserChangedContribution();
  ledger->SetContributionAmount(contributionAmount);
}

BATLedgerBridge(BOOL,
                isAutoContributeEnabled, setAutoContributeEnabled,
                GetAutoContribute, SetAutoContribute);

#pragma mark - Ads & Confirmations

- (void)adsDetailsForCurrentCycle:(void (^)(NSInteger adsReceived, double estimatedEarnings))completion;
{
  ledger->GetTransactionHistoryForThisCycle(^(std::unique_ptr<ledger::TransactionsInfo> list) {
    if (list == nullptr || list->transactions.empty()) {
      completion(0, 0.0);
    } else {
      int adsReceived = 0;
      double estimatedEarnings = 0.0;
      
      for (const auto& transaction : list->transactions) {
        if (transaction.estimated_redemption_value == 0.0) {
          continue;
        }
        
        adsReceived++;
        estimatedEarnings += transaction.estimated_redemption_value;
      }
      
      completion((NSInteger)adsReceived, estimatedEarnings);
    }
  });
}

- (void)setConfirmationsIsReady:(const bool)is_ready
{
   [self.ads setConfirmationsIsReady:is_ready];
}

- (void)confirmationsTransactionHistoryDidChange
{
  // TODO:
  // brave-core forwards this to observers
}

#pragma mark - Notifications

// TODO: Add notification logic here

#pragma mark - State

- (void)loadLedgerState:(ledger::LedgerCallbackHandler *)handler
{
  const auto contents = [self.commonOps loadContentsFromFileWithName:"ledger_state.json"];
  if (contents.length() > 0) {
    handler->OnLedgerStateLoaded(ledger::LEDGER_OK, contents);
  } else {
    handler->OnLedgerStateLoaded(ledger::LEDGER_ERROR, contents);
  }
}

- (void)saveLedgerState:(const std::string &)ledger_state handler:(ledger::LedgerCallbackHandler *)handler
{
  const auto result = [self.commonOps saveContents:ledger_state name:"ledger_state.json"];
  handler->OnLedgerStateSaved(result ? ledger::LEDGER_OK : ledger::LEDGER_ERROR);
}

- (void)loadPublisherState:(ledger::LedgerCallbackHandler *)handler
{
  const auto contents = [self.commonOps loadContentsFromFileWithName:"publisher_state.json"];
  if (contents.length() > 0) {
    handler->OnPublisherStateLoaded(ledger::LEDGER_OK, contents);
  } else {
    handler->OnPublisherStateLoaded(ledger::LEDGER_ERROR, contents);
  }
}

- (void)savePublisherState:(const std::string &)publisher_state handler:(ledger::LedgerCallbackHandler *)handler
{
  const auto result = [self.commonOps saveContents:publisher_state name:"publisher_state.json"];
  handler->OnPublisherStateSaved(result ? ledger::LEDGER_OK : ledger::LEDGER_ERROR);
}

- (void)loadPublisherList:(ledger::LedgerCallbackHandler *)handler
{
  const auto contents = [self.commonOps loadContentsFromFileWithName:"publisher_list.json"];
  if (contents.length() > 0) {
    handler->OnPublisherListLoaded(ledger::LEDGER_OK, contents);
  } else {
    handler->OnPublisherListLoaded(ledger::LEDGER_ERROR, contents);
  }
}

- (void)savePublishersList:(const std::string &)publisher_state handler:(ledger::LedgerCallbackHandler *)handler
{
  const auto result = [self.commonOps saveContents:publisher_state name:"publisher_list.json"];
  handler->OnPublishersListSaved(result ? ledger::LEDGER_OK : ledger::LEDGER_ERROR);
}

- (void)loadState:(const std::string &)name callback:(ledger::OnLoadCallback)callback
{
  const auto key = [NSString stringWithUTF8String:name.c_str()];
  const auto value = self.state[key];
  if (value) {
    callback(ledger::LEDGER_OK, std::string(value.UTF8String));
  } else {
    callback(ledger::LEDGER_ERROR, "");
  }
}

- (void)resetState:(const std::string &)name callback:(ledger::OnResetCallback)callback
{
  const auto key = [NSString stringWithUTF8String:name.c_str()];
  self.state[key] = nil;
  callback(ledger::LEDGER_OK);
  dispatch_async(self.stateWriteThread, ^{
    [self.state writeToFile:self.randomStatePath atomically:YES];
  });
}

- (void)saveState:(const std::string &)name value:(const std::string &)value callback:(ledger::OnSaveCallback)callback
{
  const auto key = [NSString stringWithUTF8String:name.c_str()];
  self.state[key] = [NSString stringWithUTF8String:value.c_str()];
  callback(ledger::LEDGER_OK);
  dispatch_async(self.stateWriteThread, ^{
    [self.state writeToFile:self.randomStatePath atomically:YES];
  });
}

#pragma mark - Timers

- (void)setTimer:(uint64_t)time_offset timerId:(uint32_t *)timer_id
{
  const auto __weak weakSelf = self;
  const auto createdTimerID = [self.commonOps createTimerWithOffset:time_offset timerFired:^(uint32_t firedTimerID) {
    const auto strongSelf = weakSelf;
    if (!strongSelf.commonOps) { return; }
    strongSelf->ledger->OnTimer(firedTimerID);
  }];
  *timer_id = createdTimerID;
}

- (void)killTimer:(const uint32_t)timer_id
{
  [self.commonOps removeTimerWithID:timer_id];
}

#pragma mark - Network

- (void)loadURL:(const std::string &)url headers:(const std::vector<std::string> &)headers content:(const std::string &)content contentType:(const std::string &)contentType method:(const ledger::URL_METHOD)method callback:(ledger::LoadURLCallback)callback
{
  std::map<ledger::URL_METHOD, std::string> methodMap {
    {ledger::GET, "GET"},
    {ledger::POST, "POST"},
    {ledger::PUT, "PUT"}
  };
  return [self.commonOps loadURLRequest:url headers:headers content:content content_type:contentType method:methodMap[method] callback:^(int statusCode, const std::string &response, const std::map<std::string, std::string> &headers) {
    callback(statusCode, response, headers);
  }];
}

- (std::string)URIEncode:(const std::string &)value
{
  const auto allowedCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
  [allowedCharacters addCharactersInString:@"-._~"];
  const auto string = [NSString stringWithUTF8String:value.c_str()];
  const auto encoded = [string stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
  return std::string(encoded.UTF8String);
}

- (std::string)generateGUID
{
  return [self.commonOps generateUUID];
}

- (void)fetchFavIcon:(const std::string &)url faviconKey:(const std::string &)favicon_key callback:(ledger::FetchIconCallback)callback
{
  // TODO: Should probably call to client to get this
}

#pragma mark - Logging

- (std::unique_ptr<ledger::LogStream>)verboseLog:(const char *)file line:(int)line vlogLevel:(int)vlog_level
{
  return std::make_unique<RewardsLogStream>(file, line, (ledger::LogLevel)vlog_level);
}

- (std::unique_ptr<ledger::LogStream>)log:(const char *)file line:(int)line logLevel:(const ledger::LogLevel)log_level
{
  return std::make_unique<RewardsLogStream>(file, line, log_level);
}

#pragma mark - Publisher Database

// TODO: Implement the rest of these methods

- (void)handlePublisherListing:(NSArray<BATPublisherInfo *> *)publishers start:(uint32_t)start limit:(uint32_t)limit callback:(ledger::PublisherInfoListCallback)callback
{
  uint32_t next_record = 0;
  if (publishers.count == limit) {
    next_record = start + limit + 1;
  }
  
  const auto vectorPublishers = VectorFromNSArray(publishers, ^ledger::PublisherInfo(BATPublisherInfo *info){
    return info.cppObj;
  });
  callback(std::cref(vectorPublishers), next_record);
}

- (void)getActivityInfoList:(uint32_t)start limit:(uint32_t)limit filter:(ledger::ActivityInfoFilter)filter callback:(ledger::PublisherInfoListCallback)callback
{
  const auto filter_ = [[BATActivityInfoFilter alloc] initWithActivityInfoFilter:filter];
  const auto publishers = [BATLedgerDatabase publishersWithActivityFromOffset:start limit:limit filter:filter_];
  
  [self handlePublisherListing:publishers start:start limit:limit callback:callback];
}

- (void)getExcludedPublishersNumberDB:(ledger::GetExcludedPublishersNumberDBCallback)callback
{
  const auto count = [BATLedgerDatabase excludedPublishersCount];
  callback((UInt32)count);
}

- (void)getOneTimeTips:(ledger::PublisherInfoListCallback)callback
{
  const auto now = [NSDate date];
  const auto publishers = [BATLedgerDatabase oneTimeTipsPublishersForMonth: (BATActivityMonth)BATGetPublisherMonth(now)
                                                        year:BATGetPublisherYear(now)];

  [self handlePublisherListing:publishers start:0 limit:0 callback:callback];
}

- (void)getRecurringTips:(ledger::PublisherInfoListCallback)callback
{
  const auto publishers = [BATLedgerDatabase recurringTips];
  
  [self handlePublisherListing:publishers start:0 limit:0 callback:callback];
}

- (void)loadActivityInfo:(ledger::ActivityInfoFilter)filter
                callback:(ledger::PublisherInfoCallback)callback
{
  const auto filter_ = [[BATActivityInfoFilter alloc] initWithActivityInfoFilter:filter];
  // set limit to 2 to make sure there is only 1 valid result for the filter
  const auto publishers = [BATLedgerDatabase publishersWithActivityFromOffset:0 limit:2 filter:filter_];
  
  [self handlePublisherListing:publishers start:0 limit:2 callback:^(const ledger::PublisherInfoList& list, uint32_t) {
    // activity info not found
    if (list.size() == 0) {
      // we need to try to get at least publisher info in this case
      // this way we preserve publisher info
      const auto publisherID = [NSString stringWithUTF8String:filter.id.c_str()];
      const auto info = [BATLedgerDatabase publisherInfoWithPublisherID:publisherID];
      if (info) {
        callback(ledger::Result::LEDGER_OK, std::make_unique<ledger::PublisherInfo>(info.cppObj));
      } else {
        // This part diverges from brave-core. brave-core actually goes into an infinite loop here?
        // Hope im missing something on their side where they don't even call this method unless
        // there's a publisher with that ID in the ActivityInfo and PublisherInfo table...
        callback(ledger::Result::NOT_FOUND, nullptr);
      }
    } else if (list.size() > 1) {
      callback(ledger::Result::TOO_MANY_RESULTS, std::unique_ptr<ledger::PublisherInfo>());
    } else {
      callback(ledger::Result::LEDGER_OK, std::make_unique<ledger::PublisherInfo>(list[0]));
    }
  }];
}

- (void)loadMediaPublisherInfo:(const std::string &)media_key
                      callback:(ledger::PublisherInfoCallback)callback
{
  const auto mediaKey = [NSString stringWithUTF8String:media_key.c_str()];
  const auto publisher = [BATLedgerDatabase mediaPublisherInfoWithMediaKey:mediaKey];
  if (publisher) {
    callback(ledger::Result::LEDGER_OK, std::make_unique<ledger::PublisherInfo>(publisher.cppObj));
  } else {
    callback(ledger::Result::LEDGER_ERROR, nullptr);
  }
}

- (void)loadPanelPublisherInfo:(ledger::ActivityInfoFilter)filter callback:(ledger::PublisherInfoCallback)callback
{
  const auto filter_ = [[BATActivityInfoFilter alloc] initWithActivityInfoFilter:filter];
  const auto publisher = [BATLedgerDatabase panelPublisherWithFilter:filter_];
  if (publisher) {
    callback(ledger::Result::LEDGER_OK, std::make_unique<ledger::PublisherInfo>(publisher.cppObj));
  } else {
    callback(ledger::Result::LEDGER_ERROR, nullptr);
  }
}

- (void)loadPublisherInfo:(const std::string &)publisher_key callback:(ledger::PublisherInfoCallback)callback
{
  const auto publisherID = [NSString stringWithUTF8String:publisher_key.c_str()];
  const auto publisher = [BATLedgerDatabase publisherInfoWithPublisherID:publisherID];
  if (publisher) {
    callback(ledger::Result::LEDGER_OK, std::make_unique<ledger::PublisherInfo>(publisher.cppObj));
  } else {
    callback(ledger::Result::LEDGER_ERROR, nullptr);
  }
}

- (void)onExcludedSitesChanged:(const std::string &)publisher_id exclude:(ledger::PUBLISHER_EXCLUDE)exclude
{
  bool excluded = exclude == ledger::PUBLISHER_EXCLUDE::EXCLUDED;
  
  if (excluded) {
    const auto stamp = ledger->GetReconcileStamp();
    const auto publisherID = [NSString stringWithUTF8String:publisher_id.c_str()];
    [BATLedgerDatabase deleteActivityInfoWithPublisherID:publisherID
                                          reconcileStamp:stamp];
  }
  
  // TODO:
//  for (auto& observer : observers_) {
//    observer.OnExcludedSitesChanged(this, publisher_id, excluded);
//  }
}

- (void)onPanelPublisherInfo:(ledger::Result)result arg1:(std::unique_ptr<ledger::PublisherInfo>)arg1 windowId:(uint64_t)windowId
{
  if (result != ledger::Result::LEDGER_OK &&
      result != ledger::Result::NOT_FOUND) {
    return;
  }
  
  // TODO:
//  for (auto& observer : private_observers_) {
//    observer.OnPanelPublisherInfo(this,
//                                  result,
//                                  std::move(info),
//                                  windowId);
//  }
}

- (void)onRemoveRecurring:(const std::string &)publisher_key callback:(ledger::RecurringRemoveCallback)callback
{
  const auto publisherID = [NSString stringWithUTF8String:publisher_key.c_str()];
  const auto success = [BATLedgerDatabase removeRecurringTipWithPublisherID:publisherID];
  callback(success ? ledger::Result::LEDGER_OK : ledger::Result::LEDGER_ERROR);
}

- (void)onRestorePublishers:(ledger::OnRestoreCallback)callback
{
  [BATLedgerDatabase restoreExcludedPublishers];
  callback(ledger::Result::LEDGER_OK);
}

- (void)saveActivityInfo:(std::unique_ptr<ledger::PublisherInfo>)publisher_info callback:(ledger::PublisherInfoCallback)callback
{
  const auto info = publisher_info.get();
  if (info != nullptr) {
    const auto publisher = [[BATPublisherInfo alloc] initWithPublisherInfo:*info];
    [BATLedgerDatabase insertOrUpdateActivityInfoFromPublisher:publisher];
    callback(ledger::Result::LEDGER_OK, std::move(publisher_info));
  } else {
    callback(ledger::Result::LEDGER_ERROR, nullptr);
  }
}

- (void)saveContributionInfo:(const std::string &)probi month:(const int)month year:(const int)year date:(const uint32_t)date publisherKey:(const std::string &)publisher_key category:(const ledger::REWARDS_CATEGORY)category
{
  [BATLedgerDatabase insertContributionInfo:[NSString stringWithUTF8String:probi.c_str()]
                                      month:month
                                       year:year
                                       date:date
                               publisherKey:[NSString stringWithUTF8String:publisher_key.c_str()]
                                   category:(BATRewardsCategory)category];
}

- (void)saveMediaPublisherInfo:(const std::string &)media_key publisherId:(const std::string &)publisher_id
{
  [BATLedgerDatabase insertOrUpdateMediaPublisherInfoWithMediaKey:[NSString stringWithUTF8String:media_key.c_str()]
                                                      publisherID:[NSString stringWithUTF8String:publisher_id.c_str()]];
}

- (void)saveNormalizedPublisherList:(const ledger::PublisherInfoListStruct &)normalized_list
{
  const auto listStruct = [[BATPublisherInfoListStruct alloc] initWithPublisherInfoListStruct:normalized_list];
  [BATLedgerDatabase insertOrUpdateActivitiesInfoFromPublishers:listStruct.list];
  
  // TODO: brave-core notifies observers about updated list
}

- (void)savePendingContribution:(const ledger::PendingContributionList &)list
{
  const auto list_ = [[BATPendingContributionList alloc] initWithPendingContributionList:list];
  [BATLedgerDatabase insertPendingContributions:list_];
  
  // TODO: brave-core notifies observers about added pending contributions
}

- (void)savePublisherInfo:(std::unique_ptr<ledger::PublisherInfo>)publisher_info callback:(ledger::PublisherInfoCallback)callback
{
  const auto info = publisher_info.get();
  if (info != nullptr) {
    const auto publisher = [[BATPublisherInfo alloc] initWithPublisherInfo:*info];
    [BATLedgerDatabase insertOrUpdatePublisherInfo:publisher];
    callback(ledger::Result::LEDGER_OK, std::move(publisher_info));
  } else {
    callback(ledger::Result::LEDGER_ERROR, nullptr);
  }
}

@end
