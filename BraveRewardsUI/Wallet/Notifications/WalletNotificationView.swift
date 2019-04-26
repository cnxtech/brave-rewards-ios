/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

class WalletNotificationView: UIView {
  
  let closeButton = Button()
  
  let backgroundView = UIImageView(image: UIImage(frameworkResourceNamed: "notification_header")).then {
    $0.contentMode = .scaleAspectFill
  }
  
  override init(frame: CGRect) {
    super.init(frame: .zero)
    
    backgroundColor = .clear
    
    closeButton.do {
      $0.setImage(UIImage(frameworkResourceNamed: "close-icon").alwaysTemplate, for: .normal)
      $0.tintColor = Colors.grey300
      $0.contentMode = .center
    }
    
    addSubview(backgroundView)
    addSubview(closeButton)
    
    closeButton.snp.makeConstraints {
      $0.top.trailing.equalTo(safeAreaLayoutGuide)
      $0.width.height.equalTo(44.0)
    }
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    backgroundView.frame = bounds
  }
  
  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }
}
