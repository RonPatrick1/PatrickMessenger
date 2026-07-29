import share_receiver_models

final class ShareViewController: ShareReceiverServiceViewController {
  override func viewDidAppear(_ animated: Bool) {
    // The package superclass closes its sheet after 0.1 seconds here. Large
    // videos still need to finish copying into the shared App Group, so let
    // its normal completion callback close the extension when copying ends.
  }
}
