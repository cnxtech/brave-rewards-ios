/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import BraveRewards

class WalletDetailsViewController: UIViewController, RewardsSummaryProtocol {
  private var ledgerObs: LedgerObserver
  let state: RewardsState
  
  init(state: RewardsState) {
    self.state = state
    ledgerObs = LedgerObserver(ledger: state.ledger)
    state.ledger.add(ledgerObs)
    super.init(nibName: nil, bundle: nil)
  }
  
  deinit {
    state.ledger.remove(ledgerObs)
  }
  
  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }
  
  override func loadView() {
    view = View(isEmpty: state.ledger.balance?.total == 0.0)
  }
  
  var detailsView: View {
    return view as! View // swiftlint:disable:this force_cast
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setObservers()
    title = Strings.WalletDetailsTitle
    
    detailsView.walletSection.addFundsButton.addTarget(self, action: #selector(tappedAddFunds), for: .touchUpInside)
    
    detailsView.walletSection.setWalletBalance(
      state.ledger.balanceString,
      crypto: "BAT",
      dollarValue: state.ledger.usdBalanceString
    )
    
    detailsView.activityView.monthYearLabel.text = summaryPeriod
    detailsView.activityView.rows = summaryRows
    detailsView.activityView.disclaimerView = disclaimerView
  }
  
  // MARK: - Actions
  
  @objc private func tappedAddFunds() {
    let controller = AddFundsViewController(state: state)
    let container = PopoverNavigationController(rootViewController: controller)
    present(container, animated: true)
  }
  
  func setObservers() {
    ledgerObs.balanceReportUpdated = {
      let rows = self.summaryRows.map({ row -> RowView in
        row.isHidden = true
        return row
      })
      UIView.animate(withDuration: 0.15, animations: {
        self.detailsView.activityView.stackView.arrangedSubviews.forEach({
          $0.isHidden = true
          $0.alpha = 0
        })
      }, completion: { _ in
        self.detailsView.activityView.rows = rows
        UIView.animate(withDuration: 0.15, animations: {
          self.detailsView.activityView.stackView.arrangedSubviews.forEach({
            $0.isHidden = false
            $0.alpha = 1
          })
        })
      })
    }
  }
}
