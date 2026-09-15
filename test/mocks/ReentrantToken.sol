// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 that, on the first outbound transfer from the escrow, re-enters a configured target
///      with configured calldata and records the result. Lets tests prove that `nonReentrant`
///      blocks a callback-driven double payout even though the state machine would as well.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    constructor() ERC20("Reentrant", "RNT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == target) {
            armed = false;
            reentered = true;
            (reentrySucceeded, reentryReturnData) = target.call(payload);
        }
    }
}
