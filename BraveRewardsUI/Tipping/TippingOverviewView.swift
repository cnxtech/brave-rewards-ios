/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

public class TippingOverviewView: UIView {
  private struct UX {
    static let backgroundColor = Colors.blurple800
    static let headerBackgroundColor = Colors.grey300
    static let headerHeight = 98.0
    static let faviconBackgroundColor = Colors.neutral800
    static let faviconSize = CGSize(width: 88.0, height: 88.0)
    static let titleColor = Colors.grey100
    static let bodyColor = Colors.grey200
  }
  
  let headerView = UIImageView().then {
    $0.backgroundColor = UX.headerBackgroundColor
    $0.clipsToBounds = true
  }
  
  let watermarkImageView = UIImageView(image: UIImage(frameworkResourceNamed: "tipping-bat-watermark"))
  
  let heartsImageView = UIImageView(image: UIImage(frameworkResourceNamed: "hearts"))
  
  let faviconImageView = UIImageView().then {
    $0.backgroundColor = UX.faviconBackgroundColor
    $0.clipsToBounds = true
    $0.layer.cornerRadius = UX.faviconSize.width / 2.0
    $0.layer.borderColor = UIColor.white.cgColor
    $0.layer.borderWidth = 2.0
  }
  
  let socialStackView = UIStackView().then {
    $0.spacing = 20.0
    for icon in ["pub-youtube", "pub-twitter", "pub-twitch"] {
      $0.addArrangedSubview(UIImageView(image: UIImage(frameworkResourceNamed: icon)))
    }
  }
  
  let titleLabel = UILabel().then {
    $0.text = BATLocalizedString("BraveRewardsTippingOverviewTitle", "Thanks for stopping by!")
    $0.textColor = UX.titleColor
    $0.font = .systemFont(ofSize: 23.0, weight: .semibold)
    $0.numberOfLines = 0
  }
  
  let bodyLabel = UILabel().then {
    $0.text = BATLocalizedString("BraveRewardsTippingOverviewBody", "You can support this site by sending a tip. It’s a way of thanking them for making great content. Verified content creators get paid for their tips during the first week of each calendar month.\n\nIf you like, you can schedule monthly tips to support this site on a continuous basis.")
    $0.textColor = UX.bodyColor
    $0.font = .systemFont(ofSize: 17.0)
    $0.numberOfLines = 0
  }
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    
    backgroundColor = UX.backgroundColor
    
    clipsToBounds = true
    layer.cornerRadius = 4.0
    
    addSubview(headerView)
    headerView.addSubview(watermarkImageView)
    // headerView.addSubview(heartsImageView)
    addSubview(socialStackView)
    addSubview(faviconImageView)
    addSubview(titleLabel)
    addSubview(bodyLabel)
    
    headerView.snp.makeConstraints {
      $0.top.leading.trailing.equalTo(self)
      $0.height.equalTo(UX.headerHeight)
    }
    watermarkImageView.snp.makeConstraints {
      $0.top.leading.equalTo(self.headerView)
    }
    faviconImageView.snp.makeConstraints {
      $0.bottom.equalTo(self.socialStackView.snp.bottom)
      $0.leading.equalTo(self).offset(25.0)
      $0.size.equalTo(UX.faviconSize)
    }
    socialStackView.snp.makeConstraints {
      $0.top.equalTo(self.headerView.snp.bottom).offset(20.0)
      $0.trailing.equalTo(self).offset(-20.0)
    }
    titleLabel.snp.makeConstraints {
      $0.top.equalTo(self.faviconImageView.snp.bottom).offset(25.0)
      $0.leading.trailing.equalTo(self).inset(25.0)
    }
    bodyLabel.snp.makeConstraints {
      $0.top.equalTo(self.titleLabel.snp.bottom).offset(10.0)
      $0.leading.trailing.equalTo(self.titleLabel)
      $0.bottom.equalTo(self).offset(-25.0)
    }
  }
  
  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }
}