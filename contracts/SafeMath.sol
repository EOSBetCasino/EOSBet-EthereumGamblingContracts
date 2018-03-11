pragma solidity ^0.4.18;

library SafeMath {

  // modifying standard SafeMul to not take up another stack space -- eosbet comment

  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0) {
      return 0;
    }
    // uint256 c = a * b; -- eosbet comment
    assert((a * b) / a == b);
    return a * b;
  }

  // modifying standard SafeDiv to not take up another stack space -- eosbet comment

  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0 -- comment in standard safemath library
    // uint256 c = a / b; -- eosbet comment
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold -- comment in standard safemath library
    return a / b;
  }

  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  // modifiying standard SafeAdd to not take up another stack space -- eosbet comment

  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    // uint256 c = a + b; -- eosbet comment
    assert((a + b) >= a);
    return a + b;
  }
}