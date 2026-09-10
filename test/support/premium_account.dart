import 'package:xxread/services/account/member_account_controller.dart';

/// A verified entitlement fixture; account API verification is tested separately.
class PremiumTestAccount extends MemberAccountController {
  PremiumTestAccount({this._premium = true});

  bool _premium;

  @override
  bool get hasPremiumAccess => _premium;

  void setPremium(bool value) {
    _premium = value;
    notifyListeners();
  }
}
